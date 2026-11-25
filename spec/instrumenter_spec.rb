# frozen_string_literal: true

require "ripr/core/analyzer" if File.file?(File.expand_path("../lib/ripr/core/analyzer.rb", __dir__))
require "ripr/core/instrumenter" if File.file?(File.expand_path("../lib/ripr/core/instrumenter.rb", __dir__))
require "ripr/runtime" if File.file?(File.expand_path("../lib/ripr/runtime.rb", __dir__))

RSpec.describe "source instrumentation" do
  def instrument(source, operators: ["comparison"], path: "lib/sample.rb")
    analysis = Ripr::Core::Analyzer.call(source, path, operators: operators)
    [analysis, Ripr::Core::Instrumenter.call(source, path, analysis.fetch(:sites))]
  end

  def evaluate(source, operators: ["comparison"])
    analysis, result = instrument(source, operators: operators)
    Ripr::R.configure(result.fetch(:site_table))
    scope = Module.new
    scope.module_eval(result.fetch(:code), "lib/sample.rb")
    [scope, analysis, result]
  end

  after { Ripr::R.reset if defined?(Ripr::R) }

  it "exposes a pure instrumentation entry point" do
    instrumenter = defined?(Ripr::Core::Instrumenter) && Ripr::Core::Instrumenter
    expect(instrumenter).to respond_to(:call)
  end

  it "switches comparisons and records the untested boundary" do
    scope, analysis, result = evaluate("def self.adult?(age)\n  age >= 18\nend\n")
    probe = Ripr::Probe.new(result.fetch(:site_table))
    Ripr::R.probe = probe
    Ripr::R.current_test = "test_adult"
    expect(scope.adult?(20)).to be(true)
    expect(scope.adult?(10)).to be(false)
    site = analysis.fetch(:sites).first
    expect(probe.snapshot.fetch("infect").fetch(site.fetch(:variants).first.fetch(:id), [])).to be_empty
    expect(probe.snapshot.fetch("samples").fetch(site.fetch(:key))).to eq([[20, 18], [10, 18]])
    Ripr::R.probe = nil
    Ripr::R.activate(site.fetch(:key), 1)
    expect(scope.adult?(18)).to be(false)
  end

  it "switches opt-in Ruby operators without calling replacements during the baseline" do
    source = <<~RUBY
      def self.feature(store, events)
        range = 1..2
        odds = [1, 2].select { |value| events << value; value.odd? }
        [range.include?(2), odds, 0.zero?, store.fetch(:key)]
      end
    RUBY
    operators = %w[range_endpoint collection_query predicate_method fetch_index]
    scope, analysis, result = evaluate(source, operators: operators)
    store = Object.new
    def store.fetch(key) = [:fetch, key]
    def store.[](key) = [:index, key]

    probe = Ripr::Probe.new(result.fetch(:site_table))
    Ripr::R.probe = probe
    Ripr::R.current_test = "feature"
    events = []
    expect(scope.feature(store, events)).to eq([true, [1], true, %i[fetch key]])
    expect(events).to eq([1, 2])
    expect(probe.snapshot.fetch("reach").size).to eq(4)

    Ripr::R.probe = nil
    expected = {
      "range_endpoint" => [false, [1], true, %i[fetch key]],
      "collection_query" => [true, [2], true, %i[fetch key]],
      "predicate_method" => [true, [1], false, %i[fetch key]],
      "fetch_index" => [true, [1], true, %i[index key]]
    }
    analysis.fetch(:sites).each do |site|
      Ripr::R.activate(site.fetch(:key), 1)
      expect(scope.feature(store, [])).to eq(expected.fetch(site.fetch(:operator)))
    end
  end

  it "evaluates the receiver and index once and preserves logical assignment short-circuiting" do
    source = <<~RUBY
      def self.pick(store, events)
        (events << :receiver; store)[(events << :index; :key)] ||= (events << :rhs; :fresh)
      end
    RUBY
    scope, analysis, = evaluate(source, operators: ["logical_assignment"])
    events = []
    store = Object.new
    store.define_singleton_method(:[]) do |key|
      events << [:read, key]
      :original
    end
    store.define_singleton_method(:[]=) { |key, value| events << [:write, key, value] }
    expect(scope.pick(store, events)).to eq(:original)
    expect(events).to eq([:receiver, :index, %i[read key]])

    events.clear
    Ripr::R.activate(analysis.fetch(:sites).first.fetch(:key), 1)
    expect(scope.pick(store, events)).to eq(:fresh)
    expect(events).to eq([:receiver, :index, :rhs, %i[write key fresh]])
  end

  it "disables a matched case pattern without undoing its bindings or repeating its dispatch" do
    source = <<~RUBY
      def self.pick(item)
        case item
        in [Integer => n]
          [:matched, n]
        else
          [:other, n]
        end
      end
    RUBY
    scope, analysis, result = evaluate(source, operators: ["case_in"])
    events = []
    item = Object.new
    item.define_singleton_method(:deconstruct) do
      events << :deconstruct
      [2]
    end
    probe = Ripr::Probe.new(result.fetch(:site_table))
    Ripr::R.probe = probe
    Ripr::R.current_test = "unmatched"
    expect(scope.pick(:unmatched)).to eq([:other, nil])
    expect(probe.snapshot.fetch("reach")).to be_empty
    Ripr::R.current_test = "matched"
    expect(scope.pick(item)).to eq([:matched, 2])
    expect(events).to eq([:deconstruct])

    site = analysis.fetch(:sites).first.fetch(:key)
    expect(probe.snapshot.fetch("reach").fetch(site)).to eq(["matched"])
    expect(probe.snapshot.fetch("infect").fetch(analysis.fetch(:mutants).first.fetch(:id))).to eq(["matched"])
    Ripr::R.probe = nil
    Ripr::R.activate(site, 1)
    expect(scope.pick(item)).to eq([:other, 2])
    expect(events).to eq(%i[deconstruct deconstruct])
  end

  it "does not infect the empty Array operand of native addition and subtraction" do
    source = "def self.copy(values, extra); values + extra; end"
    scope, analysis, result = evaluate(source, operators: ["arithmetic"])
    probe = Ripr::Probe.new(result.fetch(:site_table))
    Ripr::R.probe = probe
    Ripr::R.current_test = "test_empty"
    value = +"entry"
    array = [value].freeze

    copy = scope.copy(array, [])
    expect(copy).not_to equal(array)
    expect(copy).not_to be_frozen
    expect(copy.first).to equal(value)
    expect(probe.snapshot.fetch("reach").values).to eq([["test_empty"]])
    expect(probe.snapshot.fetch("infect")).to be_empty

    Ripr::R.current_test = "test_nonempty"
    expect(scope.copy(array, [value])).to eq([value, value])
    id = analysis.fetch(:mutants).first.fetch(:id)
    expect(probe.snapshot.fetch("infect").fetch(id)).to eq(["test_nonempty"])
  end

  it "treats subtraction as potentially infected if it is undefined on an Array receiver" do
    scope, analysis, result = evaluate("def self.copy(values, extra); values + extra; end", operators: ["arithmetic"])
    probe = Ripr::Probe.new(result.fetch(:site_table))
    Ripr::R.probe = probe
    Ripr::R.current_test = "test_missing"
    array = [1]
    class << array
      undef_method :-
    end

    expect(scope.copy(array, [])).to eq([1])
    id = analysis.fetch(:mutants).first.fetch(:id)
    expect(probe.snapshot.fetch("infect").fetch(id)).to eq(["test_missing"])
  end

  it "does not mark a customized Array operation equal when it restores the native definition" do
    scope, analysis, result = evaluate("def self.copy(values, extra); values + extra; end", operators: ["arithmetic"])
    probe = Ripr::Probe.new(result.fetch(:site_table))
    Ripr::R.probe = probe
    Ripr::R.current_test = "test_custom"
    array = [1]
    original = Array.instance_method(:+)
    calls = []
    Array.define_method(:+) do |extra|
      if equal?(array)
        Array.define_method(:+, original)
        calls << :custom
      end
      original.bind_call(self, extra)
    end

    expect(scope.copy(array, [])).to eq([1])
    expect(calls).to eq([:custom])
    id = analysis.fetch(:mutants).first.fetch(:id)
    expect(probe.snapshot.fetch("infect").fetch(id)).to eq(["test_custom"])
  ensure
    Array.define_method(:+, original)
  end

  it "does not speculate on equality for application arrays" do
    scope, analysis, result = evaluate("def self.matches(left, right); left == right; end")
    Ripr::R.probe = Ripr::Probe.new(result.fetch(:site_table))
    Ripr::R.current_test = "test_equality"
    left = [1, 2]
    called = false
    trace = TracePoint.new(:c_call) { |event| called = true if event.method_id == :!= && event.self.equal?(left) }

    expect(trace.enable { scope.matches(left, [1, 2]) }).to be(true)
    expect(called).to be(false)
    id = analysis.fetch(:mutants).first.fetch(:id)
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch(id)).to eq(["test_equality"])
  end

  it "evaluates operands once in the original order without capturing user locals" do
    source = <<~RUBY
      def self.compare(events)
        __ripr_l = 20
        (events << :left; __ripr_l) >= (events << :right; 18)
      end
    RUBY
    scope, = evaluate(source)
    events = []
    expect(scope.compare(events)).to be(true)
    expect(events).to eq(%i[left right])
  end

  it "preserves bytes and line numbers around Japanese, heredocs, and data" do
    source = <<~RUBY
      # 日本語
      def self.example(value)
        text = <<~TEXT
          日本語
        TEXT
        [value >= 18, text, __LINE__, __FILE__]
      end
      __END__
      ignored >= 1
    RUBY
    _, result = instrument(source)
    expect(result.fetch(:code).count("\n")).to eq(source.count("\n"))
    expect(Prism.parse(result.fetch(:code)).errors).to be_empty
    original = Module.new
    original.module_eval(source, "lib/sample.rb")
    changed = Module.new
    changed.module_eval(result.fetch(:code), "lib/sample.rb")
    expect(changed.example(20)).to eq(original.example(20))
  end

  it "keeps ids when lines are inserted before a method" do
    source = "module Sample; def self.adult?(age); age >= 18; end; end"
    before, = instrument(source)
    after, = instrument("# more lines\n\n#{source}")
    expect(before.fetch(:mutants).map { |m| m.fetch(:id) }).to eq(after.fetch(:mutants).map { |m| m.fetch(:id) })
    expect(before.fetch(:mutants).first.fetch(:subject)).to eq("Sample.adult?")
  end

  it "uses independent sites in different files" do
    first, = instrument("def self.x(a); a >= 18; end", path: "lib/a.rb")
    second, = instrument("def self.x(a); a >= 18; end", path: "lib/b.rb")
    expect(first.fetch(:sites).first.fetch(:key)).not_to eq(second.fetch(:sites).first.fetch(:key))
  end

  it "does not instrument explicit method calls or top-level expressions" do
    analysis, = instrument("TOP = 1 >= 0; def self.x(a); a.>=(18); end")
    expect(analysis.fetch(:mutants)).to be_empty
    expect(analysis.fetch(:static)).to be >= 1
  end

  it "discovers all default operators and valid nested rewrites" do
    source = "module Sample; def self.run(a, b); a + 1; if a >= 18 && b; true; else; false; end; end; end"
    analysis, result = instrument(source, operators: Ripr::Core::Analyzer::OPERATORS)
    expect(analysis.fetch(:mutants).map { |m| m.fetch(:operator) }.uniq.sort).to eq(
      %w[arithmetic boolean_connector boolean_literal comparison condition_negation integer_literal return_nil statement_removal]
    )
    expect(Prism.parse(result.fetch(:code)).errors).to be_empty
    expect(result.fetch(:code).count("\n")).to eq(source.count("\n"))
  end

  it "honors inline disable comments and skips arid statement deletion" do
    source = "def self.run(a)\n  puts a\n  a >= 18 # ripr:disable-line comparison -- deliberate\nend\n"
    analysis, = instrument(source, operators: %w[comparison statement_removal])
    expect(analysis.fetch(:mutants).map { |m| m.fetch(:operator) }).not_to include("statement_removal")
    expect(analysis.fetch(:mutants).first.fetch(:accepted)).to include("deliberate")
  end

  it "preserves short-circuit behavior when connector mutations are inactive" do
    scope, analysis, = evaluate("def self.run(a, events); a && (events << :right); end", operators: ["boolean_connector"])
    events = []
    expect(scope.run(false, events)).to be(false)
    expect(events).to be_empty
    Ripr::R.activate(analysis.fetch(:sites).first.fetch(:key), 1)
    expect(scope.run(false, events)).to eq([:right])
  end

  it "drops only the returned value while retaining effects for return_nil" do
    scope, analysis, = evaluate("def self.run(events); events << :called; end", operators: ["return_nil"])
    Ripr::R.activate(analysis.fetch(:sites).first.fetch(:key), 1)
    events = []
    expect(scope.run(events)).to be_nil
    expect(events).to eq([:called])
  end

  it "keeps implicit regexp matches and flip-flops in conditional context" do
    source = <<~RUBY
      def self.regexp
        $_ = "no"
        if /yes/; :yes; else; :no; end
      end
      def self.flip(value)
        if value == 1..value == 3; :yes; else; :no; end
      end
    RUBY
    scope, = evaluate(source, operators: ["condition_negation"])
    expect(scope.regexp).to eq(:no)
    expect(scope.flip(4)).to eq(:no)
  end

  it "keeps predicate and removal switches around binary switches" do
    source = "def self.run(value, events); 20 + events.length; if value >= 18; :yes; else; :no; end; end"
    scope, analysis, = evaluate(source, operators: %w[arithmetic comparison condition_negation statement_removal])
    condition = analysis.fetch(:sites).find { |s| s[:operator] == "condition_negation" }
    Ripr::R.activate(condition.fetch(:key), 1)
    expect(scope.run(20, [])).to eq(:no)
  end

  it "isolates unsupported literal contexts and retains unrelated switches" do
    analysis, result = instrument("def self.run(x); [1i, x >= 18]; end", operators: %w[integer_literal comparison])
    comparison = analysis.fetch(:sites).find { |s| s[:operator] == "comparison" }
    expect(result.fetch(:site_table)).to have_key(comparison.fetch(:key))
    expect(result.fetch(:invalid)).not_to be_empty
    expect(Prism.parse(result.fetch(:code)).errors).to be_empty
  end

  it "does not report detached heredoc interpolation as an unreached switch" do
    source = <<~'RUBY'
      def self.run(x)
        text = <<~TEXT
          #{x >= 18}
        TEXT
        text
      end
    RUBY
    analysis, result = instrument(source)
    mutant = analysis.fetch(:mutants).first
    expect(result.fetch(:invalid)).to include(mutant.fetch(:id))
    expect(result.fetch(:site_table)).not_to have_key(mutant.fetch(:site))
  end

  it "resolves relative namespace paths and excludes dynamic singleton receivers" do
    analysis, = instrument("module A; module B::C; def self.run(x); x >= 18; end; end; def object.run(x); x >= 18; end; end")
    expect(analysis.fetch(:mutants).map { |m| m[:subject] }).to eq(["A::B::C.run"])
    expect(analysis.fetch(:warnings).join).to include("singleton receiver")
  end

  it "reports define_method blocks and dynamic singleton classes as unsupported" do
    source = "class A; define_method(:run) { |x| x >= 18 }; class << Object.new; def run(x); x >= 18; end; end; end"
    analysis, = instrument(source)
    expect(analysis.fetch(:mutants)).to be_empty
    expect(analysis.fetch(:warnings).join).to include("define_method", "singleton receiver")
  end

  it "preserves the syntax and method-presence semantics of defined? operands" do
    source = "def self.run(value); [defined?(true), defined?(1), defined?(value >= 18)]; end"
    scope, analysis, = evaluate(source, operators: %w[boolean_literal integer_literal comparison])
    expect(scope.run(Object.new)).to eq(["true", "expression", nil])
    expect(analysis.fetch(:mutants)).to be_empty
  end
end
