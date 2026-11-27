# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

RSpec.describe "ripr command" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }
  let(:fixture) { File.expand_path("../test/fixtures/projects/minitest_basic", __dir__) }

  def command(*args, directory: fixture, env: {})
    Open3.capture3(env, RbConfig.ruby, executable, *args, chdir: directory)
  end

  it "restores runtime state, loaders, output, and the caller's environment after a boot failure" do
    Dir.mktmpdir("ripr-boot-cleanup") do |directory|
      FileUtils.mkdir_p(File.join(directory, "lib"))
      File.write(File.join(directory, "lib/sample.rb"), "def adult?(age); age >= 18; end\n")
      File.write(File.join(directory, "boot.rb"), <<~RUBY)
        raise "ripr flag missing" unless ENV["RIPR"] == "1"
        puts "boot diagnostic"
        STDOUT.puts "descriptor diagnostic"
        Ripr::R.current_test = "loading"
        Ripr::R.activate("loading", 1)
        raise "boot failed"
      RUBY
      program = <<~RUBY
        require "json"
        require "stringio"
        require "ripr"
        require "ripr/config"
        require "ripr/engine/runner"

        results = [nil, "caller"].map do |previous|
          previous ? ENV["RIPR"] = previous : ENV.delete("RIPR")
          stream = StringIO.new
          $stdout = stream
          failure = begin
            config = Ripr::Config.load({ operators: ["comparison"], boot: "boot.rb", jobs: 1 })
            Ripr::Engine::Runner.new(config).call
          rescue => error
            error.message
          end
          { "failure" => failure, "environment" => ENV["RIPR"],
            "loaders" => Ripr::Loader.active_loaders.size, "probe" => Ripr::R.probe,
            "current_test" => Ripr::R.current_test,
            "variant" => Ripr::R.bin("loading", 1, 2) { |_, _, variant| variant },
            "stdout_restored" => $stdout.equal?(stream), "captured" => stream.string }
        end
        STDOUT.write(JSON.generate(results))
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__),
                                             "-e", program, chdir: directory)

      expect(status.exitstatus).to eq(0), error
      expected = { "failure" => "boot failed", "loaders" => 0, "probe" => nil, "current_test" => nil,
                   "variant" => 0, "stdout_restored" => true, "captured" => "" }
      expect(JSON.parse(output)).to eq([expected.merge("environment" => nil), expected.merge("environment" => "caller")])
      expect(error.lines).to eq(["boot diagnostic\n", "descriptor diagnostic\n"] * 2)
    end
  end

  it "loads project helpers from lib, test, and spec when tests use ordinary requires" do
    Dir.mktmpdir("ripr-test-load-path") do |directory|
      FileUtils.mkdir_p(%w[lib test spec].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), "module Sample; def self.adult?(age); age >= 18; end; end\n")
      File.write(File.join(directory, "test/test_helper.rb"), "require 'minitest/autorun'\nrequire 'sample'\n")
      File.write(File.join(directory, "spec/fixture_helper.rb"), "FIXTURE_AGE = 18\n")
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "test_helper"
        require "fixture_helper"
        class LoadPathTest < Minitest::Test
          def test_boundary
            assert Sample.adult?(FIXTURE_AGE)
          end
        end
      RUBY

      output, error, status = command("--full", "--jobs", "1", "--operators", "comparison", "--reporter", "agent", directory: directory)
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(output).fetch("summary")).to include("killed" => 1, "survived" => 0, "error" => 0)
    end
  end

  it "explains when no test files or runnable tests are available" do
    Dir.mktmpdir("ripr-missing-tests") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), "def adult?(age); age >= 18; end\n")
      arguments = %w[--full --operators comparison --framework minitest]

      output, error, status = command(*arguments, directory: directory)
      expect(status.exitstatus).to eq(1)
      expect(output).to be_empty
      expect(error).to include("no test files found")

      File.write(File.join(directory, "test/empty_test.rb"), "require 'minitest/autorun'\n")
      output, error, status = command(*arguments, directory: directory)
      expect(status.exitstatus).to eq(4)
      expect(output).to be_empty
      expect(error).to include("no tests were discovered")
    end
  end

  it "classifies Minitest gaps and emits clean agent JSON" do
    stdout, stderr, status = command("--reporter", "agent", "--full", "--jobs", "2")
    expect(status.exitstatus).to eq(0), stderr
    report = JSON.parse(stdout)
    expect(report.fetch("schema")).to eq("ripr.agent/v1")
    boundary = report.fetch("gaps").find { |m| m["subject"] == "Sample.adult?" && m["operator"] == "comparison" }
    expect(boundary.fetch("kind")).to eq("not_infected")
    expect(boundary.fetch("observed")).to eq([[20, 18], [10, 18]])
    expect(report.fetch("summary").fetch("killed")).to be >= 2
    expect(report.fetch("summary").fetch("not_reached")).to be >= 1
  end

  it "produces equivalent classifications for RSpec" do
    rspec_fixture = fixture.sub("minitest_basic", "rspec_basic")
    stdout, stderr, status = command("--reporter", "agent", "--full", directory: rspec_fixture)
    expect(status.exitstatus).to eq(0), stderr
    boundary = JSON.parse(stdout).fetch("gaps").find { |m| m["operator"] == "comparison" }
    expect(boundary.fetch("kind")).to eq("not_infected")
  end

  it "observes mutations through load_iseq when test setup starts Bootsnap with a warm compile cache" do
    Dir.mktmpdir("ripr-bootsnap") do |directory|
      FileUtils.cp_r(File.join(fixture, "."), directory)
      File.write(File.join(directory, "test/boot_helper.rb"), "nil\n")
      boot = "require 'bootsnap/setup'\n"
      setup = boot + <<~RUBY
        Bootsnap.instrumentation = ->(event, path) do
          File.write("bootsnap-hit", path) if event == :hit && path.end_with?("/boot_helper.rb")
        end
        require_relative "boot_helper"
      RUBY
      test = File.join(directory, "test/sample_test.rb")
      File.write(test, setup + File.read(test).sub("adult?(20)", "adult?(18)"))
      env = { "RIPR_LOADER" => nil, "BOOTSNAP_CACHE_DIR" => File.join(directory, "cache"), "DISABLE_BOOTSNAP" => nil,
              "DISABLE_BOOTSNAP_COMPILE_CACHE" => nil, "BOOTSNAP_READONLY" => nil }
      warm = "#{boot}require './lib/sample'\nrequire './test/boot_helper'"
      _, error, warmup = Open3.capture3(env, RbConfig.ruby, "-e", warm, chdir: directory)
      expect(warmup.success?).to be(true), error

      stdout, error, status = command("--full", "--operators", "comparison", "--reporter", "agent", directory: directory, env: env)
      expect(status.success?).to be(true), error
      expect(JSON.parse(stdout).fetch("summary")).to include("killed" => 1, "not_reached" => 0)
      expect(File.read(File.join(directory, "bootsnap-hit"))).to end_with("/test/boot_helper.rb")
    end
  end

  it "matches the design's complete golden classifications for both frameworks" do
    expected = JSON.parse(File.read(File.expand_path("../test/fixtures/golden/basic.json", __dir__)))
    %w[minitest rspec].each do |framework|
      directory = fixture.sub("minitest_basic", "#{framework}_basic")
      _, stderr, status = command("--full", directory: directory)
      expect(status.exitstatus).to eq(0), stderr
      snapshot = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
      actual = snapshot.fetch("mutants").values.map { |m| m.slice("subject", "operator", "replacement", "status") }
      sort_key = ->(m) { m.values_at("subject", "operator", "replacement") }
      expect(actual.sort_by(&sort_key)).to eq(expected.sort_by(&sort_key))
    end
  end

  it "validates options and configuration before running tests" do
    _, _, status = command("--jobs", "0")
    expect(status.exitstatus).to eq(1)
    _, _, status = command("--scope", "other")
    expect(status.exitstatus).to eq(1)
    Dir.mktmpdir("ripr-config") do |dir|
      File.write(File.join(dir, ".ripr.yml"), "unknown: 1\n")
      _, stderr, status = command(directory: dir)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("unknown")
    end
  end

  it "accepts automatic workers on the command line" do
    _, stderr, status = command("--jobs", "auto", "--full")
    expect(status.exitstatus).to eq(0), stderr
  end

  it "warms the loaded test process before forking workers" do
    Dir.mktmpdir("ripr-warmup") do |dir|
      FileUtils.cp_r(File.join(fixture, "."), dir)
      File.write(File.join(dir, "test/warmup_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        Process.singleton_class.prepend(Module.new do
          def warmup
            File.write("warmed.txt", Process.pid)
            super
          end
        end)

        class WarmupTest < Minitest::Test
          def test_forked_from_warmed_parent
            assert File.file?("warmed.txt"), "parent did not warm up"
            assert_equal Process.ppid, File.read("warmed.txt").to_i
            assert Sample.adult?(20)
          end
        end
      RUBY

      _, stderr, status = command("--full", "--jobs", "1", "--tests", "test/warmup_test.rb", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
    end
  end

  it "returns quality gate and baseline failure exit codes" do
    _, _, status = command("--fail-on-survived", "--full")
    expect(status.exitstatus).to eq(2)
    Dir.mktmpdir("ripr-failure") do |dir|
      FileUtils.cp_r(File.join(fixture, "."), dir)
      File.write(File.join(dir, "test/sample_test.rb"),
                 "require 'minitest/autorun'; class BrokenTest < Minitest::Test; def test_broken; flunk; end; end")
      _, _, status = command("--full", directory: dir)
      expect(status.exitstatus).to eq(4)
    end
  end

  it "replays the selected tests on original code to distinguish false kills" do
    Dir.mktmpdir("ripr-verify-killed") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.shared = true
          def self.independent = true
        end
      RUBY
      File.write(File.join(dir, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_a_prepare
            $prepared = true
          end

          def test_b_shared
            assert $prepared, "missing setup from another test"
            assert Sample.shared
          end

          def test_c_independent
            assert Sample.independent
          end
        end
      RUBY

      stdout, stderr, status = command("--full", "--operators", "boolean_literal", "--reporter", "agent", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch("summary").fetch("killed")).to eq(2)

      stdout, stderr, status = command("--full", "--operators", "boolean_literal", "--reporter", "agent", "--verify-killed", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch("summary")).to include("killed" => 1, "error" => 1)
      expect(stderr).to include("original code", "missing setup from another test")
    end
  end

  it "loads a project boot file after installing mutation switches without mixing its output into reports" do
    Dir.mktmpdir("ripr-boot") do |dir|
      FileUtils.cp_r(File.join(fixture, "."), dir)
      File.write(File.join(dir, "boot.rb"), <<~RUBY)
        puts "booted fixture"
        require_relative "lib/sample"
        RIPR_BOOTED = true
      RUBY
      File.open(File.join(dir, "test/sample_test.rb"), "a") do |file|
        file.puts <<~RUBY
          class SampleTest
            def test_boot_ran
              assert RIPR_BOOTED
            end
          end
        RUBY
      end

      stdout, stderr, status = command("--full", "--boot", "boot.rb", "--reporter", "agent", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(stderr).to include("booted fixture")
      report = JSON.parse(stdout)
      expect(report.fetch("summary").fetch("killed")).to be >= 2
      expect(report.dig("run", "metrics", "baseline_tests_run")).to eq(3)
    end
  end

  it "activates static mutations before requiring their file in a fresh process" do
    Dir.mktmpdir("ripr-static") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "lib/sample.rb"), "module Sample; COUNT = 1; end\n")
      File.write(File.join(dir, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        at_exit { STDOUT.puts "finishing a static mutation" } unless Sample::COUNT == 1
        class SampleTest < Minitest::Test
          def test_uses_count
            STDOUT.puts "checking a load-time constant"
            assert_equal 1, Sample::COUNT
          end
        end
      RUBY

      stdout, stderr, status = command("--static", "--operators", "integer_literal", "--reporter", "agent", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch("summary")).to include("killed" => 2, "static" => 0)
      snapshot = JSON.parse(File.read(File.join(dir, ".ripr/snapshot.json")))
      expect(snapshot.fetch("mutants").values).to all(include("static" => true, "status" => "killed"))
    end
  end

  it "reuses static plans across fresh boots until a planned source changes" do
    analyzer = File.expand_path("../lib/ripr/core/analyzer", __dir__)
    %w[unchanged changed added].each do |scenario|
      Dir.mktmpdir("ripr-static-plan") do |dir|
        FileUtils.mkdir_p([File.join(dir, "lib"), File.join(dir, "test")])
        File.binwrite(File.join(dir, "lib/sample.rb"), "# coding: Windows-1252\nmodule Sample; COUNT = 1; LABEL = '\xE9'; end\n")
        File.write(File.join(dir, "lib/dependency.rb"), "nil\n")
        File.write(File.join(dir, "trace.rb"), "require #{analyzer.inspect}\n" + <<~'RUBY')
          Ripr::Core::Analyzer.singleton_class.prepend(Module.new do
            def call(source, path, **)
              File.write("planned.log", "#{Process.pid} #{path}\n", mode: "a")
              super
            end
          end)
        RUBY
        File.write(File.join(dir, "boot.rb"), <<~'RUBY')
          raise "boot was already run" if defined?(STATIC_PLAN_BOOTED)
          STATIC_PLAN_BOOTED = true
          unless File.exist?("booted.log")
            case ENV.fetch("STATIC_PLAN_SCENARIO")
            when "changed" then File.write("lib/dependency.rb", "false\n")
            when "added" then File.write("lib/added.rb", "nil\n")
            end
          end
          File.write("booted.log", "#{Process.pid}\n", mode: "a")
        RUBY
        File.write(File.join(dir, "test/sample_test.rb"), <<~RUBY)
          require "minitest/autorun"
          require_relative "../lib/sample"
          class SampleTest < Minitest::Test
            def test_static_value
              assert_equal [233], Sample::LABEL.bytes
              assert_equal "Windows-1252", Sample::LABEL.encoding.name
              assert_equal 1, Sample::COUNT
            end
          end
        RUBY

        env = { "RUBYOPT" => "#{ENV.fetch('RUBYOPT', nil)} -r#{File.join(dir, 'trace.rb')}", "STATIC_PLAN_SCENARIO" => scenario }
        stdout, stderr, status = command("--full", "--static", "--verify-killed", "--operators", "integer_literal", "--jobs", "2",
                                         "--boot", "boot.rb", "--reporter", "agent", directory: dir, env: env)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout).fetch("summary")).to include("killed" => 2, "error" => 0), scenario
        boots = File.readlines(File.join(dir, "booted.log"), chomp: true)
        expect(boots.uniq.size).to eq(5), scenario
        plans = File.readlines(File.join(dir, "planned.log"), chomp: true).map { |line| line.split.first }.uniq
        expect(plans.sort).to eq(scenario == "unchanged" ? [boots.first] : boots.sort), scenario
      end
    end
  end

  it "rejects an invalid acceptance ledger created after planning static mutations" do
    Dir.mktmpdir("ripr-static-ledger") do |dir|
      FileUtils.mkdir_p([File.join(dir, "lib"), File.join(dir, "test")])
      File.write(File.join(dir, "lib/sample.rb"), "module Sample; COUNT = 1; end\n")
      File.write(File.join(dir, "boot.rb"), "File.write('ripr.accepted.yml', 'invalid')\n")
      File.write(File.join(dir, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class SampleTest < Minitest::Test
          def test_static_value = assert_equal(1, Sample::COUNT)
        end
      RUBY

      stdout, stderr, status = command("--full", "--static", "--operators", "integer_literal", "--boot", "boot.rb",
                                       "--reporter", "agent", directory: dir)
      expect(status).to be_success, stderr
      expect(JSON.parse(stdout).fetch("summary")).to include("killed" => 0, "error" => 2)
    end
  end

  it "lists the extra operators when the full operator profile is selected" do
    stdout, stderr, status = command("list", "operators", "--operators", "full")
    expect(status.exitstatus).to eq(0), stderr
    expect(stdout.lines.map(&:chomp)).to include("string_literal", "regexp_literal", "collection_literal", "safe_navigation")
  end

  it "kills opt-in Ruby expression and pattern mutations" do
    Dir.mktmpdir("ripr-ruby-operators") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.range; 0...3; end
          def self.largest(values); values.max; end
          def self.empty?(count); count.zero?; end
          def self.required(values); values.fetch(:required); end
          def self.pick(value); value ||= :fallback; end
          def self.no_odds?(values); values.none?(&:odd?); end

          def self.first_number(input)
            case input
            in [Integer => number] then number
            else :unknown
            end
          end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class SampleTest < Minitest::Test
          def test_ruby_operations
            refute Sample.range.include?(3)
            assert_equal 5, Sample.largest([2, 5])
            assert Sample.empty?(0)
            assert_raises(KeyError) { Sample.required({}) }
            assert_equal :chosen, Sample.pick(:chosen)
            assert Sample.no_odds?([2])
            assert_equal 3, Sample.first_number([3])
          end
        end
      RUBY

      operators = %w[range_endpoint collection_query predicate_method fetch_index logical_assignment collection_none case_in]
      stdout, stderr, status = command("--full", "--jobs", "1", "--operators", operators.join(","),
                                       "--reporter", "agent", directory: directory)
      expect(status.success?).to be(true), stderr
      expect(JSON.parse(stdout).fetch("summary")).to include("killed" => operators.length, "survived" => 0, "error" => 0)
      snapshot = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
      expect(snapshot.fetch("mutants").values.map { |mutant| mutant.values_at("operator", "status") }).to match_array(
        operators.map { |operator| [operator, "killed"] }
      )
    end
  end

  it "checks directly mutated source and excludes mutations rejected by a type checker" do
    Dir.mktmpdir("ripr-typed") do |dir|
      FileUtils.mkdir_p([File.join(dir, "lib"), File.join(dir, "test"), File.join(dir, "bin")])
      File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'\n")
      source = File.join(dir, "lib/sample.rb")
      File.write(source, "module Sample; def self.label; 'label'; end; end\n")
      File.write(File.join(dir, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class SampleTest < Minitest::Test
          def test_label
            assert_equal "label", Sample.label
          end
        end
      RUBY
      bundle = File.join(dir, "bin/bundle")
      File.write(bundle, <<~SH)
        #!/bin/sh
        test "$*" = "exec srb tc" || exit 1
        if grep -q '; nil)' lib/sample.rb; then
          echo 'lib/sample.rb:1: Expected String, found NilClass'
          exit 100
        fi
      SH
      File.chmod(0o700, bundle)
      env = { "PATH" => "#{File.join(dir, 'bin')}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}" }
      stdout, stderr, status = command("--typecheck", "sorbet", "--operators", "return_nil", "--reporter", "agent",
                                       directory: dir, env: env)
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch("summary")).to include("invalid" => 1, "killed" => 0)
      expect(stderr).to include("Expected String")
      expect(File.read(source)).to eq("module Sample; def self.label; 'label'; end; end\n")
    end
  end

  it "kills arithmetic mutations when tests catch an exception from the original operator" do
    Dir.mktmpdir("ripr-exception") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "lib/sample.rb"), "module Sample; def self.divide(n, d); n / d; end; end\n")
      File.write(File.join(dir, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class DivideTest < Minitest::Test
          def test_zero_divisor
            assert_raises(ZeroDivisionError) { Sample.divide(4, 0) }
          end
        end
      RUBY
      _, stderr, status = command("--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      snapshot = JSON.parse(File.read(File.join(dir, ".ripr/snapshot.json")))
      arithmetic = snapshot.fetch("mutants").values.find { |mutant| mutant["operator"] == "arithmetic" }
      expect(arithmetic.fetch("status")).to eq("killed")
    end
  end

  it "initializes configuration and the bundled skill without overwriting changes" do
    Dir.mktmpdir("ripr-init") do |dir|
      _, stderr, status = command("init", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(File.read(File.join(dir, ".ripr.yml"))).to include("framework: auto")
      _, stderr, status = command("init-skill", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      target = File.join(dir, ".claude/skills/mutation-test-loop/SKILL.md")
      bundled = File.expand_path("../skills/mutation-test-loop/SKILL.md", __dir__)
      expect(File.read(target)).to eq(File.read(bundled))
      File.write(target, "customized")
      _, _, status = command("init-skill", directory: dir)
      expect(status.exitstatus).to eq(1)
      expect(File.read(target)).to eq("customized")
      _, _, status = command("init-skill", "--force", directory: dir)
      expect(status.exitstatus).to eq(0)
      expect(File.read(target)).to eq(File.read(bundled))
    end
  end

  it "lists operators and writes JSON and offline HTML reports" do
    stdout, _, status = command("list", "operators")
    expect(status.exitstatus).to eq(0)
    expect(stdout.lines.map(&:strip)).to include("comparison", "return_nil")
    stdout, _, status = command("list", "mutants")
    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("age >= 18")
    Dir.mktmpdir("ripr-report") do |dir|
      _, stderr, status = command("--reporter", "html", "--reporter", "json", "--report-dir", dir, "--full")
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(File.binread(File.join(dir, "mutation.json"))).fetch("schemaVersion")).to eq("2")
      expect(File.read(File.join(dir, "index.html"))).to include("ripr mutation report")
    end
  end

  it "uses workspace-relative annotation paths when run in a nested project" do
    workspace = File.expand_path("..", __dir__)
    output, stderr, status = command("--reporter", "github", "--full", env: { "GITHUB_WORKSPACE" => workspace })
    expect(status.exitstatus).to eq(0), stderr
    expect(output).to include("::warning file=test/fixtures/projects/minitest_basic/lib/sample.rb,")
  end

  it "annotates sites that ran while loading and cannot change existing load-time effects" do
    Dir.mktmpdir("ripr-load-reach") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.adult?(age); age >= 18; end
          ADULT = adult?(20)
        end
      RUBY
      File.write(File.join(dir, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class LoadTest < Minitest::Test
          def test_constant
            assert Sample::ADULT
          end
        end
      RUBY
      output, stderr, status = command("--reporter", "agent", "--operators", "comparison", "--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      gap = JSON.parse(output).fetch("gaps").first
      expect(gap.fetch("load_reached")).to be(true)
      expect(gap.fetch("hint")).to include("during loading")
    end
  end

  it "accepts equivalent mutants and invalidates the acceptance after source changes" do
    Dir.mktmpdir("ripr-accept") do |dir|
      FileUtils.cp_r(File.join(fixture, "."), dir)
      stdout, stderr, status = command("--reporter", "agent", "--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      gap = JSON.parse(stdout).fetch("gaps").find { |m| m["operator"] == "comparison" }
      _, stderr, status = command("accept", gap.fetch("id"), "--reason", "Specification excludes the exact boundary", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      stdout, stderr, status = command("--reporter", "agent", "--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch("summary").fetch("accepted")).to eq(1)
      source_path = File.join(dir, "lib/sample.rb")
      File.write(source_path, File.read(source_path).sub("age >= 18", "age >= 19"))
      stdout, stderr, status = command("--reporter", "agent", "--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch("summary").fetch("accepted")).to eq(0)
      expect(stderr).to include("stale")
    end
  end
end
