# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "yaml"
require "prism"
require "ripr/engine/result_cache"
require "ripr/config"
require "bundler"

RSpec.describe "incremental ripr commands" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }
  let(:fixture) { File.expand_path("../test/fixtures/projects/minitest_basic", __dir__) }

  def with_project
    Dir.mktmpdir("ripr-cache") do |directory|
      FileUtils.cp_r(File.join(fixture, "."), directory)
      cache = File.join(directory, ".ripr")
      FileUtils.remove_entry(cache) if File.directory?(cache)
      git(directory, "init", "-q")
      git(directory, "config", "user.name", "Ripr Test")
      git(directory, "config", "user.email", "test@example.test")
      git(directory, "add", "lib", "test")
      git(directory, "commit", "-qm", "fixture")
      yield directory
    end
  end

  def git(directory, *arguments)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments)
    raise error unless status.success?

    output
  end

  def command(directory, *arguments, expected: 0)
    output, error, status = Open3.capture3(RbConfig.ruby, executable, "--reporter", "agent", "--operators", "comparison", *arguments,
                                           chdir: directory)
    expect(status.exitstatus).to eq(expected), error
    [output.empty? ? nil : JSON.parse(output), error]
  end

  def snapshot(directory)
    JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
  end

  %w[load_iseq require].each do |mode|
    it "rejects source preloaded without instrumentation using #{mode}" do
      with_project do |directory|
        source = File.join(directory, "lib/sample.rb")
        output, error, status = Open3.capture3({ "RIPR_LOADER" => mode }, RbConfig.ruby, "-r", source, executable,
                                               "--full", "--reporter", "agent", chdir: directory)
        expect(status.exitstatus).to eq(1), error
        expect(error).to include("lib/sample.rb", "loaded before ripr")
        expect(output).to be_empty
        expect(File.exist?(File.join(directory, ".ripr/snapshot.json"))).to be(false)
      end
    end
  end

  it "allows preloaded files that have no selected mutation sites" do
    with_project do |directory|
      helper = File.join(directory, "lib/constants.rb")
      File.write(helper, "module PreloadedConstants; VALUE = 7; end\n")
      output, error, status = Open3.capture3(RbConfig.ruby, "-r", helper, executable, "--operators", "comparison",
                                             "--full", "--reporter", "agent", chdir: directory)
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(output).fetch("gaps").first.fetch("kind")).to eq("not_infected")
    end
  end

  it "recognizes a preloaded target through a realpath alias" do
    with_project do |directory|
      source = File.join(directory, "lib/sample.rb")
      alias_path = File.join(directory, "preload.rb")
      File.symlink(source, alias_path)
      output, error, status = Open3.capture3(RbConfig.ruby, "-r", alias_path, executable, "--full", "--reporter", "agent",
                                             chdir: directory)
      expect(status.exitstatus).to eq(1), error
      expect(error).to include("lib/sample.rb", "loaded before ripr")
      expect(output).to be_empty
    end
  end

  it "selects changed nodes or their entire method and treats --full as a full run" do
    with_project do |directory|
      source_path = File.join(directory, "lib/sample.rb")
      source = File.read(source_path).sub("age >= 18", "limit = 18\n    age >= limit")
      File.write(source_path, source)
      git(directory, "add", "lib/sample.rb")
      git(directory, "commit", "-qm", "two-line method")
      File.write(source_path, source.sub("limit = 18", "limit = 19"))
      report, = command(directory, "--since", "HEAD", "--scope", "node")
      expect(report.fetch("gaps")).to be_empty
      expect(report.fetch("summary").fetch("not_reached")).to eq(0)
      report, = command(directory, "--since", "HEAD", "--scope", "method")
      expect(report.fetch("gaps").map { |gap| gap.fetch("subject") }).to eq(["Sample.adult?"])
      report, = command(directory, "--full", "--since", "HEAD", "--scope", "node")
      expect(report.fetch("gaps").map { |gap| gap.fetch("subject") }).to include("Sample.adult?")
    end
  end

  it "selects new source files and validates --only ids" do
    with_project do |directory|
      File.write(File.join(directory, "lib/extra file.rb"), "module Extra; def self.adult?(age); age >= 18; end; end\n")
      report, = command(directory, "--since", "HEAD")
      expect(report.fetch("gaps").map { |gap| gap.fetch("subject") }).to eq(["Extra.adult?"])
      _, error = command(directory, "--only", "missing-id", expected: 1)
      expect(error).to include("unknown mutant")
    end
  end

  it "observes only selected sites and refreshes evidence when the scope expands" do
    with_project do |directory|
      source = File.join(directory, "lib/sample.rb")
      File.write(source, <<~RUBY)
        module Sample
          def self.first?(value); value >= 18; end
          def self.second?(value); value >= 18; end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class SampleTest < Minitest::Test
          def test_both
            assert Sample.first?(20)
            assert Sample.second?(18)
          end
        end
      RUBY
      git(directory, "add", "lib", "test")
      git(directory, "commit", "-qm", "two comparisons")
      File.write(source, File.read(source).sub("first?(value); value >= 18", "first?(value); value >= 19"))

      command(directory, "--since", "HEAD")
      narrow = snapshot(directory)
      expect(narrow.fetch("mutants").values.map { |m| m.fetch("subject") }).to eq(["Sample.first?"])
      first = narrow.fetch("mutants").values.first
      expect(first.fetch("status")).to eq("not_infected")
      expect(narrow.fetch("baseline").fetch("probe").fetch("reach").keys).to eq([first.fetch("site")])

      command(directory, "--since", "HEAD")
      expect(snapshot(directory).fetch("metrics")).to include("baseline_tests_run" => 0, "reused" => 1)

      command(directory)
      expanded = snapshot(directory)
      expect(expanded.fetch("metrics").fetch("baseline_tests_run")).to eq(1)
      expect(expanded.fetch("mutants").values.to_h { |m| m.values_at("subject", "status") })
        .to eq("Sample.first?" => "not_infected", "Sample.second?" => "killed")
    end
  end

  it "reuses an unchanged baseline and results but verifies an explicit --only request" do
    with_project do |directory|
      report, = command(directory)
      boundary = report.fetch("gaps").find { |gap| gap.fetch("subject") == "Sample.adult?" }
      expect(snapshot(directory).fetch("metrics")).to include("baseline_tests_run" => 2, "reused" => 0)
      command(directory)
      expect(snapshot(directory).fetch("metrics")).to include("baseline_reused" => true, "baseline_tests_run" => 0, "reused" => 1)
      report, = command(directory, "--only", boundary.fetch("id"))
      expect(report.fetch("gaps").first.fetch("kind")).to eq("not_infected")
      expect(snapshot(directory).fetch("metrics").fetch("reused")).to eq(0)
      expect(snapshot(directory).fetch("mutants").fetch(boundary.fetch("full_id"))).to have_key("verified")
    end
  end

  it "runs only new tests in the baseline and invalidates a formerly unreached mutation" do
    with_project do |directory|
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.adult?(age); age >= 18; end
          def self.unused(age); age >= 18; end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class SampleTest < Minitest::Test
          def test_adult
            assert Sample.adult?(20)
          end
        end
      RUBY
      command(directory)
      File.write(File.join(directory, "test/boundary_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class BoundaryTest < Minitest::Test
          def test_unused_boundary
            assert Sample.unused(18)
          end
        end
      RUBY
      command(directory)
      data = snapshot(directory)
      expect(data.fetch("metrics")).to include("baseline_reused" => true, "baseline_tests_run" => 1, "reused" => 0)
      unused = data.fetch("mutants").values.find { |mutant| mutant.fetch("subject") == "Sample.unused" }
      expect(unused.fetch("status")).to eq("killed")
      expect(data.fetch("baseline").fetch("tests").keys).to include("SampleTest#test_adult", "BoundaryTest#test_unused_boundary")
      File.unlink(File.join(directory, "test/boundary_test.rb"))
      command(directory)
      data = snapshot(directory)
      unused = data.fetch("mutants").values.find { |mutant| mutant.fetch("subject") == "Sample.unused" }
      expect(unused.fetch("status")).to eq("not_reached")
      expect(data.fetch("baseline").fetch("tests").keys).to eq(["SampleTest#test_adult"])
      observed_left = data.fetch("baseline").fetch("probe").fetch("samples").values.flatten(1).map(&:first)
      expect(observed_left).not_to include(18)
    end
  end

  it "invalidates unchanged caller results when a different target method changes" do
    with_project do |directory|
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.limit; 18; end
          def self.adult?(age); age >= limit; end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class SampleTest < Minitest::Test
          def test_boundary; assert Sample.adult?(18); end
        end
      RUBY
      command(directory)
      before = snapshot(directory)
      expect(before.fetch("mutants").values.first.fetch("status")).to eq("killed")
      source_path = File.join(directory, "lib/sample.rb")
      File.write(source_path, File.read(source_path).sub("self.limit; 18", "self.limit; 17"))
      report, = command(directory)
      expect(report.fetch("gaps").first.fetch("kind")).to eq("not_infected")
      after = snapshot(directory)
      expect(after.fetch("mutants").values.first.fetch("method_hash")).to eq(before.fetch("mutants").values.first.fetch("method_hash"))
      expect(after.fetch("metrics")).to include("baseline_reused" => false, "baseline_tests_run" => 1, "reused" => 0)
    end
  end

  it "retains not_infected when verification succeeds and preserves cache after a failed baseline" do
    with_project do |directory|
      report, = command(directory, "--verify-not-infected")
      expect(report.fetch("gaps").first.fetch("kind")).to eq("not_infected")
      cache_path = File.join(directory, ".ripr/snapshot.json")
      previous = File.read(cache_path)
      File.write(File.join(directory, "test/failing_test.rb"), <<~RUBY)
        require "minitest/autorun"
        class FailingTest < Minitest::Test
          def test_failure; flunk "broken baseline"; end
        end
      RUBY
      command(directory, expected: 4)
      expect(File.read(cache_path)).to eq(previous)
    end
  end

  it "applies valid acceptances during planning and warns when their method changes" do
    with_project do |directory|
      command(directory)
      boundary = snapshot(directory).fetch("mutants").values.first
      ledger = [boundary.slice("full_id", "method_hash").merge("reason" => "Equivalent for the specified domain")]
      File.write(File.join(directory, "ripr.accepted.yml"), ledger.to_yaml)
      report, = command(directory)
      expect(report.fetch("summary").fetch("accepted")).to eq(1)
      source_path = File.join(directory, "lib/sample.rb")
      File.write(source_path, File.read(source_path).sub("age >= 18", "age >= 19"))
      report, error = command(directory)
      expect(report.fetch("summary").fetch("accepted")).to eq(0)
      expect(error).to include("stale acceptance")
    end
  end

  it "merges RSpec baseline results when a new example file reaches the boundary" do
    with_project do |directory|
      FileUtils.remove_entry(File.join(directory, "test"))
      rspec_fixture = fixture.sub("minitest_basic", "rspec_basic")
      FileUtils.cp_r(File.join(rspec_fixture, "spec"), File.join(directory, "spec"))
      command(directory)
      command(directory)
      expect(snapshot(directory).fetch("metrics")).to include("baseline_reused" => true, "baseline_tests_run" => 0, "reused" => 1)
      File.write(File.join(directory, "spec/boundary_spec.rb"), <<~RUBY)
        require_relative "../lib/sample"
        RSpec.describe "adult boundary" do
          it "accepts eighteen" do
            expect(Sample.adult?(18)).to be(true)
          end
        end
      RUBY
      command(directory)
      data = snapshot(directory)
      expect(data.fetch("metrics")).to include("baseline_reused" => true, "baseline_tests_run" => 1, "reused" => 0)
      expect(data.fetch("mutants").values.first.fetch("status")).to eq("killed")
      expect(data.fetch("baseline").fetch("tests").length).to eq(3)
    end
  end

  it "rebuilds the baseline after auxiliary test data changes" do
    with_project do |directory|
      FileUtils.mkdir_p(File.join(directory, "test/fixtures"))
      data_path = File.join(directory, "test/fixtures/input.txt")
      File.write(data_path, "one")
      command(directory)
      File.write(data_path, "two")
      command(directory)
      expect(snapshot(directory).fetch("metrics")).to include("baseline_reused" => false, "baseline_tests_run" => 2, "reused" => 0)
    end
  end

  it "reports a verification discrepancy when externally stateful tests change their outcome" do
    with_project do |directory|
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class SampleTest < Minitest::Test
          def test_adult
            assert Sample.adult?(20)
            flunk "test depends on prior execution" if File.exist?("external-state")
            File.write("external-state", "baseline ran")
          end
        end
      RUBY
      report, error = command(directory, "--verify-not-infected")
      expect(report.fetch("summary").fetch("killed")).to eq(1)
      expect(error).to include("verification discrepancy")
    end
  end

  it "hashes target source bytes without requiring UTF-8 text" do
    Dir.mktmpdir("ripr-source-hash") do |directory|
      Dir.chdir(directory) do
        config = { full: false, only: [], operators: ["comparison"], arid_callees: [], tests: nil, samples: true,
                   seed: 0, timeout: {}, jobs: 1, verify_not_infected: false }
        cache = Ripr::Engine::ResultCache.new(config, sources: { "lib/a.rb" => "\xFF".b }, test_files: [], test_ids: [], probe_sites: [],
                                                      framework: "minitest", mutants: [])
        expect(cache.source_hash).to match(/\A[0-9a-f]{64}\z/)
      end
    end
  end

  it "invalidates results when framework-selected test identities change without a file edit" do
    with_project do |directory|
      Dir.chdir(directory) do
        config = Ripr::Config.load({ operators: ["comparison"] })
        mutant = { "id" => "sample", "full_id" => "sample::comparison", "method_hash" => "method" }
        arguments = { sources: { "lib/sample.rb" => File.read("lib/sample.rb") }, test_files: ["test/sample_test.rb"],
                      framework: "minitest", mutants: [mutant], probe_sites: [] }
        cache = Ripr::Engine::ResultCache.new(config, **arguments, test_ids: ["SampleTest#old"])
        cache.write([mutant.merge("status" => "not_infected", "observed" => [], "covering_tests" => [])], {}, {})
        unchanged = Ripr::Engine::ResultCache.new(config, **arguments, test_ids: ["SampleTest#old"])
        expect(unchanged.result_for(mutant)).not_to be_nil
        changed = Ripr::Engine::ResultCache.new(config, **arguments, test_ids: ["SampleTest#old", "SampleTest#new"])
        expect(changed.result_for(mutant)).to be_nil
      end
    end
  end

  it "invalidates a copied cache when the checkout path changes program behavior" do
    Dir.mktmpdir("ripr-path-cache") do |temporary|
      base = File.realpath(temporary)
      first = File.join(base, "long-checkout-name")
      second = File.join(base, "x")
      FileUtils.mkdir_p(first)
      FileUtils.mkdir_p(second)
      FileUtils.cp_r(File.join(fixture, "."), first)
      threshold = File.join(second, "lib").length
      File.write(File.join(first, "lib/sample.rb"), "module Sample; def self.check; __dir__.length >= #{threshold}; end; end\n")
      File.write(File.join(first, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class PathTest < Minitest::Test
          def test_path
            assert Sample.check
          end
        end
      RUBY
      report, = command(first)
      expect(report.fetch("summary").fetch("not_infected")).to eq(1)
      FileUtils.cp_r(File.join(first, "."), second)
      report, = command(second)
      expect(report.fetch("summary").fetch("killed")).to eq(1)
      expect(snapshot(second).fetch("metrics").fetch("reused")).to eq(0)
    end
  end

  it "invalidates results when the active bundle lockfile outside the project changes" do
    Dir.mktmpdir("ripr-bundle") do |bundle_directory|
      gemfile = File.join(bundle_directory, "AlternateGemfile")
      lockfile = "#{gemfile}.lock"
      File.write(gemfile, "source 'https://rubygems.org'\n")
      File.write(lockfile, "original bundle\n")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("BUNDLE_GEMFILE").and_return(gemfile)
      allow(Bundler).to receive(:default_lockfile).and_return(Pathname.new(lockfile))
      with_project do |directory|
        Dir.chdir(directory) do
          config = Ripr::Config.load({ operators: ["comparison"] })
          mutant = { "id" => "sample", "full_id" => "sample::comparison", "method_hash" => "method" }
          arguments = { sources: { "lib/sample.rb" => File.read("lib/sample.rb") }, test_files: ["test/sample_test.rb"],
                        framework: "minitest", mutants: [mutant], test_ids: ["SampleTest#test"], probe_sites: [] }
          cache = Ripr::Engine::ResultCache.new(config, **arguments)
          cache.write([mutant.merge("status" => "not_infected", "observed" => [], "covering_tests" => [])], {}, {})
          expect(Ripr::Engine::ResultCache.new(config, **arguments).result_for(mutant)).not_to be_nil
          File.write(lockfile, "updated bundle\n")
          expect(Ripr::Engine::ResultCache.new(config, **arguments).result_for(mutant)).to be_nil
        end
      end
    end
  end

  %w[minitest rspec].each do |framework|
    it "keeps #{framework} load diagnostics out of agent stdout" do
      with_project do |directory|
        test_directory = "test"
        test_file = "sample_test.rb"
        if framework == "rspec"
          FileUtils.remove_entry(File.join(directory, "test"))
          rspec_fixture = fixture.sub("minitest_basic", "rspec_basic")
          FileUtils.cp_r(File.join(rspec_fixture, "spec"), File.join(directory, "spec"))
          test_directory = "spec"
          test_file = "sample_spec.rb"
        end
        source_path = File.join(directory, "lib/sample.rb")
        File.write(source_path, "STDOUT.write(\"application diagnostic\\n\")\n#{File.read(source_path)}")
        helper_path = File.join(directory, test_directory, "helper.rb")
        File.write(helper_path, "puts \"helper diagnostic\"\n")
        test_path = File.join(directory, test_directory, test_file)
        File.write(test_path, "puts \"test diagnostic\"\nrequire_relative \"helper\"\n#{File.read(test_path)}")
        report, error = command(directory)
        expect(report.fetch("schema")).to eq("ripr.agent/v1")
        expect(error).to include("application diagnostic", "helper diagnostic", "test diagnostic")
      end
    end
  end

  it "restores stdout when test loading raises" do
    with_project do |directory|
      File.write(File.join(directory, "test/sample_test.rb"), "puts 'load diagnostic'; raise 'load failed'\n")
      script = "require 'ripr/cli'; status = Ripr::CLI.start(['--reporter', 'agent']); STDOUT.write(JSON.generate({'status' => status}))"
      output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script, chdir: directory)
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(output)).to eq("status" => 3)
      expect(error).to include("load diagnostic", "load failed")
    end
  end

  it "ignores damaged nested result and baseline cache data" do
    with_project do |directory|
      command(directory)
      cache_path = File.join(directory, ".ripr/snapshot.json")
      data = snapshot(directory)
      original = JSON.generate(data)
      record_id = data.fetch("mutants").keys.first
      damage = [
        ->(copy) { copy.fetch("mutants").fetch(record_id)["covering_tests"] = [1] },
        ->(copy) { copy.fetch("mutants").fetch(record_id)["covering_tests"] = [{ "id" => "test", "file" => 1, "line" => "one" }] },
        ->(copy) { copy.fetch("mutants").fetch(record_id)["observed"] = [1] },
        ->(copy) { copy.fetch("baseline").fetch("tests").values.first["duration_ms"] = -1 },
        ->(copy) { copy.fetch("baseline").fetch("probe").fetch("reach").values.first << "unknown-test-id" },
        ->(copy) { copy.fetch("baseline").fetch("probe").fetch("samples").values.first << 1 }
      ]
      damage.each do |corrupt|
        copy = JSON.parse(original)
        corrupt.call(copy)
        File.write(cache_path, JSON.generate(copy))
        report, = command(directory)
        expect(report.fetch("gaps").first.fetch("kind")).to eq("not_infected")
        updated = snapshot(directory)
        if copy.fetch("baseline") == data.fetch("baseline")
          expect(updated.fetch("metrics").fetch("reused")).to eq(0)
        else
          expect(updated.fetch("metrics").fetch("baseline_tests_run")).to eq(2)
        end
      end
    end
  end
end
