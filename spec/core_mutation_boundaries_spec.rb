# frozen_string_literal: true

require "ripr/core/analyzer"
require "ripr/core/input_suggestions"

RSpec.describe "Core mutation boundaries" do
  def analyze(source, operators:, static: false)
    Ripr::Core::Analyzer.call(source, "lib/example.rb", operators: operators, static: static)
  end

  it "retains the encoding declared by a source file that was read as bytes" do
    literal = %("caf\u00E9").encode("ISO-8859-1")
    source = "# coding: ISO-8859-1\ndef value; #{literal}; end\n"
    result = analyze(source.b, operators: ["string_literal"])

    expect(result.fetch(:source).encoding).to eq(Encoding::ISO_8859_1)
    expect(result.fetch(:source).bytes).to eq(source.bytes)
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:original) }).to eq([literal])
  end

  it "ignores comment bytes without changing source encoding or mutation offsets" do
    source = "# coding: ISO-8859-1\n# caf\u00E9 using ordinary arithmetic\ndef value(x); x + 0; end\n".encode("ISO-8859-1")
    result = analyze(source.b, operators: ["arithmetic"])
    mutant = result.fetch(:mutants).first

    expect(result.fetch(:source).encoding).to eq(Encoding::ISO_8859_1)
    expect(result.fetch(:source).bytes).to eq(source.bytes)
    expect(result.fetch(:sites).map { |site| site.fetch(:pure) }).to eq([true])
    expect(source.b.byteslice(mutant.fetch(:start_offset)...mutant.fetch(:end_offset))).to eq("x + 0")
    expect(mutant.fetch(:location)).to include(line: 3, column: 15)
  end

  it "attributes static mutations by scope and fingerprints the whole source file" do
    source = <<~RUBY
      TOP = 3
      ALSO_TOP = 3
      module Outer
        LIMIT = 4
        class << self
          ENABLED = 5
        end
      end
    RUBY
    operators = ["integer_literal"]
    result = analyze(source, operators: operators, static: true)
    mutants = result.fetch(:mutants)
    expect(mutants.map { |mutant| mutant.values_at(:original, :subject, :static) }.uniq)
      .to contain_exactly(["3", "Object::<load>", true], ["4", "Outer::<load>", true], ["5", "Outer::<singleton-body>", true])
    expect(mutants.map { |mutant| mutant.fetch(:method_hash) }.uniq).to eq([Digest::SHA256.hexdigest(source)])
    ids = mutants.map { |mutant| mutant.fetch(:id) }
    expect(ids.uniq).to eq(ids)

    moved = analyze("# leading comment\n#{source}", operators: operators, static: true).fetch(:mutants)
    expect(moved.map { |mutant| mutant.fetch(:id) }).to eq(ids)
    expect(moved.first.fetch(:method_hash)).not_to eq(mutants.first.fetch(:method_hash))
  end

  it "counts disabled static operators and excludes operands of defined?" do
    source = "LIMIT = 3\nAVAILABLE = defined?(true)\n"
    result = analyze(source, operators: ["boolean_literal"], static: true)

    expect(result.fetch(:static)).to eq(3)
    expect(result.fetch(:mutants)).to be_empty
  end

  it "marks constants as fixed operands even when Ruby expresses them without a literal token" do
    source = <<~'RUBY'
      def values(input)
        input >= ((18))
        input == ()
        __FILE__ == input
        input == "fixed"
        input == "#{input} suffix"
      end
    RUBY
    mutants = analyze(source, operators: ["comparison"]).fetch(:mutants)

    expect(mutants.to_h { |mutant| mutant.values_at(:original, :fixed_operands) }).to eq(
      "input >= ((18))" => [false, true],
      "input == ()" => [false, true],
      "__FILE__ == input" => [true, false],
      'input == "fixed"' => [false, true],
      "input == \"\#{input} suffix\"" => [false, false]
    )
  end

  it "skips case conditions that cannot be switched and uses the appropriate replacement for each case form" do
    source = <<~RUBY
      def match(items, value)
        case value
        when 4, *items, [1,
                         2]
          :with_predicate
        end
        case
        when false, value == 3
          :without_predicate
        end
      end
    RUBY
    mutants = analyze(source, operators: ["case_when"]).fetch(:mutants)
    expect(mutants.map { |mutant| mutant.values_at(:original, :replacement) })
      .to contain_exactly(["4", "->(*) { false }"], ["value == 3", "false"])
  end

  it "only switches strings that can be replaced without changing surrounding syntax or line numbers" do
    source = <<~'RUBY'
      def value(input)
        text = <<~TEXT
          detached
        TEXT
        ["", "ready", "prefix#{input}suffix", "over
        two lines", text]
      end
    RUBY
    mutants = analyze(source, operators: ["string_literal"]).fetch(:mutants)
    expect(mutants.map { |mutant| mutant.values_at(:original, :replacement) })
      .to contain_exactly(['""', '" "'], ['"ready"', '""'])
  end

  it "preserves named captures and skips regular expressions already using the never-match replacement" do
    source = "def value(input); [/(?<capture>.+)/ =~ input, capture, /(?!)/, /ready/]; end"
    mutants = analyze(source, operators: ["regexp_literal"]).fetch(:mutants)

    expect(mutants.map { |mutant| mutant.values_at(:original, :replacement) }).to eq([["/ready/", "/(?!)/"]])
  end

  it "uses matching empty collection kinds and leaves selectors with blocks unchanged" do
    source = <<~RUBY
      def value(items)
        array = [1]
        hash = { key: 2 }
        items.first { :fallback }
        items.size
        items.first
        items.last
      end
    RUBY
    mutants = analyze(source, operators: %w[collection_literal collection_method]).fetch(:mutants)

    expect(mutants.map { |mutant| mutant.values_at(:replacement, :mutated) }).to contain_exactly(
      ["[]", "[]"], ["{}", "{}"], ["last", "items.last"], ["first", "items.first"]
    )
  end

  describe "input suggestions" do
    def suggest(operator, original, replacement, observed)
      Ripr::Core::InputSuggestions.for(
        "status" => "not_infected", "operator" => operator, "original_operator" => original,
        "replacement" => replacement, "observed" => observed
      )
    end

    it "explains why the sampled operands hid an arithmetic mutation" do
      [
        ["+", "-", [[4, 0], [10, 0]], "right operand was zero"],
        ["%", "*", [[0, 2], [0, 3]], "left operand was zero"],
        ["/", "*", [[0, 2], [8, 1], [8, -1]], "a zero left operand or a right operand of 1 or -1"]
      ].each do |original, replacement, observed, reason|
        suggestion = suggest("arithmetic", original, replacement, observed)
        expect(suggestion.fetch(:reason)).to include(reason)
        expect(suggestion.fetch(:inputs)).not_to be_empty
      end
    end

    it "describes a sampled miss due to rounding without attributing it to zero operands" do
      suggestion = suggest("arithmetic", "+", "-", [[1e20, 1.0]])
      expect(suggestion.fetch(:reason)).to include("same result for each sampled pair")
    end

    it "offers a comparison boundary without explaining unsupported observations" do
      suggestion = suggest("comparison", ">=", ">", [[24, 18], [20, Float::INFINITY], ["21", 22]])
      expect(suggestion).to eq(inputs: [[18, 18]], reason: nil)
    end

    it "preserves sampled boolean and nil operands for an equality mutation" do
      pairs = [[true, nil], [false, true], [nil, nil]]
      expect(suggest("comparison", "==", "!=", pairs)).to eq(inputs: pairs, reason: nil)
    end

    it "skips missing or incompatible operator metadata" do
      expect(suggest("comparison", nil, ">", [[20, 18]])).to be_nil
      expect(suggest("other", ">=", ">", [[20, 18]])).to be_nil
      expect(suggest("comparison", ">=", "<", [[20, 18]])).to be_nil
    end
  end
end
