# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe "Ripr type checking" do
  def with_project(source = "def value; 1; end\n")
    Dir.mktmpdir("ripr-type-check-spec") do |directory|
      directory = File.realpath(directory)
      project = File.join(directory, "project")
      executable_dir = File.join(directory, "bin")
      FileUtils.mkdir_p([project, executable_dir])
      File.binwrite(File.join(project, "value.rb"), source)
      File.write(File.join(project, "Gemfile"), "source 'https://rubygems.org'\n")
      lockfile = File.join(project, "Gemfile.lock")
      File.write(lockfile, "original lockfile\n")
      bundle = File.join(executable_dir, "bundle")
      File.write(bundle, <<~SH)
        #!/bin/sh
        test "$BUNDLE_GEMFILE" = #{File.join(project, 'Gemfile').inspect} || exit 91
        test "$(pwd -P)" != #{File.realpath(project).inspect} || exit 92
        case "$BUNDLE_LOCKFILE" in
          ""|#{lockfile.inspect})
            test "$BUNDLE_FROZEN" = true && test ! -e require-isolated-lockfile || exit 90
            ;;
          *)
            test ! -e require-frozen-lockfile || exit 98
            if test -f #{lockfile.inspect}; then
              case "$(cat "$BUNDLE_LOCKFILE")" in
                "original lockfile"|"updated lockfile") ;;
                *) echo 'staged lockfile did not contain the original dependency versions' >&2; exit 94 ;;
              esac
            fi
            printf '%s\n' 'updated lockfile' > "$BUNDLE_LOCKFILE"
            ;;
        esac
        pwd -P > #{File.join(directory, 'staged-directory').inspect}
        if test -f expected-original && ! cmp -s value.rb expected-original && ! cmp -s value.rb expected-mutation; then
          echo 'staged source does not match the expected bytes' >&2
          exit 95
        fi
        case "$(cat value.rb)" in
          *"hung check"*) sleep 2 ;;
          *"broken checker"*) echo 'checker failed to load' >&2; exit 1 ;;
          *"swap symlink"*) rm value.rb; ln -s other.rb value.rb ;;
          *"move source and symlink"*) mv value.rb moved.rb; ln -s moved.rb value.rb ;;
          *"verify copy"*)
            test -f .checker-config && test ! -e .git && test ! -e .ripr || exit 96
            mkdir -p "$XDG_CACHE_HOME" && touch "$XDG_CACHE_HOME/type-results" || exit 97
            ;;
          *"silent exit"*) exit 73 ;;
          *"signaled check"*) kill -TERM "$$" ;;
          *"colored diagnostic"*)
            echo 'tool warning'
            printf 'value.rb:1: Expected \033[31mInteger\033[0m\nvalue.rb:2: Another error\n' >&2
            exit 100
            ;;
          *"long diagnostic"*) printf 'value.rb:1: %0810d\n' 0 >&2; exit 100 ;;
          *"long failure"*) printf 'checker failed: %0810d\n' 0 >&2; exit 73 ;;
          *"wrong diagnostic exit"*) echo 'value.rb:1: Expected Integer' >&2; exit 73 ;;
          *"successful warning"*) echo 'value.rb:1:2: [warning] Redundant check'; exit 0 ;;
          *"bad return"*)
            case "$*" in
              "exec srb tc") echo 'value.rb:1: Expected Integer https://srb.help/7005' >&2; exit 100 ;;
              "exec steep check") echo 'value.rb:1:2: [error] Expected Integer'; exit 1 ;;
              *) echo 'unexpected checker invocation' >&2; exit 93 ;;
            esac ;;
        esac
      SH
      File.chmod(0o700, bundle)
      environment_keys = %w[PATH BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLE_FROZEN XDG_CACHE_HOME]
      previous = ENV.to_h.slice(*environment_keys)
      ENV["PATH"] = "#{executable_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"
      ENV["BUNDLE_GEMFILE"] = File.join(project, "Gemfile")
      ENV["BUNDLE_LOCKFILE"] = lockfile
      ENV.delete("BUNDLE_FROZEN")
      ENV["XDG_CACHE_HOME"] = File.join(directory, "caller-cache")
      Dir.chdir(project) { yield directory }
    ensure
      environment_keys.each { |key| ENV[key] = previous[key] } if previous
    end
  end

  def checker
    require "ripr/engine/type_checker"
    Ripr::Engine::TypeChecker
  end

  def staged_source(directory)
    File.join(File.read(File.join(directory, "staged-directory")).chomp, "value.rb")
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

  it "rejects an unsupported checker by name" do
    expect { checker.open("unsupported") { raise "unexpected yield" } }
      .to raise_error(ArgumentError, /unknown type checker .*unsupported/)
  end

  it "isolates project metadata and tool caches while returning the block result" do
    with_project do |directory|
      File.write(".checker-config", "checked")
      FileUtils.mkdir_p(%w[.git .ripr])
      result = checker.open("sorbet") do |check|
        expect(check.check("value.rb", "# verify copy\n")).to be_nil
        :result
      end
      expect(result).to eq(:result)
      expect(File.exist?(File.join(directory, "caller-cache"))).to be(false)
      expect(File.exist?(File.dirname(staged_source(directory)))).to be(false)
    end
  end

  it "uses the original project bundle even when BUNDLE_GEMFILE is unset" do
    with_project do
      ENV.delete("BUNDLE_GEMFILE")
      checker.open("sorbet") { |check| expect(check.check("value.rb", "# bad return\n")).to include("Expected Integer") }
    end
  end

  { "2.6.9" => "frozen", "4.0.0" => "isolated" }.each do |version, lock_mode|
    it "uses the #{lock_mode} lockfile mode with Bundler #{version}" do
      checker
      stub_const("Bundler::VERSION", version)
      with_project do
        File.write("require-#{lock_mode}-lockfile", "")
        checker.open("rbs") { |check| expect(check.check("value.rb", "# bad return\n")).to include("Expected Integer") }
        expect(File.read("Gemfile.lock")).to eq("original lockfile\n")
      end
    end
  end

  it "checks exact staged bytes and restores the copy after a rejected mutation" do
    original = "# binary sample \xFF\r\ndef value; 1; end\r\n".b
    mutation = "# bad return\n".b
    with_project(original) do |directory|
      File.binwrite("expected-original", original)
      File.binwrite("expected-mutation", mutation)
      checker.open("sorbet") do |check|
        expect(check.check("value.rb", mutation)).to include("Expected Integer")
        expect(File.binread(staged_source(directory)).bytes).to eq(original.bytes)
      end
      expect(File.binread("value.rb").bytes).to eq(original.bytes)
    end
  end

  it "rejects a failing baseline and distinguishes infrastructure errors from invalid mutants" do
    with_project("# bad return\n") do
      expect { checker.open("sorbet") { raise "unexpected yield" } }.to raise_error(Ripr::Error, /baseline.*Expected Integer/)
    end
    with_project do |directory|
      checker.open("rbs") do |check|
        expect { check.check("value.rb", "# broken checker\n") }.to raise_error(Ripr::Error, /checker failed to load/)
        expect(File.read(staged_source(directory))).to eq(File.read("value.rb"))
        expect(check.check("value.rb", "# successful warning\n")).to be_nil
      end
    end
  end

  it "returns an uncolored diagnostic only when the checker exit code signals rejection" do
    with_project do
      checker.open("sorbet") do |check|
        expect(check.check("value.rb", "# colored diagnostic\n")).to eq("value.rb:1: Expected Integer")
        expect { check.check("value.rb", "# wrong diagnostic exit\n") }
          .to raise_error(Ripr::Error, /sorbet typecheck failed to run: value\.rb:1: Expected Integer/)
      end
    end
  end

  it "reports how a checker stopped when it produced no diagnostic output" do
    with_project do
      checker.open("sorbet") do |check|
        expect { check.check("value.rb", "# silent exit\n") }.to raise_error(Ripr::Error, /sorbet.*exit status 73/)
        expect { check.check("value.rb", "# signaled check\n") }
          .to raise_error(Ripr::Error, /sorbet.*signal #{Signal.list.fetch('TERM')}/)
      end
    end
  end

  it "bounds rejection diagnostics and execution errors and restores the staged source" do
    with_project do |directory|
      checker.open("sorbet") do |check|
        expect(check.check("value.rb", "# long diagnostic\n")).to eq("value.rb:1: #{'0' * 788}")
        expect { check.check("value.rb", "# long failure\n") }
          .to raise_error(Ripr::Error, "sorbet typecheck failed to run: checker failed: #{'0' * 784}")
        expect(File.binread(staged_source(directory))).to eq(File.binread("value.rb"))
        expect(check.check("value.rb", "def value; 2; end\n")).to be_nil
      end
    end
  end

  it "reports the execution error when the bundle command can no longer be started" do
    with_project do |directory|
      checker.open("sorbet") do |check|
        ENV["PATH"] = directory
        expect { check.check("value.rb", "def value; 2; end\n") }
          .to raise_error(Ripr::Error, /sorbet typecheck failed to run: Errno::ENOENT: .*bundle/)
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
        expect { check.check("../absent.rb", "overwritten") }.to raise_error(ArgumentError, /outside/)
      end
      expect(File.read(outside)).to eq("protected\n")
    end
  end

  it "accepts contained symlinks and reports missing or non-file sources" do
    with_project do |directory|
      File.symlink("value.rb", "alias.rb")
      Dir.mkdir("subdirectory")
      checker.open("sorbet") do |check|
        expect(check.check("alias.rb", "# bad return\n")).to include("Expected Integer")
        expect(File.binread(staged_source(directory))).to eq(File.binread("value.rb"))
        expect { check.check("absent.rb", "ignored") }.to raise_error(ArgumentError, /missing project source/)
        expect { check.check("subdirectory", "ignored") }.to raise_error(ArgumentError, /source/)
      end
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

  it "rejects a checker that leaves a symlink to the moved source in its original location" do
    with_project do |directory|
      checker.open("sorbet") do |check|
        expect { check.check("value.rb", "# move source and symlink\n") }
          .to raise_error(Ripr::Error, /replaced.*value\.rb/)
        moved = File.join(File.dirname(staged_source(directory)), "moved.rb")
        expect(File.binread(moved)).to eq(File.binread("value.rb"))
      end
    end
  end

  it "bounds a hung checker and restores the staged source after the timeout" do
    with_project do |directory|
      checker.open("sorbet") do |check|
        stub_const("Ripr::Engine::TypeChecker::TIMEOUT_MS", 500)
        expect { check.check("value.rb", "# hung check\n") }.to raise_error(Ripr::Error, /sorbet typecheck timed out/)
        expect(File.binread(staged_source(directory))).to eq(File.binread("value.rb"))
      end
    end
  end
end
