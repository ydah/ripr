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
    JSON.parse(output).tap do |result|
      result.fetch("gaps").each { |gap| gap.fetch("covering_tests").each { |test| test.delete("duration_ms") } }
    end
  end

  def select_report(directory, base, *args, environment: {})
    report(directory, base, "--reach-map", ".ripr/reach-map.json", *args, environment: environment)
  end

  def baseline_count(report)
    report.dig("run", "metrics", "baseline_tests_run")
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
