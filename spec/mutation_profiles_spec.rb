# frozen_string_literal: true

require "ripr/core/analyzer"
require "ripr/core/instrumenter"
require "ripr/runtime"

RSpec.describe "optional mutation operators" do
  def analyze(source, **options)
    Ripr::Core::Analyzer.call(source, "lib/example.rb", **options)
  end

  def instrument(source, **options)
    analysis = analyze(source, **options)
    result = Ripr::Core::Instrumenter.call(source, "lib/example.rb", analysis.fetch(:sites))
    expect(Prism.parse(result.fetch(:code))).to be_success
    expect(result.fetch(:code).count("\n")).to eq(source.count("\n"))
    Ripr::R.configure(result.fetch(:site_table))
    [analysis.fetch(:mutants), result]
  end

  def activate(mutant, result)
    site = mutant.fetch(:site)
    variant = result.fetch(:site_table).fetch(site).index(mutant.fetch(:id)) + 1
    Ripr::R.activate(site, variant)
  end

  after { Ripr::R.reset }

  it "keeps the default profile unchanged and lists the extended operators" do
    operators = Ripr::Core::Operators
    expect(operators::NAMES).to eq(%w[comparison arithmetic integer_literal boolean_literal condition_negation boolean_connector
                                      return_nil statement_removal])
    expect(operators::FULL_NAMES - operators::NAMES).to eq(%w[string_literal regexp_literal collection_literal collection_method
                                                              range_endpoint collection_query predicate_method fetch_index
                                                              safe_navigation compound_assignment case_when])
    expect(analyze('def value; ["a", /b/]; end').fetch(:mutants).map { |mutant| mutant[:operator] }).to eq(["return_nil"])
  end

  [
    ["string_literal", 'def self.value; "hello"; end', [], "hello", ""],
    ["regexp_literal", "def self.value; /match/; end", [], /match/, /(?!)/],
    ["collection_literal", "def self.value; [1, 2]; end", [], [1, 2], []],
    ["collection_literal", "def self.value; { count: 3 }; end", [], { count: 3 }, {}],
    ["collection_method", "def self.value(list); list.first; end", [[1, 2]], 1, 2],
    ["compound_assignment", "def self.value(count); count += 2; end", [8], 10, 6],
    ["case_when", "def self.value(n); case n; when 2 then :yes; else :no; end; end", [2], :yes, :no],
    ["case_when", "def self.value(n); case; when n then :yes; else :no; end; end", [true], :yes, :no]
  ].each do |operator, source, args, original, mutated|
    it "activates #{operator} in #{source}" do
      mutants, result = instrument(source, operators: [operator])
      expect(mutants.length).to eq(1)
      scope = Module.new
      scope.module_eval(result.fetch(:code))
      expect(scope.value(*args)).to eq(original)
      activate(mutants.first, result)
      expect(scope.value(*args)).to eq(mutated)
    end
  end

  it "keeps safe-navigation arguments lazy while probing" do
    source = "def self.value(target, events); target&.foo(events << :argument); end"
    mutants, result = instrument(source, operators: ["safe_navigation"])
    scope = Module.new
    scope.module_eval(result.fetch(:code))
    events = []
    probe = Ripr::Probe.new(result.fetch(:site_table))
    Ripr::R.probe = probe
    Ripr::R.current_test = "navigation"
    expect(scope.value(nil, events)).to be_nil
    expect(events).to be_empty
    expect(probe.snapshot.fetch("infect")).to eq(mutants.first.fetch(:id) => ["navigation"])
    Ripr::R.probe = nil
    activate(mutants.first, result)
    expect { scope.value(nil, events) }.to raise_error(NoMethodError)
    expect(events).to eq([:argument])
  end

  it "retains source-dependent semantics and line counts with the full profile" do
    source = <<~RUBY
      # frozen_string_literal: true
      def self.value
        /(?<capture>literal)/ =~ "literal"
        { word: "one" "two", capture: capture,
          heredoc: <<~TEXT, regex: /read/, names: %w[one two] }
          heredoc
        TEXT
      end
    RUBY
    _, result = instrument(source, operators: Ripr::Core::Operators::FULL_NAMES)
    expected = Module.new.tap { |scope| scope.module_eval(source) }.value
    scope = Module.new.tap { |mod| mod.module_eval(result.fetch(:code)) }
    expect(scope.value).to eq(expected)
    expect(scope.value.fetch(:word)).to be_frozen
  end

  it "switches opt-in load-time mutations before evaluating module bodies" do
    source = <<~RUBY
      TOP = 1
      module Nested
        NUMBER = 3
        def self.value; 8; end
      end
    RUBY
    expect(analyze(source).fetch(:static)).to eq(5)
    mutants, result = instrument(source, static: true, operators: ["integer_literal"])
    static = mutants.select { |mutant| mutant[:static] }
    expect(static.map { |mutant| mutant.fetch(:original) }.uniq).to eq(%w[1 3])
    expect(mutants.reject { |mutant| mutant[:static] }.map { |mutant| mutant.fetch(:original) }.uniq).to eq(["8"])
    mutant = static.find { |entry| entry.fetch(:original) == "3" && entry.fetch(:replacement) == "4" }
    activate(mutant, result)
    scope = Module.new.tap { |mod| mod.module_eval(result.fetch(:code)) }
    expect(scope.const_get(:TOP, false)).to eq(1)
    expect(scope.const_get(:Nested, false).const_get(:NUMBER, false)).to eq(4)
    later = analyze("\n# preserve identity\n#{source}", static: true, operators: ["integer_literal"]).fetch(:mutants)
    expect(later.map { |entry| entry.fetch(:id) }).to eq(mutants.map { |entry| entry.fetch(:id) })
  end

  it "inverts a predicate during loading in static mode" do
    source = "if true; VALUE = :yes; else; VALUE = :no; end"
    mutants, result = instrument(source, static: true, operators: ["condition_negation"])
    expect(mutants).to contain_exactly(a_hash_including(static: true, operator: "condition_negation"))
    activate(mutants.first, result)
    scope = Module.new.tap { |mod| mod.module_eval(result.fetch(:code)) }
    expect(scope.const_get(:VALUE, false)).to eq(:no)
  end

  it "replaces the planned byte range directly for a type checker" do
    source = "# 日本語\nVALUE = 11\ndef value; 2; end\n"
    analyzed = analyze(source, static: true, operators: ["integer_literal"])
    mutant = analyzed.fetch(:mutants).find { |entry| entry[:static] && entry[:replacement] == "12" }
    expect(Ripr::Core::Instrumenter.mutate(source, mutant)).to eq("# 日本語\nVALUE = 12\ndef value; 2; end\n")
  end
end
