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

  def capture(directory, *arguments, loader: nil, environment: {}, ruby_args: [])
    env = { "RIPR_LOADER" => loader, "REACH_MAP_TEST_SECRET" => "fixture-input" }.merge(environment)
    Open3.capture3(env, RbConfig.ruby, *ruby_args, executable, "reach-map", *arguments, chdir: directory)
  end

  def artifact(directory)
    File.join(directory, ".ripr/reach-map.json")
  end

  [nil, "require"].each do |loader|
    it "records the full baseline with the #{loader || 'default'} loader" do
      with_project do |directory|
        output, error, status = capture(directory, loader: loader)
        expect(status.exitstatus).to eq(0), error
        expect(output).to include("Wrote .ripr/reach-map.json")
        expect(File).to exist(artifact(directory))
        raw = File.read(artifact(directory))
        map = JSON.parse(raw)
        expect(map).to include("version" => 4, "base" => git(directory, "rev-parse", "HEAD"), "framework" => "minitest",
                               "opaque_load" => false, "opaque_tests" => [])
        expect(raw).not_to include(directory, "fixture-input")
        expect(map.fetch("tests")).to eq(
          "SampleTest#test_calculate" => { "file" => "test/sample_test.rb", "line" => 4 },
          "SampleTest#test_positive" => { "file" => "test/sample_test.rb", "line" => 5 }
        )
        expect(map.fetch("test_order")).to eq(%w[SampleTest#test_calculate SampleTest#test_positive])
        expect(map.fetch("test_load_order")).to eq(["test/sample_test.rb"])
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

  it "honors a higher timeout base when recording a reach map" do
    clock = <<~RUBY
      Process.singleton_class.prepend(Module.new do
        def clock_gettime(clock, *)
          value = super
          clock == Process::CLOCK_MONOTONIC ? value * 1000 : value
        end
      end)
    RUBY
    slow_tests = test_code.sub("assert_equal(3, Sample.calculate)", "(sleep 0.2; assert_equal(3, Sample.calculate))")
    with_project("clock.rb" => clock, "lib/sample.rb" => source, "test/sample_test.rb" => slow_tests) do |directory|
      ruby_args = ["-r", File.join(directory, "clock.rb")]
      _, error, status = capture(directory, ruby_args: ruby_args)
      expect(status.exitstatus).to eq(4)
      expect(error).to include("baseline failed: timeout")
      expect(File).not_to exist(artifact(directory))

      _, error, status = capture(directory, "--timeout-base", "5000000", ruby_args: ruby_args)
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(File.read(artifact(directory))).fetch("tests").keys).to eq(%w[SampleTest#test_calculate SampleTest#test_positive])
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
      expect(map.fetch("test_load_order")).to eq(["spec/sample_spec.rb"])
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
      expect(map).to include("opaque_load" => true, "unresolved_files" => ["lib/sample.rb"])
      expect(map.fetch("deferred_methods").map { |key| key.split(":").last }).to eq(["deferred"])
    end
  end

  it "fingerprints explicit boot files and changes to boot directory reads" do
    boot = "Dir['generated/*.txt']\n"
    files = { ".gitignore" => "/generated/\n", "boot.rb" => boot,
              "lib/sample.rb" => source, "test/sample_test.rb" => test_code }
    with_project(files) do |directory|
      _, error, status = capture(directory, "--boot", "boot.rb")
      expect(status.exitstatus).to eq(0), error
      first = JSON.parse(File.read(artifact(directory)))
      expect(first.fetch("boot_inputs")).to include("boot.rb" => Digest::SHA256.hexdigest(boot))
      expect(first.fetch("opaque_load")).to be(false)

      generated = File.join(directory, "generated")
      FileUtils.mkdir_p(generated)
      File.write(File.join(generated, "input.txt"), "input\n")
      _, error, status = capture(directory, "--boot", "boot.rb")
      expect(status.exitstatus).to eq(0), error
      second = JSON.parse(File.read(artifact(directory)))
      expect(second).to include("base" => first.fetch("base"), "opaque_load" => false)
      expect(second.fetch("load_reads")).not_to eq(first.fetch("load_reads"))
    end
  end

  it "marks boot reads that return file metadata as opaque" do
    with_project("boot.rb" => "File.stat('lib/sample.rb')\n", "lib/sample.rb" => source, "test/sample_test.rb" => test_code) do |directory|
      _, error, status = capture(directory, "--boot", "boot.rb")
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(File.read(artifact(directory))).fetch("opaque_load")).to be(true)
    end
  end

  it "fingerprints scalar boot reads without publishing their contents" do
    boot = <<~RUBY
      raise unless File.size?('empty.txt').nil?
      raise unless File.file?('input.txt')
      raise if File.exist?('missing.txt')
      raise unless File.size('input.txt') == 16
      raise unless File.binread('input.txt') == 'load-only-secret'
      raise unless Dir['input.*'] == ['input.txt']
    RUBY
    files = { "boot.rb" => boot, "input.txt" => "load-only-secret", "empty.txt" => "",
              "lib/sample.rb" => source, "test/sample_test.rb" => test_code }
    with_project(files) do |directory|
      _, error, status = capture(directory, "--boot", "boot.rb")
      expect(status.exitstatus).to eq(0), error
      raw = File.read(artifact(directory))
      map = JSON.parse(raw)
      expect(map.fetch("opaque_load")).to be(false)
      expect(map.fetch("load_reads")).to match(/\A[0-9a-f]{64}\z/)
      expect(map.fetch("load_reads")).not_to eq(Digest::SHA256.hexdigest(""))
      expect(raw).not_to include("load-only-secret")
    end
  end

  [2 * 1024 * 1024, (2 * 1024 * 1024) + 1].each do |bytes|
    it "#{bytes == 2 * 1024 * 1024 ? 'fingerprints' : 'marks opaque'} a boot read returning #{bytes} bytes" do
      files = { "boot.rb" => "File.binread('input.txt')\n", "input.txt" => "x" * bytes,
                "lib/sample.rb" => source, "test/sample_test.rb" => test_code }
      with_project(files) do |directory|
        _, error, status = capture(directory, "--boot", "boot.rb")
        expect(status.exitstatus).to eq(0), error
        expect(JSON.parse(File.read(artifact(directory))).fetch("opaque_load")).to eq(bytes > 2 * 1024 * 1024)
      end
    end
  end

  { "1024 short lines" => ["x\n" * 1024, false], "1025 short lines" => ["x\n" * 1025, true],
    "a 4096-byte line" => ["x" * 4096, false], "a 4097-byte line" => ["x" * 4097, true] }.each do |name, (input, opaque)|
    it "#{opaque ? 'marks opaque' : 'fingerprints'} a boot read returning #{name}" do
      files = { "boot.rb" => "File.readlines('input.txt')\n", "input.txt" => input,
                "lib/sample.rb" => source, "test/sample_test.rb" => test_code }
      with_project(files) do |directory|
        _, error, status = capture(directory, "--boot", "boot.rb")
        expect(status.exitstatus).to eq(0), error
        expect(JSON.parse(File.read(artifact(directory))).fetch("opaque_load")).to eq(opaque)
      end
    end
  end

  it "marks a boot with more than 10000 file observations opaque" do
    files = { "boot.rb" => "10_001.times { File.exist?('missing.txt') }\n",
              "lib/sample.rb" => source, "test/sample_test.rb" => test_code }
    with_project(files) do |directory|
      _, error, status = capture(directory, "--boot", "boot.rb")
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(File.read(artifact(directory))).fetch("opaque_load")).to be(true)
    end
  end

  { 7 => false, 9 => true }.each do |reads, opaque|
    it "#{opaque ? 'marks opaque' : 'fingerprints'} a boot that reads #{reads * 2} MiB in bounded chunks" do
      files = { "boot.rb" => "#{reads}.times { File.binread('input.txt') }\n", "input.txt" => "x" * (2 * 1024 * 1024),
                "lib/sample.rb" => source, "test/sample_test.rb" => test_code }
      with_project(files) do |directory|
        _, error, status = capture(directory, "--boot", "boot.rb")
        expect(status.exitstatus).to eq(0), error
        expect(JSON.parse(File.read(artifact(directory))).fetch("opaque_load")).to eq(opaque)
      end
    end
  end

  %w[test/fixtures/input.txt spec/fixtures/input.txt test/input.txt test/fixtures/link.txt].each do |path|
    fixture = %w[test/fixtures/input.txt spec/fixtures/input.txt].include?(path)
    it "#{fixture ? 'trusts' : 'marks opaque'} a test reading #{path} through an open file" do
      tests = test_code.sub("def test_calculate = assert_equal(3, Sample.calculate)", <<~RUBY.chomp)
        def test_calculate
          file = File.open(File.expand_path(#{path.inspect}))
          assert_equal("fixture\\n", file.read)
          file.close
          assert_equal(3, Sample.calculate)
        end
      RUBY
      files = { "lib/sample.rb" => source, "test/sample_test.rb" => tests, "test/input.txt" => "fixture\n" }
      files[path] = "fixture\n" unless path.end_with?("/link.txt")
      with_project(files) do |directory|
        if path.end_with?("/link.txt")
          FileUtils.mkdir_p(File.join(directory, "test/fixtures"))
          File.symlink("../input.txt", File.join(directory, path))
          git(directory, "add", path)
          git(directory, "-c", "user.name=Ripr Test", "-c", "user.email=test@example.test", "commit", "-qm", "fixture link")
        end
        _, error, status = capture(directory)
        expect(status.exitstatus).to eq(0), error
        map = JSON.parse(File.read(artifact(directory)))
        expect(map.fetch("opaque_load")).to be(false)
        expect(map.fetch("opaque_tests")).to eq(fixture ? [] : ["SampleTest#test_calculate"])
        expect(map.fetch("test_files")).to include(path => Digest::SHA256.hexdigest("fixture\n"))
      end
    end
  end

  it "fingerprints RSpec options outside the project without exposing their path" do
    Dir.mktmpdir("ripr-reach-rspec-config") do |config|
      options = File.join(config, "rspec", "options")
      FileUtils.mkdir_p(File.dirname(options))
      File.write(options, "# suite options\n")
      with_project do |directory|
        _, error, status = capture(directory, environment: { "XDG_CONFIG_HOME" => config })
        expect(status.exitstatus).to eq(0), error
        raw = File.read(artifact(directory))
        expect(raw).not_to include(config)
        expect(JSON.parse(raw).fetch("external_inputs")).to include(
          Digest::SHA256.hexdigest(options) => Digest::SHA256.file(options).hexdigest
        )
      end
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
