# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe "Ripr type checking" do
  def with_project(source = "def value; 1; end\n")
    Dir.mktmpdir("ripr-type-check-spec") do |directory|
      project = File.join(directory, "project")
      executable_dir = File.join(directory, "bin")
      FileUtils.mkdir_p([project, executable_dir])
      File.write(File.join(project, "value.rb"), source)
      File.write(File.join(project, "Gemfile"), "source 'https://rubygems.org'\n")
      lockfile = File.join(project, "Gemfile.lock")
      File.write(lockfile, "original lockfile\n")
      bundle = File.join(executable_dir, "bundle")
      File.write(bundle, <<~SH)
        #!/bin/sh
        test "$BUNDLE_GEMFILE" = #{File.join(project, 'Gemfile').inspect} || exit 91
        test "$(pwd -P)" != #{File.realpath(project).inspect} || exit 92
        case "$BUNDLE_LOCKFILE" in
          ""|#{lockfile.inspect}) test "$BUNDLE_FROZEN" = true || exit 90 ;;
          *) printf '%s\n' 'updated lockfile' > "$BUNDLE_LOCKFILE" ;;
        esac
        case "$(cat value.rb)" in
          *"hung check"*) sleep 10 ;;
          *"broken checker"*) echo 'checker failed to load' >&2; exit 1 ;;
          *"swap symlink"*) rm value.rb; ln -s other.rb value.rb ;;
          *"bad return"*)
            case "$*" in
              "exec srb tc") echo 'value.rb:1: Expected Integer https://srb.help/7005' >&2; exit 100 ;;
              "exec steep check") echo 'value.rb:1:2: [error] Expected Integer'; exit 1 ;;
              *) echo 'unexpected checker invocation' >&2; exit 93 ;;
            esac ;;
        esac
      SH
      File.chmod(0o700, bundle)
      previous = ENV.to_h.slice("PATH", "BUNDLE_GEMFILE", "BUNDLE_LOCKFILE")
      ENV["PATH"] = "#{executable_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"
      ENV["BUNDLE_GEMFILE"] = File.join(project, "Gemfile")
      ENV["BUNDLE_LOCKFILE"] = lockfile
      Dir.chdir(project) { yield directory }
    ensure
      %w[PATH BUNDLE_GEMFILE BUNDLE_LOCKFILE].each { |key| ENV[key] = previous[key] } if previous
    end
  end

  def checker
    require "ripr/engine/type_checker"
    Ripr::Engine::TypeChecker
  end

  %w[sorbet rbs].each do |backend|
    it "checks #{backend} mutations in a copy and preserves the original source" do
      with_project do
        checker.open(backend) do |check|
          expect(check.check("value.rb", "# bad return\n")).to include("Expected Integer")
          expect(check.check("value.rb", "def value; 2; end\n")).to be_nil
          expect(File.read("value.rb")).to eq("def value; 1; end\n")
          expect(File.read("Gemfile.lock")).to eq("original lockfile\n")
        end
      end
    end
  end

  it "rejects a failing baseline and distinguishes infrastructure errors from invalid mutants" do
    with_project("# bad return\n") do
      expect { checker.open("sorbet") { raise "unexpected yield" } }.to raise_error(Ripr::Error, /baseline.*Expected Integer/)
    end
    with_project do
      checker.open("rbs") do |check|
        expect { check.check("value.rb", "# broken checker\n") }.to raise_error(Ripr::Error, /checker failed to load/)
      end
    end
  end

  it "rejects escaped source paths and leaves symlink targets untouched" do
    with_project do |directory|
      outside = File.join(directory, "outside.rb")
      File.write(outside, "protected\n")
      File.symlink(outside, "escape.rb")
      checker.open("sorbet") do |check|
        expect { check.check("escape.rb", "overwritten") }.to raise_error(ArgumentError, /outside/)
        expect { check.check("../outside.rb", "overwritten") }.to raise_error(ArgumentError, /outside/)
      end
      expect(File.read(outside)).to eq("protected\n")
    end
  end

  it "rejects a checker that replaces the staged source with a symlink" do
    with_project do
      File.write("other.rb", "protected\n")
      checker.open("sorbet") do |check|
        expect { check.check("value.rb", "# swap symlink\n") }.to raise_error(Ripr::Error, /replaced.*value\.rb/)
      end
      expect(File.read("other.rb")).to eq("protected\n")
    end
  end

  it "bounds hung checkers" do
    with_project do
      checker
      stub_const("Ripr::Engine::TypeChecker::TIMEOUT_MS", 250)
      expect { checker.open("sorbet") { |check| check.check("value.rb", "# hung check\n") } }.to raise_error(Ripr::Error, /timed out/)
    end
  end
end
