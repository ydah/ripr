# frozen_string_literal: true

require "ripr/core/analyzer"
require "ripr/core/instrumenter"
require "ripr/core/classifier"
require "ripr/core/reuse_planner"

RSpec.describe "Core source analysis" do
  def analyze(source, operators: Ripr::Core::Operators::NAMES, arid_callees: %w[logger.* puts pp warn], skipped: nil)
    Ripr::Core::Analyzer.call(source, "lib/example.rb", operators: operators, arid_callees: arid_callees, skipped: skipped)
  end

  def instrument(source, analysis = analyze(source))
    Ripr::Core::Instrumenter.call(source, "lib/example.rb", analysis.fetch(:sites))
  end

  it "reports syntax errors without planning partial mutations" do
    skipped = []
    result = analyze("module Broken\n def value(\n", skipped: skipped)
    expect(result.fetch(:sites)).to be_empty
    expect(result.fetch(:mutants)).to be_empty
    expect(result.fetch(:static)).to eq(0)
    expect(result.fetch(:warnings).join).to include("lib/example.rb")
    expect(skipped).not_to be_empty
    expect(skipped).to all(match(["lib/example.rb", a_kind_of(Integer), a_kind_of(Integer), a_string_starting_with("parse error: ")]))
  end

  it "leaves unevaluated defined? operands out of the runtime mutation plan" do
    result = analyze("def value; defined?(true) || defined?(1 >= 0); end", operators: %w[boolean_literal integer_literal comparison])
    expect(result.fetch(:sites)).to be_empty
    expect(result.fetch(:mutants)).to be_empty
  end

  it "maps every comparison and arithmetic operator to its default replacement" do
    expected = { ">=" => ">", ">" => ">=", "<=" => "<", "<" => "<=", "==" => "!=", "!=" => "==",
                 "+" => "-", "-" => "+", "*" => "/", "/" => "*", "%" => "*" }
    expected.each do |operator, replacement|
      result = analyze("def calculate(a, b); a #{operator} b; end", operators: %w[comparison arithmetic])
      expect(result.fetch(:mutants).map { |mutant| mutant.values_at(:replacement, :mode) }).to eq([[replacement, "value"]])
    end
  end

  it "plans opt-in range, collection, predicate, and fetch mutations" do
    source = <<~RUBY
      def value(items, attributes, key, limit)
        (1..limit)
        (1...limit)
        (..limit)
        items.select(&:odd?)
        items.reject { |item| item.odd? }
        items.min
        items.max
        items.any?(&:odd?)
        items.all?(&:odd?)
        limit.positive?
        limit.negative?
        limit.zero?
        items.present?
        items.blank?
        attributes . fetch(key)
      end
    RUBY
    operators = %w[range_endpoint collection_query predicate_method fetch_index]
    mutants = analyze(source, operators: operators).fetch(:mutants)
    expect(mutants.map { |mutant| mutant.values_at(:operator, :mutated) }).to contain_exactly(
      ["range_endpoint", "1...limit"], ["range_endpoint", "1..limit"], ["range_endpoint", "...limit"],
      ["collection_query", "items.reject(&:odd?)"], ["collection_query", "items.select { |item| item.odd? }"],
      ["collection_query", "items.max"], ["collection_query", "items.min"],
      ["collection_query", "items.all?(&:odd?)"], ["collection_query", "items.any?(&:odd?)"],
      ["predicate_method", "limit.negative?"], ["predicate_method", "limit.positive?"], ["predicate_method", "!(limit.zero?)"],
      ["predicate_method", "items.blank?"], ["predicate_method", "items.present?"], ["fetch_index", "attributes[key]"]
    )
    expect(mutants.map { |mutant| mutant.fetch(:mode) }.uniq).to eq(["unknown"])
    expect(analyze(source).fetch(:mutants).map { |mutant| mutant.fetch(:operator) } & operators).to be_empty
  end

  it "leaves flip-flops, patterns and nonmatching Ruby call shapes out of the opt-in operators" do
    source = <<~RUBY
      def value(items, attributes, key, limit, *arguments, **keywords, &block)
        :inside if limit == 1..limit == 5
        items in [1..5]
        attributes.fetch(key: key)
        attributes.fetch(**keywords)
        attributes.fetch(*arguments)
        attributes.fetch(key, :default)
        attributes.fetch(key, &block)
        attributes.fetch(key) { :default }
        attributes.fetch key
        attributes&.fetch(key)
        fetch(key)
        items.select(:column)
        items.min(2)
        items.any?(Integer)
        items&.blank?
        positive?(limit)
        items.zero? { :callback }
        items.present?(limit)
      end
    RUBY
    operators = %w[range_endpoint collection_query predicate_method fetch_index]
    expect(analyze(source, operators: operators).fetch(:mutants)).to be_empty
  end

  it "uses one arithmetic definition for matching, mutation and native array-copy probing" do
    operator = Ripr::Core::Operators.fetch("arithmetic")
    node = Prism.parse("left + right").value.statements.body.first
    explicit_call = Prism.parse("left.+(right)").value.statements.body.first

    expect(operator.variants_for(node).map { |variant| variant.fetch(2) }).to eq(["-"])
    expect(operator.variants_for(explicit_call)).to be_empty
    expect(operator).to have_attributes(mode: "value", comparator: :native_array_copy, instrument_template: :binary)
  end

  it "evaluates the registered native infection condition on supported operands" do
    operators = Ripr::Core::Operators
    comparison = operators.fetch("comparison").infection_condition
    arithmetic = operators.fetch("arithmetic").infection_condition
    custom_value = Object.new
    expect(custom_value).not_to receive(:+)

    expect(comparison.call(20, 18, ">=")).to be(false)
    expect(comparison.call(18, 18, ">=")).to be(true)
    expect(arithmetic.call(1e20, 1.0, "+")).to be(false)
    expect(arithmetic.call(8, 1, "+")).to be(true)
    expect(arithmetic.call(8, 0, "/")).to be_nil
    expect(arithmetic.call(8, 2, "**")).to be_nil
    expect(arithmetic.call(custom_value, 1, "+")).to be_nil
  end

  it "limits the native array-copy probe to addition and subtraction" do
    source = <<~RUBY
      def value(left, right)
        left + right
        left * right
        left == right
      end
    RUBY
    result = instrument(source, analyze(source, operators: %w[arithmetic comparison]))
    binaries = result.fetch(:code).lines.select { |line| line.include?("::Ripr::R.bin(") }

    expect(binaries.map { |line| line.include?(",true,true)") }).to eq([true, false, false])
  end

  it "preserves contextual mutation identities for case conditions and returned values" do
    source = "def choose(value); case value; when 1 then true; else false; end; end"
    mutants = analyze(source, operators: %w[case_when return_nil]).fetch(:mutants)
    expected = [
      "lib/example.rb::Object#choose::body.body.0.conditions.0.conditions.0::case_when::->(*) { false }",
      "lib/example.rb::Object#choose::body.return::return_nil::nil"
    ]

    expect(mutants.map { |mutant| mutant.fetch(:full_id) }).to eq(expected)
  end

  it "removes duplicate and unchanged integer replacements" do
    { "0" => %w[1 -1], "1" => %w[2 0], "-1" => %w[0 -2], "9" => %w[10 8 0] }.each do |literal, replacements|
      result = analyze("def number; #{literal}; end", operators: ["integer_literal"])
      expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:replacement) }).to eq(replacements)
    end
  end

  it "flips boolean literals independently of condition mutation" do
    result = analyze("def flag(value); value ? true : false; end", operators: %w[boolean_literal condition_negation])
    expect(result.fetch(:mutants).map { |mutant| mutant.values_at(:operator, :replacement, :mode) })
      .to contain_exactly(%w[boolean_literal false always], %w[boolean_literal true always],
                          ["condition_negation", "!", "always"])
    literals = result.fetch(:mutants).select { |mutant| mutant.fetch(:operator) == "boolean_literal" }
    expect(literals.to_h { |mutant| mutant.values_at(:original, :replacement) }).to eq("true" => "false", "false" => "true")
  end

  it "records method identities and separates redefinitions and singleton contexts" do
    source = <<~RUBY
      module Outer
        class Inner
          def value; 1; end
          def value; 2; end
          def self.class_value; 3; end
          class << self
            def other_value; 4; end
          end
        end
      end
    RUBY
    mutants = analyze(source).fetch(:mutants)
    expect(mutants.map { |mutant| mutant.fetch(:subject) }.uniq)
      .to eq(["Outer::Inner#value", "Outer::Inner#value[2]", "Outer::Inner.class_value", "Outer::Inner.other_value"])
    expect(mutants.map { |mutant| mutant.fetch(:id) }.uniq.length).to eq(mutants.length)
    expect(mutants.all? { |mutant| mutant.fetch(:method_end) >= mutant.fetch(:method_start) }).to be(true)
  end

  it "counts static expressions without including them in method mutations" do
    result = analyze("VALUE = 1\nmodule Example\n def self.value; 2; end\nend\n")
    expect(result.fetch(:static)).to eq(2)
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:original) }.uniq).to eq(["2"])
    expect(result.fetch(:mutants).length).to eq(4)
  end

  it "preserves redefinition identities when an earlier method has an empty body" do
    result = analyze("class Example; def value; end; def value; 2; end; end", operators: ["integer_literal"])
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:subject) }.uniq).to eq(["Example#value[2]"])
  end

  it "plans and directly rewrites all extended operator kinds and load-time literals" do
    source = <<~RUBY
      LIMIT = 3
      WORD = "ready"
      if true; LABEL = "on"; end
      def value(items, count)
        count += 2
        case count
        when 3 then ["ready", /pattern/, {key: items&.first}, items.first]
        else [1..count, count.positive?, items.min, items.fetch(0)]
        end
      end
    RUBY
    operators = Ripr::Core::Operators::EXTRA_NAMES + %w[integer_literal condition_negation]
    analysis = Ripr::Core::Analyzer.call(source, "lib/example.rb", operators: operators, static: true)
    mutants = analysis.fetch(:mutants)
    expect(mutants.map { |mutant| mutant.fetch(:operator) }.uniq).to match_array(operators)
    expect(mutants.select { |mutant| mutant[:static] }.map { |mutant| mutant.fetch(:original) }.uniq).to include('"ready"', "3", "true")
    mutants.each do |mutant|
      mutated = Ripr::Core::Instrumenter.mutate(source, mutant)
      expect(mutated).not_to eq(source)
      expect(Prism.parse(mutated)).to be_success
    end
    expect(instrument(source, analysis).fetch(:invalid)).to be_empty
  end

  it "plans dynamic method bodies and excludes unsupported singleton receivers" do
    source = "define_method(:value) { 1 }\nclass << object\n def value; 2; end\nend\ndef object.value; 3; end\n"
    result = analyze(source)
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:subject) }.uniq).to eq(["Object#value<define_method>"])
    expect(result.fetch(:warnings)).to contain_exactly("lib/example.rb:2: skipped unsupported singleton receiver",
                                                       "lib/example.rb:5: skipped unsupported singleton receiver")
  end

  it "recognizes core deferred constructors and keeps unrelated call blocks in their enclosing context" do
    source = <<~RUBY
      class Example
        define_method("limit") { 1 }
        define_method(name) { 2 }
        FIRST = Kernel.lambda { 3 }
        SECOND = self.proc { 4 }
        THIRD = ::Proc.new { 5 }
        FOURTH = proc { 9 }
        OTHER = object.lambda { 6 }
        REGULAR = Builder.new { 7 }
        def value
          iterate { 8 }
        end
      end
    RUBY
    result = analyze(source, operators: ["integer_literal"])
    expect(result.fetch(:mutants).map { |mutant| mutant.values_at(:subject, :original) }.uniq).to contain_exactly(
      ["Example#limit<define_method>", "1"], ["Example#<define_method>", "2"], ["Example#<lambda>", "3"],
      ["Example#<proc>", "4"], ["Example#<proc>[2]", "5"], ["Example#<proc>[3]", "9"], ["Example#value", "8"]
    )
  end

  it "records only selected load-time operators and the reason for protected syntax" do
    source = <<~RUBY
      TOP = 1
      if FLAG
        OTHER = 2
      end
      def value(a)
        puts(a)
        return logger.warn(a)
        defined?(a >= 3)
        a
      end
      def object.unsupported; 4; end
    RUBY
    skipped = []
    analyze(source, operators: %w[condition_negation statement_removal], skipped: skipped)
    expect(skipped).to contain_exactly(
      ["lib/example.rb", 2, 4, "load-time expression requires --static"],
      ["lib/example.rb", 6, 3, "statement removal suppressed by arid_callees"],
      ["lib/example.rb", 8, 12, "defined? operand requires its original syntax"],
      ["lib/example.rb", 11, 1, "unsupported singleton receiver"]
    )

    skipped.clear
    analyze(source, operators: ["integer_literal"], skipped: skipped)
    expect(skipped).to contain_exactly(
      ["lib/example.rb", 1, 7, "load-time expression requires --static"],
      ["lib/example.rb", 3, 11, "load-time expression requires --static"],
      ["lib/example.rb", 8, 12, "defined? operand requires its original syntax"],
      ["lib/example.rb", 11, 1, "unsupported singleton receiver"]
    )
  end

  it "keeps explicit and splatted calls out of binary operators" do
    source = "def value(a, b); a.>=(b); a.+(b) do; end; a.+(*b); a.call(b); end"
    result = analyze(source, operators: %w[comparison arithmetic])
    expect(result.fetch(:sites)).to be_empty
  end

  it "keeps mutator filters and inline acceptance reasons precise" do
    source = <<~RUBY
      def value(x)
        # ripr:disable-next-line comparison -- externally specified boundary
        x >= 18
      end
    RUBY
    result = analyze(source)
    boundary = result.fetch(:mutants).find { |mutant| mutant.fetch(:operator) == "comparison" }
    expect(boundary.fetch(:accepted)).to eq("externally specified boundary")
    expect(result.fetch(:mutants).select { |mutant| mutant.fetch(:operator) == "integer_literal" }
                 .all? { |mutant| mutant[:accepted].nil? }).to be(true)
    expect(analyze(source, operators: ["arithmetic"]).fetch(:mutants)).to be_empty
  end

  it "protects configured arid calls while retaining removable ordinary statements" do
    source = "def value; audit.write(1); regular(2); logger.debug(3); 4; end"
    result = analyze(source, operators: ["statement_removal"], arid_callees: ["audit.*", "logger.*"])
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:original) }).to eq(["regular(2)"])
    expect(result.fetch(:mutants).first.fetch(:mode)).to eq("unknown")
  end

  it "avoids replacing explicit control flow with return_nil or statement removal" do
    %w[return raise fail].each do |keyword|
      result = analyze("def value; #{keyword} 1; end", operators: %w[return_nil statement_removal])
      expect(result.fetch(:mutants)).to be_empty
    end
  end

  it "keeps ids stable across prefix lines while source hashes detect method edits" do
    source = "def value(x); x >= 18; end\n"
    before = analyze(source).fetch(:mutants)
    moved = analyze("# heading\n\n#{source}").fetch(:mutants)
    changed = analyze(source.sub("18", "19")).fetch(:mutants)
    expect(moved.map { |mutant| mutant.fetch(:full_id) }).to eq(before.map { |mutant| mutant.fetch(:full_id) })
    expect(moved.map { |mutant| mutant.fetch(:method_hash) }).to eq(before.map { |mutant| mutant.fetch(:method_hash) })
    expect(changed.first.fetch(:method_hash)).not_to eq(before.first.fetch(:method_hash))
    expect(before.first.fetch(:location)).to include(file: "lib/example.rb", line: 1, column: 15)
  end

  it "suppresses value speculation for source using refinements" do
    source = "using CustomOperators\ndef value(x); x >= 18; end\n"
    expect(analyze(source).fetch(:sites).all? { |site| site.fetch(:pure) == false }).to be(true)
    expect(instrument(source).fetch(:code)).to include(",false)")
  end

  it "emits matching site tables and reparsable code for nested default operators" do
    source = "def value(x, enabled); saved = true; enabled && (x + 2 >= 18) ? saved : false; end\n"
    result = analyze(source)
    rewritten = instrument(source, result)
    expect(Prism.parse(rewritten.fetch(:code))).to be_success
    expect(rewritten.fetch(:code).count("\n")).to eq(source.count("\n"))
    expect(rewritten.fetch(:invalid)).to be_empty
    expected = result.fetch(:sites).to_h { |site| [site.fetch(:key), site.fetch(:variants).map { |variant| variant.fetch(:id) }] }
    expect(rewritten.fetch(:site_table)).to eq(expected)
    expect(result.fetch(:mutants).none? { |mutant| mutant[:invalid] }).to be(true)
  end

  it "leaves accepted and invalid sites unchanged" do
    source = "def value; 1; end\n"
    result = analyze(source)
    result.fetch(:mutants).each { |mutant| mutant[:accepted] = "Equivalent by specification" }
    rewritten = instrument(source, result)
    expect(rewritten.fetch(:code)).to eq(source)
    expect(rewritten.fetch(:site_table)).to be_empty
    result.fetch(:mutants).each do |mutant|
      mutant[:accepted] = nil
      mutant[:invalid] = true
    end
    expect(instrument(source, result).fetch(:code)).to eq(source)
  end

  it "preserves empty source, detached data, and newline boundaries" do
    ["", "\n\n", "# 日本語\ndef value; 1; end\n__END__\n追加データ\n"].each do |source|
      rewritten = instrument(source)
      expect(Prism.parse(rewritten.fetch(:code))).to be_success
      expect(rewritten.fetch(:code).count("\n")).to eq(source.count("\n"))
      expect(rewritten.fetch(:code).split("__END__", 2).last).to eq(source.split("__END__", 2).last) if source.include?("__END__")
    end
  end

  it "groups literal variants at one site and emits fixed-length short identities" do
    result = analyze("def value; 18; end", operators: ["integer_literal"])
    expect(result.fetch(:sites).length).to eq(1)
    expect(result.fetch(:sites).first.fetch(:variants)).to eq(result.fetch(:mutants))
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:id) }).to all(match(/\A[0-9a-f]{10}\z/))
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:full_id) }.uniq.length).to eq(3)
  end

  it "limits connector duplication to three boolean levels and excludes multiline connectors" do
    %w[&& ||].each do |connector|
      source = "def value(a,b,c,d,e,f); #{%w[a b c d e f].join(" #{connector} ")}; end"
      skipped = []
      expect(analyze(source, operators: ["boolean_connector"], skipped: skipped).fetch(:sites).length).to eq(3)
      expect(skipped.length).to eq(2)
      expect(skipped).to all(match(["lib/example.rb", 1, a_kind_of(Integer), "boolean connector exceeds the mutation depth limit"]))
      skipped.clear
      analyze(source, operators: ["arithmetic"], skipped: skipped)
      expect(skipped).to be_empty
    end
    source = "def value(a,b); a &&\n b; end\n"
    expect(Prism.parse(source)).to be_success
    expect(analyze(source, operators: ["boolean_connector"]).fetch(:sites)).to be_empty
  end

  it "isolates an unsupported imaginary literal while retaining an independent comparison" do
    source = "def value(x); [1i, x >= 18]; end\n"
    result = analyze(source, operators: %w[integer_literal comparison])
    rewritten = instrument(source, result)
    comparison = result.fetch(:sites).find { |site| site.fetch(:operator) == "comparison" }
    expect(rewritten.fetch(:site_table)).to have_key(comparison.fetch(:key))
    expect(rewritten.fetch(:invalid)).not_to be_empty
    expect(rewritten.fetch(:warnings).join).to include("excluded", "unsupported")
    expect(Prism.parse(rewritten.fetch(:code))).to be_success
    expect(rewritten.fetch(:code).count("\n")).to eq(source.count("\n"))
  end

  it "accepts all operators on disabled lines and supplies a reason when none was written" do
    source = <<~RUBY
      def value(x)
        x >= 18 # ripr:disable-line -- Boundaries excluded by contract
      end
    RUBY
    result = analyze(source)
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:accepted) }.uniq).to eq(["Boundaries excluded by contract"])
    expect(result.fetch(:sites).length).to eq(3)
    source = "def value\n # ripr:disable-next-line\n 1\nend\n"
    expect(analyze(source).fetch(:mutants).map { |mutant| mutant.fetch(:accepted) }.uniq).to eq(["inline disable"])
  end

  it "records exact one-based span columns and the documented short identity" do
    source = "def value(x)\n  x >= 18\nend\n"
    mutant = analyze(source, operators: ["comparison"]).fetch(:mutants).first
    expect(mutant.fetch(:full_id)).to eq("lib/example.rb::Object#value::body.body.0::comparison::>")
    expect(mutant.fetch(:id)).to eq(Digest::SHA256.hexdigest(mutant.fetch(:full_id)).slice(0, 10))
    expect(mutant.fetch(:location)).to eq(file: "lib/example.rb", line: 2, column: 3, end_line: 2, end_column: 10)
  end

  it "marks statement removal invalid when it leaves an undefined pinned pattern variable" do
    source = "def value(input)\n  pinned = 1\n  input in ^pinned\nend\n"
    expect(Prism.parse(source)).to be_success
    mutant = analyze(source, operators: ["statement_removal"]).fetch(:mutants).first
    expect(mutant.fetch(:original)).to eq("pinned = 1")
    expect(mutant.fetch(:invalid)).to be(true)
  end

  it "recognizes arid calls inside nested statements" do
    source = "def value; result = wrap(logger.info(:message)); compute; 1; end"
    result = analyze(source, operators: ["statement_removal"])
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:original) }).to eq(["compute"])
  end

  it "distinguishes top-level instance and singleton methods" do
    result = analyze("def instance_value; 1; end\ndef self.singleton_value; 1; end")
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:subject) }.uniq).to eq(["Object#instance_value", "Object.singleton_value"])
  end

  it "reports the unsupported receiver for an isolated singleton definition" do
    result = analyze("def object.value; 1; end")
    expect(result.fetch(:mutants)).to be_empty
    expect(result.fetch(:warnings)).to eq(["lib/example.rb:1: skipped unsupported singleton receiver"])
  end

  it "gives a nested def its own instance subject" do
    source = "class Example; def outer; def inner; 1; end; end; end"
    expect(analyze(source).fetch(:mutants).map { |mutant| mutant.fetch(:subject) }.uniq).to eq(["Example#inner"])
  end

  it "gives define_method blocks inside ordinary methods their own subjects" do
    result = analyze("def outer; define_method(:inner) { 1 }; end", operators: ["integer_literal"])
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:subject) }.uniq).to eq(["Object#inner<define_method>"])
    expect(result.fetch(:warnings)).to be_empty
  end

  it "plans removal of every non-final ordinary statement" do
    result = analyze("def value; first; second; third; end", operators: ["statement_removal"])
    expect(result.fetch(:mutants).map { |mutant| mutant.fetch(:original) }).to eq(%w[first second])
  end

  it "generates both original and replacement binary expressions and preserves operand newlines" do
    source = "def value(left, right)\n  left >=\n    right\nend\n"
    result = analyze(source, operators: ["comparison"])
    rewritten = instrument(source, result)
    expect(rewritten.fetch(:invalid)).to be_empty
    expect(rewritten.fetch(:site_table).keys).to eq(result.fetch(:sites).map { |site| site.fetch(:key) })
    expect(rewritten.fetch(:code)).to include("__ripr_k == 0 ? __ripr_l >= __ripr_r", "__ripr_l > __ripr_r")
    expect(rewritten.fetch(:code).count("\n")).to eq(source.count("\n"))
  end

  it "retains both operands in the switched connector branch" do
    source = "def value(left, right); left && right; end"
    rewritten = instrument(source, analyze(source, operators: ["boolean_connector"]))
    expect(rewritten.fetch(:code)).to include("((left) || (right))", "(left && right)")
  end

  it "isolates one invalid site out of exactly two candidates" do
    source = "def value(left, right); [1i, left >= right]; end"
    result = analyze(source, operators: %w[integer_literal comparison])
    expect(result.fetch(:sites).length).to eq(2)
    rewritten = instrument(source, result)
    comparison = result.fetch(:sites).find { |site| site.fetch(:operator) == "comparison" }
    expect(rewritten.fetch(:site_table).keys).to eq([comparison.fetch(:key)])
    expect(rewritten.fetch(:warnings)).to eq(["lib/example.rb: excluded 1 unsupported instrumentation sites"])
  end

  it "omits unreachable heredoc interpolation sites from the runtime table" do
    source = <<~'RUBY'
      def value(input)
        text = <<~TEXT
          #{input >= 18}
        TEXT
        text
      end
    RUBY
    result = analyze(source, operators: ["comparison"])
    expect(result.fetch(:sites).length).to eq(1)
    rewritten = instrument(source, result)
    expect(rewritten.fetch(:site_table)).to be_empty
    expect(rewritten.fetch(:invalid)).to eq(result.fetch(:mutants).map { |mutant| mutant.fetch(:id) })
    expect(rewritten.fetch(:warnings)).to eq(["lib/example.rb: excluded 1 unsupported instrumentation sites"])
    expect(rewritten.fetch(:code)).to eq(source)
  end

  it "keeps unary operators outside the binary mutation interface" do
    source = "def value(input); [-input, +input, !input, ~input]; end"
    expect(Prism.parse(source)).to be_success
    expect(analyze(source, operators: %w[comparison arithmetic]).fetch(:mutants)).to be_empty
  end

  it "refuses malformed recorded test maps before cache reuse" do
    mutant = { "id" => "abc", "full_id" => "full", "method_hash" => "method" }
    record = mutant.merge("status" => "killed", "env_hash" => "env")
    [nil, [], "spec/example_spec.rb"].each do |tests|
      expect(Ripr::Core::ReusePlanner.reusable?(record.merge("tests" => tests), mutant, env_hash: "env", test_hashes: {})).to be(false)
    end
  end
end
