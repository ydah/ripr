# frozen_string_literal: true

require "json"
require "tmpdir"
require "ripr/config"
require "ripr/core/analyzer"
require "ripr/core/instrumenter"
require "ripr/engine/child"
require "ripr/engine/runner"
require "ripr/loader"
require "ripr/engine/method_exits"

RSpec.describe Ripr::Engine::MethodExits do
  let(:subject_class) do
    Class.new do
      def compute(value)
        return [1, compute(value - 1)] if value.is_a?(Integer) && value.positive?

        value
      end

      def fail_with(error)
        raise error
      end

      def delegate(error)
        fail_with(error)
      end

      def suppress(error)
        fail_with(error)
      ensure
        return nil # rubocop:disable Lint/EnsureReturn -- Exercise an intentionally suppressed exception.
      end

      def nonlocal
        throw :exit_test
      end
    end
  end

  after { Ripr::R.reset }

  def as_test(id)
    Ripr::R.current_test = id
    yield
  ensure
    Ripr::R.current_test = nil
  end

  def returned(value)
    ["return", Ripr::Value.snapshot(value)]
  end

  def with_target_source(source)
    Dir.mktmpdir("ripr-method-targets") do |directory|
      Dir.chdir(directory) do
        path = "sample.rb"
        File.write(path, source)
        config = Ripr::Config.load({ operators: ["comparison"] })
        yield Ripr::Engine::Runner.new(config, [path]).plan, path
      end
    end
  ensure
    Object.send(:remove_const, :MethodExitsResolveFixture) if defined?(MethodExitsResolveFixture)
    Object.send(:remove_method, :ripr_resolver_top_level) if Object.private_method_defined?(:ripr_resolver_top_level, false)
  end

  it "resolves loaded definitions from a Runner plan, including top-level private methods" do
    with_target_source(<<~RUBY) do |definitions, path|
      module MethodExitsResolveFixture
        class Nested
          def within?(value)
            value >= 0 && value <= 5
          end

          def self.positive?(value)
            value > 0
          end
        end
      end

      def ripr_resolver_top_level(value)
        value == 1
      end
    RUBY
      load path
      targets = described_class.targets(definitions)

      expect(targets).to eq(
        "MethodExitsResolveFixture::Nested#within?" => MethodExitsResolveFixture::Nested.instance_method(:within?),
        "MethodExitsResolveFixture::Nested.positive?" => MethodExitsResolveFixture::Nested.method(:positive?),
        "Object#ripr_resolver_top_level" => Object.instance_method(:ripr_resolver_top_level)
      )
      expect(targets).to be_frozen
      expect(described_class.public_subjects(targets)).to eq(
        "MethodExitsResolveFixture::Nested#within?" => true, "MethodExitsResolveFixture::Nested.positive?" => true
      )
    end
  end

  it "leaves autoload and missing-constant hooks untouched" do
    with_target_source(<<~RUBY) do |definitions, path|
      module MethodExitsResolveFixture
        class Unloaded
          def check(value)
            value > 0
          end
        end

        class Missing
          def check(value)
            value > 0
          end
        end
      end
    RUBY
      namespace = Module.new do
        def self.const_missing(name)
          raise "checked missing constant #{name}"
        end
      end
      Object.const_set(:MethodExitsResolveFixture, namespace)
      namespace.autoload(:Unloaded, File.expand_path(path))

      expect(described_class.targets(definitions)).to be_empty
      expect(namespace.autoload?(:Unloaded, false)).to eq(File.expand_path(path))
    end
  end

  it "resolves native method tables without invoking reflection overrides" do
    with_target_source(<<~RUBY) do |definitions, path|
      module MethodExitsResolveFixture
        class Nested
          def self.check(value)
            value >= 0
          end
        end
      end
    RUBY
      load path
      namespace = MethodExitsResolveFixture
      owner = namespace::Nested
      expected = owner.method(:check)
      %i[const_defined? const_get autoload? name].each do |name|
        namespace.define_singleton_method(name) { |*| raise "called custom #{name}" }
      end
      %i[method singleton_class instance_method name respond_to_missing?].each do |name|
        owner.define_singleton_method(name) { |*| raise "called custom #{name}" }
      end

      expect(described_class.targets(definitions)).to eq("MethodExitsResolveFixture::Nested.check" => expected)
      missing = definitions.first.with(subject: "MethodExitsResolveFixture::Nested.missing")
      expect(described_class.targets([missing])).to be_empty
    end
  end

  it "requires a unique path, definition line, and owner for each target" do
    with_target_source(<<~RUBY) do |definitions, path|
      module MethodExitsResolveFixture
        class Parent
          def check(value)
            value >= 0
          end

          alias_method :copy, :check
        end

        class Child < Parent
        end
      end
    RUBY
      load path
      definition = definitions.first
      Dir.mkdir("different")
      File.write("different/sample.rb", File.read(path))
      wrong_file = definition.with(location: definition.location.with(file: "different/sample.rb"))
      wrong_line = definition.with(method_start: definition.method_start + 1)
      alias_definition = definition.with(subject: "MethodExitsResolveFixture::Parent#copy")
      inherited = definition.with(subject: "MethodExitsResolveFixture::Child#check")
      duplicate = definition.with(subject: "#{definition.subject}[2]")

      [wrong_file, wrong_line, alias_definition, inherited, duplicate, definition.with(static: true)].each do |unresolved|
        expect(described_class.targets([unresolved])).to be_empty
      end
      expect(described_class.targets([definition, duplicate])).to be_empty
      expect(described_class.targets([definition, wrong_file])).to be_empty

      File.symlink(path, "link.rb")
      symlink = definition.with(location: definition.location.with(file: "link.rb"))
      expect(described_class.targets([symlink]).keys).to eq([definition.subject])
    end
  end

  it "records ordered exits from the selected body and keeps test identities separate" do
    instance = subject_class.new
    targets = { "Sample#compute" => subject_class.instance_method(:compute) }
    result, observations = described_class.observe(targets) do
      as_test("first") do
        instance.compute(1)
        instance.compute(false)
      end
      as_test("second") { instance.compute(:other) }
      :adapter_result
    end

    expect(result).to eq(:adapter_result)
    expect(observations).to eq("Sample#compute" => {
                                 "first" => [returned([1, 0]), returned(0), returned(false)], "second" => [returned(:other)]
                               })
    expect { JSON.generate(observations) }.not_to raise_error
  end

  it "records a verified exception unwind through nested calls" do
    instance = subject_class.new
    targets = { "Sample#delegate" => instance.method(:delegate), "Sample#fail_with" => instance.method(:fail_with) }
    _, observations = described_class.observe(targets) do
      as_test("assertion") do
        instance.delegate(ArgumentError.new("invalid"))
      rescue ArgumentError
        :handled
      end
    end

    expected = { "assertion" => [%w[raise ArgumentError]] }
    expect(observations).to eq("Sample#delegate" => expected, "Sample#fail_with" => expected)
  end

  it "keeps nil exits without proof of normal return or exception unwind ambiguous" do
    instance = subject_class.new
    targets = { "nil" => instance.method(:compute), "ensure" => instance.method(:suppress), "throw" => instance.method(:nonlocal) }
    _, observations = described_class.observe(targets) do
      as_test("example") do
        instance.compute(nil)
        instance.suppress(TypeError.new("suppressed"))
        catch(:exit_test) { instance.nonlocal }
      end
    end

    expect(observations).to eq(%w[nil ensure throw].to_h { |name| [name, { "example" => [["ambiguous_exit"]] }] })
    expect(described_class.stable(observations, observations)).to be_empty
  end

  it "does not let an unrelated rescue confirm a suppressed exception" do
    instance = subject_class.new
    error = ArgumentError.new("reused")
    _, observations = described_class.observe("Sample#suppress" => instance.method(:suppress)) do
      as_test("example") do
        instance.suppress(error)
        begin
          raise error
        rescue ArgumentError
          :handled
        end
      end
    end

    expect(observations).to eq("Sample#suppress" => { "example" => [["ambiguous_exit"]] })
  end

  it "does not attribute an already unwinding exception to a method called from ensure" do
    instance = subject_class.new
    error = ArgumentError.new("same object")
    _, observations = described_class.observe("Sample#suppress" => instance.method(:suppress)) do
      as_test("example") do
        begin
          raise error
        ensure
          instance.suppress(error)
        end
      rescue ArgumentError
        :handled
      end
    end

    expect(observations).to eq("Sample#suppress" => { "example" => [["ambiguous_exit"]] })
  end

  it "falls back for opaque values, unowned calls, and Data identities that might differ across processes" do
    instance = subject_class.new
    method = instance.method(:compute)
    _, observations = described_class.observe("Sample#compute" => method) do
      as_test("opaque") { instance.compute(Object.new) }
      as_test("data") { instance.compute([Data.define(:x).new(1)]) }
    end

    expect(observations).to eq("Sample#compute" => { "opaque" => [nil], "data" => [nil] })
    expect(described_class.stable(observations, observations)).to be_empty
    _, unowned = described_class.observe("Sample#compute" => method) { instance.compute(true) }
    expect(unowned).to eq("Sample#compute" => nil)
  end

  it "compares repeatable original observations with calls in the mutant's test subset" do
    original = { "A" => { "first" => [returned([1])], "other" => [returned(false)] }, "B" => { "first" => [returned(true)] } }
    repeated = { "A" => original.fetch("A"), "B" => { "first" => [returned(false)] } }
    stable = described_class.stable(original, repeated)
    expect(stable).to eq("A" => original.fetch("A"))

    expect(described_class.compare(stable.fetch("A"), { "first" => [returned([1])] }, ["first"])).to eq("status" => "not_propagated")
    changed = described_class.compare(stable.fetch("A"), { "first" => [returned([2])] }, ["first"])
    expect(changed).to eq("status" => "not_revealed", "propagation" => {
                            "test_id" => "first", "call" => 1, "original" => returned([1]), "mutant" => returned([2])
                          })
    expect(described_class.compare(stable.fetch("A"), { "first" => [nil] }, ["first"])).to be_nil
    expect(described_class.compare(stable.fetch("A"), {}, ["first"])).to be_nil
  end

  it "proves a change when a normal non-nil result becomes an ambiguous exit" do
    original = { "test" => [returned(true)] }
    result = described_class.compare(original, { "test" => [["ambiguous_exit"]] }, ["test"])

    expect(result.fetch("status")).to eq("not_revealed")
    expect(result.fetch("propagation").fetch("mutant")).to eq(["ambiguous_exit"])
    expect(described_class.compare({ "test" => [%w[raise ArgumentError]] }, { "test" => [["ambiguous_exit"]] }, ["test"])).to be_nil
  end

  it "reports a change in the number of calls when both runs observed the test" do
    original = { "test" => [returned(1)] }
    mutant = { "test" => [returned(1), returned(1)] }

    result = described_class.compare(original, mutant, ["test"])
    expect(result.fetch("status")).to eq("not_revealed")
    expect(result.fetch("propagation")).to include("call" => 2, "original" => ["not_called"], "mutant" => returned(1))
  end

  it "keeps observations immutable and abandons a subject that exceeds the call budget" do
    instance = subject_class.new
    targets = { "Sample#compute" => instance.method(:compute) }
    _, observations = described_class.observe(targets) { as_test("small") { instance.compute([+"entry"]) } }
    expect(observations).to be_frozen
    expect(observations.fetch("Sample#compute")).to be_frozen
    expect(observations.fetch("Sample#compute").fetch("small")).to be_frozen

    _, overflow = described_class.observe(targets) do
      as_test("large") { (described_class::MAX_CALLS_PER_TEST + 1).times { instance.compute(false) } }
    end
    expect(overflow).to eq("Sample#compute" => nil)
  end

  it "traces a method compiled by the instrumenting loader in the baseline and its fork" do
    source = <<~RUBY
      module MethodExitsFixture
        def self.adult(age)
          age >= 18
        end
      end
    RUBY
    Dir.mktmpdir("ripr-method-exits") do |directory|
      path = File.join(directory, "method_exits_fixture.rb")
      File.write(path, source)
      plan = Ripr::Core::Analyzer.call(source, path, operators: ["comparison"])
      instrumented = Ripr::Core::Instrumenter.call(source, path, plan.fetch(:sites))
      loader = Ripr::Loader.new({ path => instrumented.fetch(:code) })
      loader.install
      load path
      table = instrumented.fetch(:site_table)
      Ripr::R.configure(table)
      definitions = plan.fetch(:mutants).map { |mutant| Ripr::Engine::Mutant.from_analysis(mutant, invalid: false) }
      targets = described_class.targets(definitions)
      _, original = described_class.observe(targets) { as_test("test") { MethodExitsFixture.adult(18) } }
      child = Ripr::Engine::Child.call(timeout_ms: 2_000) do
        Ripr::R.activate(table.keys.first, 1)
        described_class.observe(targets) { as_test("test") { MethodExitsFixture.adult(18) } }.last
      end

      result = described_class.compare(original.values.first, child.values.first, ["test"])
      expect(result.fetch("status")).to eq("not_revealed")
      expect(result.fetch("propagation").values_at("original", "mutant")).to eq([returned(true), returned(false)])
    ensure
      loader&.uninstall
      Object.send(:remove_const, :MethodExitsFixture) if defined?(MethodExitsFixture)
    end
  end
end
