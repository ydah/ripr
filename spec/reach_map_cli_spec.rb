# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "ripr reach-map" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }
  let(:source) do
    <<~RUBY
      module Sample
        def self.startup = 7
        START = startup
        def self.positive? = 1 > 0
        def self.calculate = 1 + 2
        def self.unused = false
      end
    RUBY
  end
  let(:test_code) do
    <<~RUBY
      require "minitest/autorun"
      require "sample"
      class SampleTest < Minitest::Test
        def test_calculate = assert_equal(3, Sample.calculate)
        def test_positive = assert(Sample.positive?)
      end
    RUBY
  end

  def git(directory, *arguments)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments)
    raise error unless status.success?

    output.strip
  end

  def with_project(files = { "lib/sample.rb" => source, "test/sample_test.rb" => test_code })
    Dir.mktmpdir("ripr-reach-map") do |directory|
      files.each do |name, contents|
        path = File.join(directory, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end
      git(directory, "init", "-q")
      git(directory, "add", ".")
      git(directory, "-c", "user.name=Ripr Test", "-c", "user.email=test@example.test", "commit", "-qm", "fixture")
      yield directory
    end
  end

  def capture(directory, *arguments, loader: nil)
    Open3.capture3({ "RIPR_LOADER" => loader, "REACH_MAP_TEST_SECRET" => "fixture-input" }, RbConfig.ruby, executable, "reach-map",
                   *arguments, chdir: directory)
  end

  def artifact(directory)
    File.join(directory, ".ripr/reach-map.json")
  end

  [nil, "require"].each do |loader|
    it "records the full baseline with the #{loader || 'default'} loader" do
      with_project do |directory|
        _, error, status = capture(directory, loader: loader)
        expect(status.exitstatus).to eq(0), error
        expect(File).to exist(artifact(directory))
        raw = File.read(artifact(directory))
        map = JSON.parse(raw)
        expect(map).to include("version" => 1, "base" => git(directory, "rev-parse", "HEAD"), "framework" => "minitest")
        expect(raw).not_to include(directory, "fixture-input")
        expect(map.fetch("tests")).to eq(
          "SampleTest#test_calculate" => { "file" => "test/sample_test.rb", "line" => 4 },
          "SampleTest#test_positive" => { "file" => "test/sample_test.rb", "line" => 5 }
        )
        expect(map.fetch("test_order")).to eq(%w[SampleTest#test_calculate SampleTest#test_positive])
        expect(map.fetch("test_files")).to eq("test/sample_test.rb" => Digest::SHA256.hexdigest(test_code))
        expect(map.fetch("sources")).to eq("lib/sample.rb" => Digest::SHA256.hexdigest(source))
        expect(map.fetch("structure_hash")).to match(/\A[0-9a-f]{64}\z/)
        methods = map.fetch("method_hashes").keys.map { |key| key.split(":").last }
        expect(methods).to contain_exactly("startup", "positive?", "calculate", "unused")
        expect(map.fetch("reach").transform_keys { |key| key.split(":").last }).to eq(
          "positive?" => ["SampleTest#test_positive"], "calculate" => ["SampleTest#test_calculate"]
        )
        expect(map.fetch("unattributed").map { |key| key.split(":").last }).to eq(["startup"])
        expect(File).not_to exist(File.join(directory, ".ripr/snapshot.json"))
      end
    end
  end

  it "records RSpec group hook reach without assigning it to the example" do
    spec = <<~RUBY
      require "sample"
      RSpec.describe Sample do
        before(:context) { Sample.calculate }
        it("is positive") { expect(Sample.positive?).to be(true) }
      end
    RUBY
    with_project("lib/sample.rb" => source, "spec/sample_spec.rb" => spec, "spec/support/config.rb" => "# suite input\n") do |directory|
      _, error, status = capture(directory)
      expect(status.exitstatus).to eq(0), error
      expect(File).to exist(artifact(directory))
      map = JSON.parse(File.read(artifact(directory)))
      expect(map.fetch("unattributed").map { |key| key.split(":").last }).to contain_exactly("startup", "calculate")
      expect(map.fetch("reach").transform_keys { |key| key.split(":").last }).to eq("positive?" => ["./spec/sample_spec.rb[1:1]"])
      expect(map.fetch("test_files")).to include("spec/support/config.rb" => Digest::SHA256.hexdigest("# suite input\n"))
    end
  end

  it "records unresolved calls and named methods that can return a closure" do
    dynamic_source = source.sub("def self.unused = false", <<~RUBY.chomp)
      def self.deferred = -> { 3 }
      define_singleton_method(:dynamic) { 3 }
    RUBY
    tests = test_code.sub("Sample.calculate)", "Sample.deferred.call + Sample.dynamic - 3)")
    with_project("lib/sample.rb" => dynamic_source, "test/sample_test.rb" => tests) do |directory|
      _, error, status = capture(directory)
      expect(status.exitstatus).to eq(0), error
      map = JSON.parse(File.read(artifact(directory)))
      expect(map.fetch("unresolved_files")).to eq(["lib/sample.rb"])
      expect(map.fetch("deferred_methods").map { |key| key.split(":").last }).to eq(["deferred"])
    end
  end

  it "does not publish failed baseline results" do
    tests = test_code.sub("3, Sample.calculate", "9, Sample.calculate")
    with_project("lib/sample.rb" => source, "test/sample_test.rb" => tests) do |directory|
      _, error, status = capture(directory)
      expect(status.exitstatus).to eq(4), error
      expect(error).to include("baseline failed")
      expect(File).not_to exist(artifact(directory))
    end
  end

  it "does not publish a baseline if tracked inputs change while tests run" do
    setup = test_code.sub("def test_calculate =", "def setup = File.write('config/input', 'changed')\n  def test_calculate =")
    with_project("lib/sample.rb" => source, "test/sample_test.rb" => setup, "config/input" => "initial") do |directory|
      _, error, status = capture(directory)
      expect(status.exitstatus).to eq(1), error
      expect(error).to include("clean Git worktree")
      expect(File).not_to exist(artifact(directory))
    end
  end

  it "requires a clean Git worktree and rejects partial run arguments" do
    with_project do |directory|
      [["--since", "HEAD"], ["--only", "sample"], ["--dry-run"]].each do |arguments|
        _, error, status = capture(directory, *arguments)
        expect(status.exitstatus).to eq(1), error
        expect(error).to include("reach-map requires a complete baseline")
      end
      File.write(File.join(directory, "lib/sample.rb"), source.sub("1 > 0", "1 < 0"))
      _, error, status = capture(directory)
      expect(status.exitstatus).to eq(1), error
      expect(error).to include("clean Git worktree")
      expect(File).not_to exist(artifact(directory))
    end
  end

  it "preserves an existing artifact if an ignored configured test file changes during execution" do
    tests = test_code.sub("def test_calculate =", "def setup = File.write('cases/another.rb', 'changed')\n  def test_calculate =")
    files = { ".gitignore" => "/cases/another.rb\n", "lib/sample.rb" => source, "cases/sample.rb" => tests }
    with_project(files) do |directory|
      File.write(File.join(directory, "cases/another.rb"), "# Initial test input\n")
      FileUtils.mkdir_p(File.dirname(artifact(directory)))
      File.write(artifact(directory), "existing map")
      _, error, status = capture(directory, "--tests", "cases/*.rb")
      expect(status.exitstatus).to eq(1), error
      expect(error).to include("project inputs changed")
      expect(File.read(artifact(directory))).to eq("existing map")
    end
  end

  it "replaces the previous reach map from a nested project" do
    files = { "app/lib/sample.rb" => source, "app/test/sample_test.rb" => test_code }
    with_project(files) do |directory|
      app = File.join(directory, "app")
      2.times do
        _, error, status = capture(app)
        expect(status.exitstatus).to eq(0), error
      end
      expect(JSON.parse(File.read(artifact(app)))).to include("base" => git(directory, "rev-parse", "HEAD"), "project_prefix" => "app/")
    end
  end

  it "rejects changes outside a nested project in the same repository" do
    files = { "app/lib/sample.rb" => source, "app/test/sample_test.rb" => test_code, "shared.rb" => "# input\n" }
    with_project(files) do |directory|
      File.write(File.join(directory, "shared.rb"), "# changed\n")
      app = File.join(directory, "app")
      _, error, status = capture(app)
      expect(status.exitstatus).to eq(1), error
      expect(error).to include("clean Git worktree")
      expect(File).not_to exist(artifact(app))
    end
  end

  it "keeps the previous artifact if boot changes the project working directory" do
    files = { "boot.rb" => "Dir.chdir('shadow')\n", "lib/sample.rb" => source,
              "shadow/lib/sample.rb" => source, "shadow/test/sample_test.rb" => test_code }
    with_project(files) do |directory|
      FileUtils.mkdir_p(File.dirname(artifact(directory)))
      File.write(artifact(directory), "existing map")
      _, error, status = capture(directory, "--boot", "boot.rb")
      expect(status.exitstatus).to eq(1), error
      expect(error).to include("working directory changed")
      expect(File.read(artifact(directory))).to eq("existing map")
      expect(File).not_to exist(artifact(File.join(directory, "shadow")))
    end
  end
end
