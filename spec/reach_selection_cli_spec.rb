# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "ripr reach-map selection" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }
  let(:source) do
    <<~RUBY
      module Sample
        def self.startup = 7 + 1
        START = startup
        def self.calculate = 3 + 2
        def self.positive? = 3 >= 2
      end
    RUBY
  end
  let(:minitest) do
    <<~RUBY
      require "minitest/autorun"
      require "sample"
      class SampleTest < Minitest::Test
        def test_calculate = assert_operator(Sample.calculate, :>=, 5)
        def test_positive = assert(Sample.positive?)
      end
    RUBY
  end
  let(:rspec) do
    <<~RUBY
      require "sample"
      RSpec.describe Sample do
        it("calculates") { expect(Sample.calculate).to be >= 5 }
        it("is positive") { expect(Sample.positive?).to be(true) }
      end
    RUBY
  end

  def git(directory, *args)
    output, error, status = Open3.capture3("git", "-C", directory, *args)
    raise error unless status.success?

    output.strip
  end

  def write(directory, name, contents)
    path = File.join(directory, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  def with_project(files)
    Dir.mktmpdir("ripr-reach-select") do |directory|
      write(directory, ".gitignore", "/.ripr/\n")
      write(directory, "lib/sample.rb", source)
      files.each { |name, contents| write(directory, name, contents) }
      git(directory, "init", "-q")
      commit(directory, "base")
      yield directory
    end
  end

  def commit(directory, message)
    git(directory, "add", ".")
    git(directory, "-c", "user.name=Ripr Test", "-c", "user.email=test@example.test", "commit", "-qm", message)
  end

  def run(directory, *args, environment: {})
    Open3.capture3(environment, RbConfig.ruby, executable, *args, "--jobs", "1", chdir: directory)
  end

  def capture(directory, environment: {})
    _, error, status = run(directory, "reach-map", environment: environment)
    expect(status.exitstatus).to eq(0), error
    git(directory, "rev-parse", "HEAD")
  end

  def report(directory, base, *args, environment: {})
    output, error, status = run(directory, "--since", base, "--reporter", "agent", *args, environment: environment)
    expect(status.exitstatus).to eq(0), error
    yield error if block_given?
    JSON.parse(output).tap do |result|
      result.fetch("gaps").each { |gap| gap.fetch("covering_tests").each { |test| test.delete("duration_ms") } }
    end
  end

  def select_report(directory, base, *args, environment: {}, &)
    report(directory, base, "--reach-map", ".ripr/reach-map.json", *args, environment: environment, &)
  end

  def baseline_count(report)
    report.dig("run", "metrics", "baseline_tests_run")
  end

  def with_load_audit
    Dir.mktmpdir("ripr-reach-load-audit") do |directory|
      script = <<~RUBY
        require "coverage"
        Coverage.start(lines: true)
        at_exit do
          executed = Coverage.peek_result.filter_map { |path, counts| path if counts.fetch(:lines).compact.any?(&:positive?) }
          File.write(ENV.fetch("RIPR_LOAD_AUDIT"), executed.join("\\n"))
        end
      RUBY
      write(directory, "audit.rb", script)
      path = File.join(directory, "loaded")
      yield({ "RUBYOPT" => [ENV.fetch("RUBYOPT", nil), "-r#{File.join(directory, 'audit.rb')}"].compact.join(" "),
              "RIPR_LOAD_AUDIT" => path }, path)
    end
  end

  def expect_file_selection(files, loads_trailing:)
    with_load_audit do |environment, audit|
      with_project(files) do |directory|
        base = capture(directory, environment: environment)
        write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
        commit(directory, "edit method")
        full = report(directory, base, environment: environment)
        selected = select_report(directory, base, "--reach-map-files", files.keys.last, environment: environment) do |diagnostic|
          expect(diagnostic).not_to include("retrying with all test files")
        end

        expect(baseline_count(full)).to eq(2)
        expect(baseline_count(selected)).to eq(1)
        expect(selected.values_at("summary", "gaps")).to eq(full.values_at("summary", "gaps"))
        trailing = File.realpath(File.join(directory, files.keys.last))
        loaded = File.readlines(audit, chomp: true)
        loads_trailing ? expect(loaded).to(include(trailing)) : expect(loaded).not_to(include(trailing))
      end
    end
  end

  it "omits independent Minitest DSL tests with setup and teardown blocks" do
    support = <<~RUBY
      require "minitest/spec"
      Minitest::Test.extend(Minitest::Spec::DSL)
      class << Minitest::Test
        alias test it
        alias setup before
        alias teardown after
      end
    RUBY
    first = minitest.sub("  def test_positive = assert(Sample.positive?)\n", "")
                    .sub('require "sample"', "require \"sample\"\nrequire \"./test/support.rb\"")
    last = <<~RUBY
      require "minitest/autorun"
      require "sample"
      require "./test/support.rb"
      class LastTest < Minitest::Test
        setup { @ready = true }
        teardown { assert(@ready) }
        test("is positive") { assert(Sample.positive?) }
      end
    RUBY
    expect_file_selection({ "test/support.rb" => support, "test/first_test.rb" => first, "test/last_test.rb" => last },
                          loads_trailing: false)
  end

  {
    "a custom superclass" => [<<~RUBY, "class LastTest < SupportTest\n  def test_positive = assert(Sample.positive?)\nend\n"],
      class SupportTest < Minitest::Test
        def self.inherited(child)
          super
          $minimum = 5
        end
      end
    RUBY
    "a class without a superclass" => ["class LastTest < Minitest::Test; end\n", <<~RUBY],
      class LastTest
        $minimum = 5
        def test_positive = assert(Sample.positive?)
      end
    RUBY
    "a class with no tests" => [<<~RUBY, <<~RUBY],
      Minitest::Test.singleton_class.prepend(Module.new do
        def inherited(child)
          super
          $minimum = 5 if child.name == "ConfigurationTest"
        end
      end)
    RUBY
      class ConfigurationTest < Minitest::Test
        def minimum = 5
      end
      class LastTest < Minitest::Test
        def test_positive = assert(Sample.positive?)
      end
    RUBY
    "an unsupported test DSL" => [<<~RUBY, <<~RUBY],
      require "minitest/spec"
      Minitest::Test.extend(Minitest::Spec::DSL)
      Minitest::Test.singleton_class.prepend(Module.new do
        def inherited(child)
          super
          $minimum = 5 if child.name == "LastTest"
        end
      end)
    RUBY
      class LastTest < Minitest::Test
        it("is positive") { assert(Sample.positive?) }
      end
    RUBY
    "a class body setting" => ["# shared support\n", <<~RUBY]
      class LastTest < Minitest::Test
        $minimum = 5
        def test_positive = assert(Sample.positive?)
      end
    RUBY
  }.each do |declaration, (support, last)|
    it "retains trailing Minitest declarations containing #{declaration}" do
      first = minitest.sub("  def test_positive = assert(Sample.positive?)\n", "")
                      .sub('require "sample"', "require \"sample\"\nrequire \"./test/support.rb\"")
                      .sub(":>=, 5", ":>=, $minimum || 0")
      last = "require \"minitest/autorun\"\nrequire \"sample\"\nrequire \"./test/support.rb\"\n#{last}"
      expect_file_selection({ "test/support.rb" => support, "test/first_test.rb" => first, "test/last_test.rb" => last },
                            loads_trailing: true)
    end
  end

  it "retains a trailing Minitest file that imports additional test settings" do
    first = minitest.sub("  def test_positive = assert(Sample.positive?)\n", "").sub(":>=, 5", ":>=, $minimum || 0")
    last = minitest.sub("  def test_calculate = assert_operator(Sample.calculate, :>=, 5)\n", "")
                   .sub("SampleTest", "LastTest").sub('require "sample"', "require \"sample\"\nrequire \"./test/settings.rb\"")
    expect_file_selection({ "test/settings.rb" => "$minimum = 5\n", "test/first_test.rb" => first, "test/last_test.rb" => last },
                          loads_trailing: true)
  end

  {
    "relative imports" => ["require \"./test/settings.rb\"\n", 'require_relative "./test/settings.rb"',
                           { "test/settings.rb" => "$minimum = 0\n", "test/test/settings.rb" => "$minimum = 5\n" }],
    "a default require argument" => [<<~RUBY, "require", { "test/settings.rb" => "$minimum = 5\n" }],
      def require(path = "./test/settings.rb")
        super(path)
      end
    RUBY
    "a computed require argument" => ["", 'require File.expand_path("settings.rb", __dir__)', { "test/settings.rb" => "$minimum = 5\n" }]
  }.each do |loader, (setup, declaration, settings)|
    it "retains a trailing Minitest file with #{loader}" do
      first = minitest.sub("  def test_positive = assert(Sample.positive?)\n", "")
                      .sub("class SampleTest", "#{setup}class SampleTest").sub(":>=, 5", ":>=, $minimum || 0")
      last = minitest.sub("  def test_calculate = assert_operator(Sample.calculate, :>=, 5)\n", "")
                     .sub("SampleTest", "LastTest").sub('require "sample"', "require \"sample\"\n#{declaration}")
      expect_file_selection(settings.merge("test/first_test.rb" => first, "test/last_test.rb" => last),
                            loads_trailing: true)
    end
  end

  it "retains a trailing RSpec group with metadata that configures shared test settings" do
    support = <<~RUBY
      RSpec.configure do |config|
        config.on_example_group_definition do |group|
          $minimum = 5 if group.metadata[:stricter]
        end
      end
    RUBY
    first = rspec.sub("describe Sample", 'describe "first"').sub(/  it\("is positive"\).*\n/, "")
                 .sub('require "sample"', "require \"sample\"\nrequire \"./spec/support.rb\"")
                 .sub("be >= 5", "be >= ($minimum || 0)")
    last = <<~RUBY
      require "sample"
      require "./spec/support.rb"
      RSpec.describe "last", stricter: true do
        it("is positive") { expect(Sample.positive?).to be(true) }
      end
    RUBY
    expect_file_selection({ "spec/support.rb" => support, "spec/first_spec.rb" => first, "spec/last_spec.rb" => last },
                          loads_trailing: true)
  end

  %w[minitest rspec].each do |framework|
    it "loads fewer #{framework} files when a trailing declaration is independent" do
      files = if framework == "minitest"
                first = minitest.sub("  def test_positive = assert(Sample.positive?)\n", "")
                last = minitest.sub("  def test_calculate = assert_operator(Sample.calculate, :>=, 5)\n", "")
                { "test/first_test.rb" => first, "test/last_test.rb" => last.sub("SampleTest", "LastTest") }
              else
                first = rspec.sub("describe Sample", 'describe "first"').sub(/  it\("is positive"\).*\n/, "")
                last = rspec.sub("describe Sample", 'describe "last"').sub(/  it\("calculates"\).*\n/, "")
                { "spec/first_spec.rb" => first, "spec/last_spec.rb" => last }
              end
      with_load_audit do |environment, audit|
        with_project(files) do |directory|
          base = capture(directory, environment: environment)
          write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
          commit(directory, "edit method") if framework == "rspec"

          ineligible = File.realpath(File.join(directory, files.keys.last))
          select_report(directory, base, "--reach-map-files", files.keys.first, environment: environment)
          expect(File.readlines(audit, chomp: true)).to include(ineligible)

          pattern = files.keys.last.sub("/last_", "/*ast_")
          selected = select_report(directory, base, "--reach-map-files", pattern, "--reach-map-files", "unmatched/*",
                                   environment: environment) do |diagnostic|
            expect(diagnostic).not_to include("reach-map fallback")
          end
          expect(baseline_count(selected)).to eq(1)
          expect(File.readlines(audit, chomp: true)).to include(File.realpath(File.join(directory, files.keys.first)))
          expect(File.readlines(audit, chomp: true)).not_to include(File.realpath(File.join(directory, files.keys.last)))
          expect(File).not_to exist(File.join(directory, ".ripr/snapshot.json"))
          full = report(directory, base, environment: environment)
          expect(selected.values_at("summary", "gaps")).to eq(full.values_at("summary", "gaps"))

          repeated_flags = ["--reach-map-files", pattern, "--baseline-runs", "2"]
          repeated = select_report(directory, base, *repeated_flags, environment: environment) do |diagnostic|
            expect(diagnostic).to include("repeated baselines require all test files")
          end
          expect(baseline_count(repeated)).to eq(4)
          expect(File.readlines(audit, chomp: true)).to include(ineligible)
          expect(repeated.values_at("summary", "gaps")).to eq(full.values_at("summary", "gaps"))
        end
      end
    end
  end

  it "retains a trailing RSpec file that registers a global hook" do
    first = rspec.sub("describe Sample", 'describe "first"').sub(/  it\("is positive"\).*\n/, "")
    first = first.sub("be >= 5", "be >= @minimum")
    last = <<~RUBY
      require "sample"
      RSpec.configure { |config| config.before { @minimum = 5 } }
      RSpec.describe "last" do
        it("is positive") { expect(Sample.positive?).to be(true) }
      end
    RUBY
    with_load_audit do |environment, audit|
      with_project("spec/first_spec.rb" => first, "spec/last_spec.rb" => last) do |directory|
        base = capture(directory, environment: environment)
        write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
        commit(directory, "edit method")

        result = select_report(directory, base, "--reach-map-files", "spec/last_spec.rb", environment: environment) do |diagnostic|
          expect(diagnostic).not_to include("reach-map fallback")
        end
        expect(baseline_count(result)).to eq(1)
        expect(File.readlines(audit, chomp: true)).to include(File.realpath(File.join(directory, "spec/last_spec.rb")))
      end
    end
  end

  it "retains a trailing Minitest file that reopens a class from an earlier file" do
    first = minitest.sub("  def test_positive = assert(Sample.positive?)\n", "") + <<~RUBY
      class LastTest < Minitest::Test
      end
    RUBY
    last = minitest.sub("  def test_calculate = assert_operator(Sample.calculate, :>=, 5)\n", "").sub("SampleTest", "LastTest")
    with_load_audit do |environment, audit|
      with_project("test/first_test.rb" => first, "test/last_test.rb" => last) do |directory|
        base = capture(directory, environment: environment)
        write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))

        result = select_report(directory, base, "--reach-map-files", "test/last_test.rb", environment: environment)
        expect(baseline_count(result)).to eq(1)
        expect(File.readlines(audit, chomp: true)).to include(File.realpath(File.join(directory, "test/last_test.rb")))
      end
    end
  end

  it "preserves Minitest verdicts when a retained test refers to the omitted class" do
    first = minitest.sub("  def test_positive = assert(Sample.positive?)\n", "")
    first = first.sub("assert_operator(Sample.calculate, :>=, 5)", "assert_operator(Sample.calculate, :>=, defined?(LastTest) ? 5 : 0)")
    last = minitest.sub("  def test_calculate = assert_operator(Sample.calculate, :>=, 5)\n", "").sub("SampleTest", "LastTest")
    with_load_audit do |environment, audit|
      with_project("test/first_test.rb" => first, "test/last_test.rb" => last) do |directory|
        base = capture(directory, environment: environment)
        write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
        full = report(directory, base, environment: environment)
        selected = select_report(directory, base, "--reach-map-files", "test/last_test.rb", environment: environment)

        expect(selected.values_at("summary", "gaps")).to eq(full.values_at("summary", "gaps"))
        expect(baseline_count(selected)).to eq(1)
        expect(File.readlines(audit, chomp: true)).to include(File.realpath(File.join(directory, "test/last_test.rb")))
      end
    end
  end

  it "preserves RSpec verdicts when a retained example reads the spec registry" do
    first = rspec.sub("describe Sample", 'describe "first"').sub(/  it\("is positive"\).*\n/, "")
    first = first.sub("be >= 5", "be >= (RSpec.world.example_groups.size > 1 ? 5 : 0)")
    last = rspec.sub("describe Sample", 'describe "last"').sub(/  it\("calculates"\).*\n/, "")
    with_load_audit do |environment, audit|
      with_project("spec/first_spec.rb" => first, "spec/last_spec.rb" => last) do |directory|
        base = capture(directory, environment: environment)
        write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
        commit(directory, "edit method")
        full = report(directory, base, environment: environment)
        selected = select_report(directory, base, "--reach-map-files", "spec/last_spec.rb", environment: environment)

        expect(selected.values_at("summary", "gaps")).to eq(full.values_at("summary", "gaps"))
        expect(baseline_count(selected)).to eq(1)
        expect(File.readlines(audit, chomp: true)).to include(File.realpath(File.join(directory, "spec/last_spec.rb")))
      end
    end
  end

  it "restarts from the invoking directory and runs a full baseline after failed narrowing" do
    first = minitest.sub("  def test_positive = assert(Sample.positive?)\n", "")
    first = first.sub(":>=, 5", ':>=, Object.const_defined?(["Last", "Test"].join) ? 5 : 99')
    first += <<~RUBY
      raise "test loading changed the environment" if ENV["RIPR_RETRY_FIXTURE_STATE"]
      ENV["RIPR_RETRY_FIXTURE_STATE"] = "started"
    RUBY
    last = <<~RUBY
      require "minitest/autorun"
      require "sample"
      class LastTest < Minitest::Test
        def test_positive = assert(Sample.positive?)
      end
    RUBY
    with_load_audit do |environment, audit|
      with_project("app/lib/sample.rb" => source, "app/test/first_test.rb" => first, "app/test/last_test.rb" => last) do |directory|
        app = File.join(directory, "app")
        base = capture(app, environment: environment)
        write(app, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))

        output, error, status = run(directory, "--since", base, "--reporter", "agent", "--profile", "--reach-map",
                                    ".ripr/reach-map.json", "--reach-map-files", "test/last_test.rb", "app", environment: environment)
        expect(status.exitstatus).to eq(0), error
        expect(error.scan("retrying with all test files").size).to eq(1)
        expect(baseline_count(JSON.parse(output))).to eq(2)
        expect(File.readlines(audit, chomp: true)).to include(File.realpath(File.join(app, "test/last_test.rb")))
        expect(File).to exist(File.join(app, ".ripr/report/profile.json"))
      end
    end
  end

  %w[minitest rspec].each do |framework|
    it "preserves #{framework} verdicts while only executing the affected baseline test" do
      files = framework == "minitest" ? { "test/sample_test.rb" => minitest } : { "spec/sample_spec.rb" => rspec }
      with_project(files) do |directory|
        base = capture(directory)
        write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
        commit(directory, "edit method") if framework == "rspec"

        selected = select_report(directory, base)
        expect(baseline_count(selected)).to eq(1)
        expect(File).not_to exist(File.join(directory, ".ripr/snapshot.json"))
        control = report(directory, base)
        expect(baseline_count(control)).to eq(2)
        expect(selected.values_at("summary", "gaps")).to eq(control.values_at("summary", "gaps"))
      end
    end
  end

  it "adds tests from a changed file with a known test body" do
    tests = minitest.sub("  def test_positive = assert(Sample.positive?)\n", "")
    other = <<~RUBY
      require "minitest/autorun"
      require "sample"
      class ChangedTest < Minitest::Test
        def test_positive = assert(Sample.positive?)
      end
    RUBY
    unrelated = other.sub("ChangedTest", "UnrelatedTest")
    with_project("test/first_test.rb" => tests, "test/changed_test.rb" => other, "test/unrelated_test.rb" => unrelated) do |directory|
      base = capture(directory)
      write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
      write(directory, "test/changed_test.rb", other.sub("Sample.positive?", "Sample.calculate >= 5"))
      expect(baseline_count(select_report(directory, base))).to eq(2)
    end
  end

  it "falls back to the full baseline when a changed method ran during load" do
    with_project("test/sample_test.rb" => minitest) do |directory|
      base = capture(directory)
      write(directory, "lib/sample.rb", source.sub("7 + 1", "8 + 1"))
      expect(baseline_count(select_report(directory, base))).to eq(2)
    end
  end

  it "falls back to the full baseline after a change to a test helper" do
    with_project("test/sample_test.rb" => minitest, "test/helper.rb" => "# helper\n") do |directory|
      base = capture(directory)
      write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
      write(directory, "test/helper.rb", "# changed\n")
      expect(baseline_count(select_report(directory, base))).to eq(2)
    end
  end

  it "falls back to the full baseline on an environment change" do
    with_project("test/sample_test.rb" => minitest) do |directory|
      base = capture(directory)
      write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
      expect(baseline_count(select_report(directory, base, environment: { "RIPR_SELECT_TEST_ENV" => "changed" }))).to eq(2)
    end
  end

  it "selects baseline tests with a version 3 map" do
    with_project("test/sample_test.rb" => minitest) do |directory|
      base = capture(directory)
      artifact = File.join(directory, ".ripr/reach-map.json")
      data = JSON.parse(File.read(artifact)).merge("version" => 3).except("test_load_order")
      File.write(artifact, JSON.generate(data))
      write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))

      expect(baseline_count(select_report(directory, base, "--reach-map-files", "test/*_test.rb"))).to eq(1)
    end
  end

  it "runs the full baseline for class-body changes, stale maps, and malformed reach data" do
    with_project("test/sample_test.rb" => minitest) do |directory|
      base = capture(directory)
      artifact = File.join(directory, ".ripr/reach-map.json")
      original = JSON.parse(File.read(artifact))
      write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2").sub("START = startup", "START = startup + 1"))
      expect(baseline_count(select_report(directory, base))).to eq(2)

      write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
      File.write(artifact, JSON.generate(original.merge("base" => "stale")))
      expect(baseline_count(select_report(directory, base))).to eq(2)
      File.write(artifact, JSON.generate(original.merge("test_order" => ["stranger"])))
      expect(baseline_count(select_report(directory, base))).to eq(2)
    end
  end

  it "falls back to a full baseline when a cached reach map fails validation" do
    secondary = "module Secondary\n  def self.calculate = 1 + 1\nend\n"
    with_project("test/sample_test.rb" => minitest, "lib/secondary.rb" => secondary) do |directory|
      base = capture(directory)
      artifact = File.join(directory, ".ripr/reach-map.json")
      map = JSON.parse(File.read(artifact))
      write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
      write(directory, "lib/secondary.rb", secondary.sub("1 + 1", "2 + 1"))
      expect(baseline_count(select_report(directory, base))).to eq(1)
      full = report(directory, base)
      expect(baseline_count(full)).to eq(2)

      calculation = "SampleTest#test_calculate"
      positive = "SampleTest#test_positive"
      reach = map.fetch("reach")
      tests = map.fetch("tests")
      changes = {
        "unsupported format" => { "version" => map.fetch("version") + 1 },
        "opaque load" => { "opaque_load" => true },
        "unknown database inputs" => { "database_inputs" => nil },
        "stale test location" => { "tests" => tests.merge(calculation => tests.fetch(calculation).merge("line" => 3)) },
        "incomplete test order" => { "test_order" => [calculation] },
        "obsolete test ID" => { "reach" => reach.merge(reach.key([positive]) => ["SampleTest#test_removed"]) },
        "truncated method digest" => { "method_hashes" => map.fetch("method_hashes").merge(reach.key([calculation]) => "truncated") },
        "stale source digest" => { "sources" => map.fetch("sources").merge("lib/sample.rb" => "0" * 64) }
      }
      changes.each do |label, overrides|
        aggregate_failures(label) do
          File.write(artifact, JSON.generate(map.merge(overrides)))
          result = select_report(directory, base)
          expect(baseline_count(result)).to eq(2), "Expected a full baseline for #{label}, got #{baseline_count(result)} tests"
          expect(result.values_at("summary", "gaps")).to eq(full.values_at("summary", "gaps"))
        end
      end
    end
  end

  it "runs the full baseline after edits outside the recorded project" do
    files = { "app/lib/sample.rb" => source, "app/test/sample_test.rb" => minitest, "lib/sibling.rb" => "# original\n" }
    with_project(files) do |directory|
      app = File.join(directory, "app")
      base = capture(app)
      write(app, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
      expect(baseline_count(select_report(app, base))).to eq(1)
      write(directory, "lib/sibling.rb", "# changed\n")
      expect(baseline_count(select_report(app, base))).to eq(2)
    end
  end

  it "runs a fresh full baseline when the reduced baseline fails" do
    changed_source = source.sub("3 + 2", "(@seed || 0) + 2").sub("START = startup", "START = startup\n  def self.seed = (@seed = 3)")
    tests = minitest.sub("def test_positive = assert(Sample.positive?)", "def test_a_seed = Sample.seed")
    with_project("lib/sample.rb" => changed_source, "test/sample_test.rb" => tests) do |directory|
      base = capture(directory)
      write(directory, "lib/sample.rb", changed_source.sub("(@seed || 0) + 2", "(@seed || 0) + 3"))
      result = select_report(directory, base)
      expect(baseline_count(result)).to eq(2)
      expect(result.dig("run", "metrics", "baseline_reach_map")).to be_nil
      expect(File).to exist(File.join(directory, ".ripr/snapshot.json"))
    end
  end

  [nil, "require"].each do |loader|
    it "keeps tests that inspect source directly with the #{loader || 'default'} loader" do
      observer = 'assert_includes(File.read("lib/sample.rb"), "3 + 2")'
      tests = minitest.sub("assert(Sample.positive?)", observer)
      with_project("test/sample_test.rb" => tests) do |directory|
        environment = { "RIPR_LOADER" => loader }
        base = capture(directory, environment: environment)
        write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
        _, error, status = run(directory, "--since", base, "--reach-map", ".ripr/reach-map.json", environment: environment)
        expect(status.exitstatus).to eq(4), error
        expect(error).to include("baseline failed")
      end
    end
  end

  it "selects opaque tests without running unrelated tests" do
    tests = minitest.sub("assert(Sample.positive?)", 'assert_includes(File.read("lib/sample.rb"), "module Sample")')
                    .sub("end\n", "  def test_unrelated = assert(Sample.positive?)\nend\n")
    with_project("test/sample_test.rb" => tests) do |directory|
      base = capture(directory)
      map = JSON.parse(File.read(File.join(directory, ".ripr/reach-map.json")))
      expect(map.fetch("opaque_tests")).to eq(["SampleTest#test_positive"])
      write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
      result = select_report(directory, base)
      expect(baseline_count(result)).to eq(2)
      expect(result.dig("run", "metrics", "baseline_reach_map")).to be(true)
    end
  end

  {
    "reads" => "MEMOIZED_SOURCE = File.binread('lib/sample.rb')",
    "yields" => "MEMOIZED_SOURCE = +''\nFile.foreach('lib/sample.rb') { |line| MEMOIZED_SOURCE << line }"
  }.each do |operation, setup|
    it "runs the full baseline if an operation #{operation} source during test loading" do
      tests = minitest.sub("class SampleTest < Minitest::Test", "#{setup}\nclass SampleTest < Minitest::Test")
                      .sub("assert(Sample.positive?)", "assert_includes(MEMOIZED_SOURCE, '3 + 2')")
      with_project("test/sample_test.rb" => tests) do |directory|
        base = capture(directory)
        write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
        _, error, status = run(directory, "--since", base, "--reach-map", ".ripr/reach-map.json")
        expect(status.exitstatus).to eq(4), error
        expect(error).to include("baseline failed")
      end
    end
  end

  it "keeps tests that inspect source through Pathname, subprocesses, or copy_stream" do
    observers = [
      'assert_includes(Pathname.new("lib/sample.rb").read, "3 + 2")',
      'assert(system("grep", "-qF", "3 + 2", "lib/sample.rb"))',
      'buffer = StringIO.new; IO.copy_stream("lib/sample.rb", buffer); assert_includes(buffer.string, "3 + 2")'
    ]
    observers.each do |observer|
      tests = "require 'pathname'\nrequire 'stringio'\n#{minitest.sub('assert(Sample.positive?)', "(#{observer})")}"
      with_project("test/sample_test.rb" => tests) do |directory|
        base = capture(directory)
        write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
        _, error, status = run(directory, "--since", base, "--reach-map", ".ripr/reach-map.json")
        expect(status.exitstatus).to eq(4), error
      end
    end
  end

  it "keeps tests that inspect source through an anonymous file handle" do
    observer = 'File.open("lib/sample.rb") { |file| assert_includes(File.new(file.fileno, autoclose: false).read, "3 + 2") }'
    tests = minitest.sub("assert(Sample.positive?)", observer)
    with_project("test/sample_test.rb" => tests) do |directory|
      base = capture(directory)
      write(directory, "lib/sample.rb", source.sub("3 + 2", "4 + 2"))
      _, error, status = run(directory, "--since", base, "--reach-map", ".ripr/reach-map.json")
      expect(status.exitstatus).to eq(4), error
    end
  end
end
