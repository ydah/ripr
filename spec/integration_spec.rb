# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

RSpec.describe "test framework adapters" do
  def isolated_adapter(framework, source, body)
    script = <<~RUBY
      require "json"
      require "tmpdir"
      require "ripr/runtime"
      require "ripr/integration/#{framework}"
      Dir.mktmpdir("ripr-adapter") do |dir|
        Dir.chdir(dir) do
          file = File.join(dir, "#{framework == 'minitest' ? 'sample_test' : 'sample_spec'}.rb")
          File.write(file, #{source.dump})
          #{body}
        end
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
    expect(status.success?).to be(true), stderr
    JSON.parse(stdout)
  end

  let(:minitest_source) do
    <<~RUBY
      require "minitest/autorun"
      class AdapterTest < Minitest::Test
        def setup
          $scopes ||= []
          $scopes << Ripr::R.current_test
        end
        def teardown
          $scopes << Ripr::R.current_test
        end
        def test_pass
          $runs = ($runs || 0) + 1
          assert true
        end
        def test_fail
          flunk "missing assertion"
        end
      end
    RUBY
  end

  let(:rspec_source) do
    <<~RUBY
      require "rspec/autorun"
      RSpec.describe "adapter" do
        before { ($scopes ||= []) << Ripr::R.current_test }
        after { $scopes << Ripr::R.current_test }
        it("passes") { $runs = ($runs || 0) + 1; expect(true).to eq(true) }
        it("fails") { expect(true).to eq(false) }
      end
    RUBY
  end

  { "minitest" => "Minitest", "rspec" => "RSpec" }.each do |framework, klass|
    it "loads #{framework} definitions without running or autorun" do
      result = isolated_adapter(framework, public_send("#{framework}_source"), <<~RUBY)
        adapter = Ripr::Integration::#{klass}.new([file], seed: 12)
        adapter.load
        puts JSON.generate([adapter.tests, $runs])
      RUBY
      expect(result[0].size).to eq(2)
      expect(result[0].all? { |test| test.fetch("file").end_with?(".rb") && test.fetch("line").positive? }).to be(true)
      expect(result[1]).to be_nil
    end

    it "runs selected #{framework} tests and covers setup and teardown with the current ID" do
      selector = framework == "minitest" ? 'test["id"].end_with?("#test_pass")' : 'test["id"].end_with?("[1:1]")'
      result = isolated_adapter(framework, public_send("#{framework}_source"), <<~RUBY)
        adapter = Ripr::Integration::#{klass}.new([file], seed: 12).load
        id = adapter.tests.find { |test| #{selector} }.fetch("id")
        result = adapter.run([id])
        puts JSON.generate([result, $scopes, $runs, id, Ripr::R.current_test])
      RUBY
      expect(result[0].fetch("success")).to be(true)
      expect(result[0].fetch("tests").keys).to eq([result[3]])
      expect(result[0].fetch("tests").fetch(result[3]).fetch("duration_ms")).to be >= 0
      expect(result[1]).to eq([result[3], result[3]])
      expect(result[2]).to eq(1)
      expect(result[4]).to be_nil
    end

    it "returns #{framework} failures and honors fail-fast" do
      selector = framework == "minitest" ? 'test["id"].end_with?("#test_fail")' : 'test["id"].end_with?("[1:2]")'
      result = isolated_adapter(framework, public_send("#{framework}_source"), <<~RUBY)
        adapter = Ripr::Integration::#{klass}.new([file], seed: 12).load
        failed_id = adapter.tests.find { |test| #{selector} }.fetch("id")
        ids = [failed_id] + adapter.tests.map { |test| test.fetch("id") }.reject { |id| id == failed_id }
        result = adapter.run(ids, fail_fast: true)
        puts JSON.generate([result, $runs])
      RUBY
      expect(result[0].fetch("success")).to be(false)
      expect(result[0].fetch("failures")).not_to be_empty
      expect(result[0].fetch("tests").size).to eq(1)
      expect(result[1]).to be_nil
    end

    it "rejects unknown #{framework} test IDs and does not treat an empty suite as success" do
      result = isolated_adapter(framework, "", <<~RUBY)
        adapter = Ripr::Integration::#{klass}.new([file], seed: 12).load
        message = begin
          adapter.run(["missing-test"])
          nil
        rescue ArgumentError => error
          error.message
        end
        puts JSON.generate([message, adapter.run])
      RUBY
      expect(result[0]).to include("test")
      expect(result[1].fetch("success")).to be(false)
      expect(result[1].fetch("failures")).not_to be_empty
    end
  end

  it "returns the diagnostic for an RSpec suite hook failure" do
    source = <<~RUBY
      RSpec.configure { |config| config.before(:suite) { raise "suite boot failure" } }
      RSpec.describe("suite") { it("passes") { expect(true).to be(true) } }
    RUBY
    result = isolated_adapter("rspec", source, <<~RUBY)
      adapter = Ripr::Integration::RSpec.new([file]).load
      puts JSON.generate(adapter.run)
    RUBY
    expect(result.fetch("success")).to be(false)
    expect(result.fetch("failures").map { |failure| failure.fetch("message") }.join).to include("suite boot failure")
  end

  it "preserves an RSpec file loading failure even if examples were defined first" do
    source = <<~RUBY
      RSpec.describe("suite") { it("passes") { expect(true).to be(true) } }
      raise "load boot failure"
    RUBY
    result = isolated_adapter("rspec", source, <<~RUBY)
      adapter = Ripr::Integration::RSpec.new([file]).load
      puts JSON.generate(adapter.run)
    RUBY
    expect(result.fetch("success")).to be(false)
    expect(result.fetch("failures").map { |failure| failure.fetch("message") }.join).to include("load boot failure")
  end
end
