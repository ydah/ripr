# frozen_string_literal: true

require "json"
require "ripr/runtime" if File.file?(File.expand_path("../lib/ripr/runtime.rb", __dir__))

RSpec.describe "mutation runtime" do
  let(:site) { "lib/sample.rb::Sample.adult?::body.0::comparison" }
  let(:table) { { site => ["adult-boundary"] } }

  def observe(left, right, pure = true) # rubocop:disable Style/OptionalBooleanParameter
    Ripr::R.bin(site, left, right, pure) { |l, r, k| k.zero? ? l >= r : l > r }
  end

  def start_probe(samples: true)
    Ripr::R.configure(table, samples: samples)
    Ripr::R.probe = Ripr::Probe.new(table, samples: samples)
    Ripr::R.current_test = "SampleTest#test_adult"
  end

  after { Ripr::R.reset if defined?(Ripr::R) }

  it "exposes the mutation switching entry point" do
    runtime = defined?(Ripr::R) && Ripr::R
    expect(runtime).to respond_to(:bin, :lit, :cond, :ret, :on?, :activate, :configure, :reset)
  end

  it "returns the original value until its own site is activated" do
    Ripr::R.configure(table)
    expect(observe(18, 18)).to be(true)
    Ripr::R.activate("another-file", 1)
    expect(observe(18, 18)).to be(true)
    Ripr::R.activate(site, 1)
    expect(observe(18, 18)).to be(false)
  end

  it "clears an active mutation, probe, and current test when starting a new run" do
    start_probe
    Ripr::R.activate(site, 1)
    expect(Ripr::R.lit("unselected-site", :original, :replacement)).to eq(:original)
    expect(Ripr::R.lit(site, :original, :replacement)).to eq(:replacement)

    Ripr::R.configure({ "another-site" => ["other-variant"] }, samples: false)
    expect(Ripr::R.probe).to be_nil
    expect(Ripr::R.current_test).to be_nil
    expect(Ripr::R.lit(site, :original, :replacement)).to eq(:original)
    expect(Ripr::R.on?(site)).to be(false)
  end

  it "records reach and observations without infection away from the boundary" do
    start_probe
    expect(observe(20, 18)).to be(true)
    expect(observe(10, 18)).to be(false)
    snapshot = Ripr::R.probe.snapshot
    expect(snapshot.fetch("reach").fetch(site)).to eq(["SampleTest#test_adult"])
    expect(snapshot.fetch("infect").fetch("adult-boundary", [])).to be_empty
    expect(snapshot.fetch("samples").fetch(site)).to eq([[20, 18], [10, 18]])
  end

  it "marks the boundary as infected and keeps the original result" do
    start_probe
    expect(observe(18, 18)).to be(true)
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  end

  it "does not evaluate operands more than once" do
    start_probe
    seen = []
    operand = lambda do |name, value|
      seen << name
      value
    end
    Ripr::R.bin(site, operand.call(:left, 20), operand.call(:right, 18)) { |l, r, k| k.zero? ? l >= r : l > r }
    expect(seen).to eq(%i[left right])
  end

  it "treats a mutated exception as infection without raising it" do
    start_probe
    expect(Ripr::R.bin(site, 4, 0) { |l, r, k| k.zero? ? l * r : l / r }).to eq(0)
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  end

  it "does not swallow exceptions from the original expression" do
    start_probe
    expect { Ripr::R.bin(site, 4, 0) { |l, r, _k| l / r } }.to raise_error(ZeroDivisionError)
  end

  it "records conservative infection when a test catches the original operator exception" do
    start_probe
    expect { Ripr::R.bin(site, 4, 0) { |l, r, k| k.zero? ? l / r : l * r } }.to raise_error(ZeroDivisionError)
    snapshot = Ripr::R.probe.snapshot
    expect(snapshot.fetch("reach").fetch(site)).to eq(["SampleTest#test_adult"])
    expect(snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  end

  it "does not call speculative operators on user objects" do
    start_probe
    calls = []
    value = Object.new
    value.define_singleton_method(:>=) do |_right|
      calls << :original
      true
    end
    value.define_singleton_method(:>) do |_right|
      calls << :mutated
      false
    end
    expect(observe(value, 18)).to be(true)
    expect(calls).to eq([:original])
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
    expect(Ripr::R.probe.snapshot.fetch("samples")).not_to have_key(site)
  end

  it "accepts BasicObject operands and return values without requiring Object methods" do
    start_probe
    klass = Class.new(BasicObject) do
      def >=(_other)
        true
      end
    end
    value = klass.new
    expect(observe(value, 18)).to be(true)
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
    Ripr::R.ret(site, value)
    expect(Ripr::Value.same?(value, value)).to be(false)
  end

  it "does not call speculative operators when the instrumenter flags refinements" do
    start_probe
    calls = []
    Ripr::R.bin(site, 20, 18, false) do |l, r, k|
      calls << k
      k.zero? ? l >= r : l > r
    end
    expect(calls).to eq([0])
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  end

  it "rejects String subclasses and singleton operator overrides as pure values" do
    expect(Ripr::Value.pure?(Class.new(String).new("x"))).to be(false)
    value = +"x"
    value.define_singleton_method(:>) { |_other| true }
    expect(Ripr::Value.pure?(value)).to be(false)
  end

  it "does not speculate on monkey-patched core operators" do
    start_probe
    original = String.instance_method(:>)
    calls = []
    String.define_method(:>) do |_right|
      calls << :mutated
      false
    end
    expect(observe("20", "18")).to be(true)
    expect(calls).to be_empty
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  ensure
    String.define_method(:>, original)
  end

  it "does not call a redefined comparison callback twice" do
    start_probe
    original = String.instance_method(:<=>)
    left = +"20"
    calls = []
    String.define_method(:<=>) do |right|
      calls << right if equal?(left)
      original.bind_call(self, right)
    end
    expect(observe(left, "18")).to be(true)
    expect(calls).to eq(["18"])
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  ensure
    String.define_method(:<=>, original)
  end

  it "leaves operands untouched when a replacement aliases a native mutator" do
    start_probe
    original = String.instance_method(:>)
    String.alias_method(:>, :replace)
    left = +"20"
    expect(observe(left, "18")).to be(true)
    expect(left).to eq("20")
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  ensure
    String.define_method(:>, original)
  end

  it "does not send a missing replacement operator to user method_missing" do
    start_probe
    left = +"20"
    calls = []
    String.define_method(:method_missing) do |name, *arguments|
      if name == :- && equal?(left)
        calls << name
        self
      else
        super(name, *arguments)
      end
    end
    expect(Ripr::R.bin(site, left, "18") { |l, r, k| k.zero? ? l + r : l - r }).to eq("2018")
    expect(calls).to be_empty
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  ensure
    String.remove_method(:method_missing)
  end

  it "does not call a private singleton comparison callback twice" do
    start_probe
    left = +"20"
    calls = []
    left.define_singleton_method(:<=>) do |right|
      calls << right
      1
    end
    left.singleton_class.__send__(:private, :<=>)
    expect(observe(left, "18")).to be(true)
    expect(calls).to eq(["18"])
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  end

  it "distinguishes floating point signs and exact value classes" do
    expect(Ripr::Value.same?(0.0, -0.0)).to be(false)
    expect(Ripr::Value.same?(1, 1.0)).to be(false)
    expect(Ripr::Value.same?(Rational(1, 2), Rational(2, 4))).to be(true)
    expect(Ripr::Value.same?("x".encode(Encoding::UTF_8), "x".encode(Encoding::US_ASCII))).to be(false)
    expect(Ripr::Value.same?(2.0, 2.0)).to be(true)
    expect(Ripr::Value.same?(2.0, 3.0)).to be(false)
    expect(Ripr::Value.same?(+"same", +"same")).to be(true)
    expect(Ripr::Value.same?(+"left", +"right")).to be(false)
  end

  it "compares bounded plain arrays, hashes, ranges, and Data fields by their values" do
    point = Data.define(:coordinates, :bounds)
    left = point.new([1, { x: [true, nil] }], ..5)
    right = point.new([1, { x: [true, nil] }], ..5)

    expect(Ripr::Value.pure?(left)).to be(true)
    expect(Ripr::Value.same?(left, right)).to be(true)
    expect(Ripr::Value.same?(left, point.new(right.coordinates, ...5))).to be(false)
    expect(Ripr::Value.same?(left, Data.define(:coordinates, :bounds).new(right.coordinates, right.bounds))).to be(false)
  end

  it "preserves differences that native collection equality can hide" do
    [
      [[1], [1.0]],
      [[0.0], [-0.0]],
      [{ first: 1, second: 2 }, { second: 2, first: 1 }],
      [{ x: 1 }, Hash.new(5).merge(x: 1)],
      [["x"], [+"x"]],
      [{ x: 1 }, { x: 1 }.compare_by_identity]
    ].each do |left, right|
      expect(Ripr::Value.same?(left, right)).to be(false)
    end
  end

  it "compares each nested scalar payload by its exact value" do
    left = { "status" => [:ready, -0.0, Rational(1, 2), 2**127, +"utf-8"] }
    right = { "status" => [:ready, -0.0, Rational(1, 2), 2**127, +"utf-8"] }

    expect(Ripr::Value.same?(left, right)).to be(true)
    [:waiting, 0.0, Rational(1, 3), (2**127) + 1, +"different"].each_with_index do |value, index|
      changed = right.transform_values(&:dup)
      changed.fetch("status")[index] = value
      expect(Ripr::Value.same?(left, changed)).to be(false)
    end
    expect(Ripr::Value.same?(left, nil)).to be(false)
    expect(Ripr::Value.same?([nil], [false])).to be(false)

    special = [Float::NAN, Float::INFINITY, -Float::INFINITY]
    snapshot = Ripr::Value.snapshot(special)
    expect(snapshot).not_to be_nil
    expect { JSON.generate(snapshot) }.not_to raise_error
  end

  it "preserves scalar types and payloads in serialized result snapshots" do
    value = [:ready, -0.0, Rational(3, 2), 42, +"ready"]
    snapshot = JSON.parse(JSON.generate(Ripr::Value.snapshot(value)))
    expected_values = [
      ["Symbol", %w[US-ASCII 7265616479]],
      ["Float", %w[ASCII-8BIT 8000000000000000]],
      ["Rational", 3, 2],
      ["Integer", 42],
      ["String", false, %w[UTF-8 7265616479]]
    ]

    expect(snapshot.first).to eq("Array")
    expect(snapshot.last).to eq(expected_values)
  end

  it "rejects unsupported collections even when one object appears on both sides" do
    cycle = []
    cycle << cycle
    shared = [1]
    shared_string = +"shared"
    frozen_unsupported = Object.new.freeze
    values = [cycle, [shared, shared], [shared_string, shared_string], [frozen_unsupported].freeze, Class.new(Array).new([1]),
              Array.new(1_000, 1), 100.times.reduce(1) { |value, _index| [value] }, ["x" * 100_000],
              Array.new(5) { Array.new(32, 1) }, Hash.new { raise "called a default proc" }, { x: 1 }.compare_by_identity,
              { Float::NAN => :ambiguous_key }]

    values.each do |value|
      expect(Ripr::Value.pure?(value)).to be(false)
      expect(Ripr::Value.same?(value, value)).to be(false)
    end
  end

  it "snapshots ordinary large integers and declines ones with excessive storage" do
    integer = 2**800
    largest_integer = 2**8_191

    expect(Ripr::Value.same?([integer], [Integer(integer.to_s)])).to be(true)
    expect(Ripr::Value.same?([integer], [integer + 1])).to be(false)
    expect(Ripr::Value.snapshot([largest_integer])).not_to be_nil
    expect(Ripr::Value.snapshot([largest_integer * 2])).to be_nil
  end

  it "snapshots up to 32 entries in arrays, hashes, and Data records" do
    [[32, false], [33, true]].each do |size, unknown|
      pairs = (1..size).to_h { |index| [index, index] }
      record = Data.define(*(1..size).map { |index| :"column_#{index}" })

      [pairs.keys, pairs, record.new(*pairs.values)].each do |value|
        expect(Ripr::Value.snapshot(value).nil?).to eq(unknown)
      end
    end
  end

  it "snapshots up to four nested collection levels" do
    value = [[[[1]]]]

    expect(Ripr::Value.snapshot(value)).not_to be_nil
    expect(Ripr::Value.snapshot([value])).to be_nil
  end

  it "snapshots up to 128 values across nested collections" do
    value = Array.new(3) { Array.new(32, 1) } << Array.new(27, 1)

    expect(Ripr::Value.snapshot(value)).not_to be_nil
    value.last << 1
    expect(Ripr::Value.snapshot(value)).to be_nil
  end

  it "snapshots string payloads of up to 1,024 bytes" do
    value = "x" * 1_024

    expect(Ripr::Value.snapshot([value])).not_to be_nil
    value << "x"
    expect(Ripr::Value.snapshot([value])).to be_nil
  end

  it "does not compare Hash keys whose insertion-time hash can differ from their current value" do
    key = [1]
    hash = { key => :value }
    key << 2

    expect(Ripr::Value.snapshot(hash)).to be_nil
    expect(Ripr::Value.same?(hash, { [1, 2] => :value })).to be(false)
  end

  it "rejects user Data methods and singleton container methods without calling them" do
    calls = []
    point = Data.define(:value) do
      define_method(:==) { |_other| calls << :equality }
    end
    accessor = Data.define(:value) do
      define_method(:value) { calls << :accessor }
    end
    range = 1..2
    value = [1]
    value.define_singleton_method(:length) { calls << :public_array_method }
    private_value = [1]
    private_value.define_singleton_method(:private_payload) { calls << :private_array_method }
    private_value.singleton_class.__send__(:private, :private_payload)
    string = +"mutable"
    string.define_singleton_method(:length) { calls << :string_method }
    odd_range = Class.new(Range).new(range.begin, range.end)

    [point.new(1), accessor.new(1), value, private_value, [string], odd_range].each do |unsafe|
      expect(Ripr::Value.pure?(unsafe)).to be(false)
      expect(Ripr::Value.same?(unsafe, unsafe)).to be(false)
    end
    expect(calls).to be_empty
  end

  it "declines compounds when a core accessor or implicit conversion has been customized" do
    numerator = Rational.instance_method(:numerator)
    size = Array.instance_method(:size)
    number = Rational(1, 2)
    compound = [number]
    plain_array = [1]
    calls = []
    results = begin
      Rational.define_method(:numerator) do
        calls << :numerator if equal?(number)
        numerator.bind_call(self)
      end
      rational_snapshot = Ripr::Value.snapshot(compound)
      Rational.define_method(:numerator, numerator)
      Array.define_method(:size) do
        calls << :size if equal?(plain_array)
        size.bind_call(self)
      end
      array_snapshot = Ripr::Value.snapshot(plain_array)
      copy_safe = Ripr::Value.array_copy_operands?(plain_array, [])
      Array.define_method(:size, size)
      Array.define_method(:to_hash) do
        calls << :to_hash if equal?(plain_array)
        {}
      end
      [rational_snapshot, array_snapshot, copy_safe, Ripr::Value.snapshot(plain_array)]
    ensure
      Rational.define_method(:numerator, numerator)
      Array.define_method(:size, size)
      Array.remove_method(:to_hash) if Array.method_defined?(:to_hash, false)
    end
    expect(results).to eq([nil, nil, false, nil])
    expect(calls).to be_empty
  end

  it "recognizes only fresh, writable and verified shallow copies with native arrays on both sides" do
    left = [+"value"]
    right = []
    expect(Ripr::Value.empty_array_copy?(left, right, left.dup)).to be(true)
    expect(Ripr::Value.array_copy_operands?(left, Class.new(Array).new)).to be(false)
    expect(Ripr::Value.array_copy_operands?(Object.new, right)).to be(false)
    expect(Ripr::Value.empty_array_copy?([], right, right)).to be(false)
    expect(Ripr::Value.empty_array_copy?(left, right, left)).to be(false)
    expect(Ripr::Value.empty_array_copy?(left, right, left.dup.freeze)).to be(false)
    expect(Ripr::Value.empty_array_copy?(left, right, nil)).to be(false)
    expect(Ripr::Value.empty_array_copy?(left, right, [+"value"])).to be(false)

    unverified_left = left.dup
    unverified_left.instance_variable_set(:@extra_state, true)
    unverified_right = []
    unverified_right.define_singleton_method(:label) { "custom" }
    expect(Ripr::Value.empty_array_copy?(unverified_left, right, left.dup)).to be(false)
    expect(Ripr::Value.empty_array_copy?(left, unverified_right, left.dup)).to be(false)
    expect(Ripr::Value.empty_array_copy?(left, right, unverified_left)).to be(false)
  end

  it "rejects a native alias in a collection's equality path" do
    original = Array.instance_method(:==)
    Array.alias_method(:==, :replace)

    expect(Ripr::Value.pure?([1])).to be(false)
  ensure
    Array.define_method(:==, original)
  end

  it "rejects a missing native collection comparator even if Ruby inherits a fallback" do
    original = Array.instance_method(:==)
    Array.remove_method(:==)

    expect(Ripr::Value.snapshot([1])).to be_nil
  ensure
    Array.define_method(:==, original)
  end

  it "snapshots mutation results without retaining mutable inputs" do
    value = { x: [+"mutable", nil] }
    before = Ripr::Value.snapshot(value)

    expect(before).to be_frozen
    expect(Ripr::Value.snapshot(nil)).not_to be_nil
    expect(Ripr::Value.snapshot(Object.new)).to be_nil
    value[:x][0].replace("changed")
    expect(before).to eq(Ripr::Value.snapshot({ x: [+"mutable", nil] }))
    expect(before).not_to eq(Ripr::Value.snapshot(value))
    expect { JSON.generate(before) }.not_to raise_error
  end

  it "records nil return values as uninfected and other returns as infected" do
    start_probe
    expect(Ripr::R.ret(site, nil)).to be_nil
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary", [])).to be_empty
    expect(Ripr::R.ret(site, false)).to be(false)
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
    Ripr::R.probe = nil
    Ripr::R.activate(site, 1)
    expect(Ripr::R.ret(site, 12)).to be_nil
  end

  it "switches literals and conditions and marks always-mode variants infected" do
    start_probe
    Ripr::R.lit(site, 18, 19)
    expect(Ripr::R.cond(site, "truthy")).to eq("truthy")
    expect(Ripr::R.on?(site)).to be(false)
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
    Ripr::R.probe = nil
    Ripr::R.activate(site, 1)
    expect(Ripr::R.lit(site, 18, 19)).to eq(19)
    expect(Ripr::R.cond(site, "truthy")).to be(false)
    expect(Ripr::R.on?(site)).to be(true)
  end

  it "keeps at most three unique observations and truncates strings" do
    start_probe
    ["a" * 40, "a" * 40, "b", "c", "d"].each do |value|
      Ripr::R.bin(site, value, "x") { |l, r, k| k.zero? ? l == r : l != r }
    end
    samples = Ripr::R.probe.snapshot.fetch("samples").fetch(site)
    expect(samples).to eq([["a" * 32, "x"], %w[b x], %w[c x]])
  end

  it "keeps observed strings isolated from both operands and exported snapshots" do
    start_probe
    left = +"20"
    observe(left, +"18")
    left.replace("caller changed the operand")

    exported = Ripr::R.probe.snapshot.fetch("samples").fetch(site)
    sample = exported.first.first
    sample.replace("edited snapshot") unless sample.frozen?
    exported.clear

    expect(Ripr::R.probe.snapshot.fetch("samples").fetch(site)).to eq([%w[20 18]])
  end

  it "copies string operands even when the class name is overridden" do
    allow(String).to receive(:name).and_return("RenamedString")
    start_probe
    left = +"20"
    observe(left, +"18")
    left.replace("edited operand")
    expect(Ripr::R.probe.snapshot.fetch("samples").fetch(site)).to eq([%w[20 18]])
  end

  it "stops checking operands after samples are full and the test has infected the mutation" do
    start_probe
    [18, 19, 20].each { |age| observe(age, 18) }
    expected = Ripr::R.probe.snapshot
    expect(expected.fetch("samples").fetch(site)).to eq([[18, 18], [19, 18], [20, 18]])
    expect(expected.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])

    expect(Ripr::Value).not_to receive(:scalar?)
    expect(observe(21, 18)).to be(true)
    expect(Ripr::R.probe.snapshot).to eq(expected)
  end

  it "checks an operator again when a later test reaches the same site after a redefinition" do
    start_probe
    original = String.instance_method(:>)
    left = +"20"
    expect(observe(left, "18")).to be(true)
    expect(Ripr::R.probe.snapshot.fetch("infect")).to be_empty

    Ripr::R.current_test = "SampleTest#test_redefined"
    String.alias_method(:>, :replace)
    expect(observe(left, "18")).to be(true)
    expect(left).to eq("20")
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_redefined"])
  ensure
    String.define_method(:>, original)
  end

  it "can disable operand observations" do
    start_probe(samples: false)
    observe(20, 18)
    expect(Ripr::R.probe.snapshot.fetch("samples")).to be_empty
    expect(Ripr::R.probe.snapshot.fetch("reach")).to have_key(site)
  end

  it "probes each scalar variant independently without collecting samples" do
    variants = { site => %w[equivalent changed] }
    Ripr::R.configure(variants, samples: false)
    Ripr::R.probe = Ripr::Probe.new(variants, samples: false)
    Ripr::R.current_test = "test_variants"
    calls = []
    value = Ripr::R.bin(site, 20, 18) do |left, right, variant|
      calls << variant
      case variant
      when 0 then left >= right
      when 1 then left > right
      when 2 then left == right
      else raise "unexpected variant #{variant}"
      end
    end

    expect(value).to be(true)
    expect(calls).to eq([0, 1, 2])
    expect(Ripr::R.probe.snapshot.fetch("infect")).to eq("changed" => ["test_variants"])
    expect(Ripr::R.probe.snapshot.fetch("samples")).to be_empty
  end

  it "does not speculate with only one safe operand when sampling is disabled" do
    start_probe(samples: false)
    phases = []
    unsafe = Object.new
    value = Ripr::R.bin(site, 20, unsafe) do |_left, _right, variant|
      phases << variant
      :original
    end

    expect(value).to eq(:original)
    expect(phases).to eq([0])
    expect(Ripr::R.probe.snapshot.fetch("infect")).to eq("adult-boundary" => ["SampleTest#test_adult"])
  end

  it "keeps unowned activity as load reach instead of assigning it to a test" do
    start_probe
    Ripr::R.current_test = nil
    observe(18, 18)
    snapshot = Ripr::R.probe.snapshot
    expect(snapshot.fetch("load_reached")).to eq([site])
    expect(snapshot.fetch("reach").fetch(site, [])).to be_empty
  end

  it "retains untracked reach outside the selected sites for cache invalidation" do
    start_probe
    Ripr::R.probe = Ripr::Probe.new({})
    observe(18, 18)
    Ripr::R.ret("other-return", :original)
    Ripr::R.lit("other-literal", :original, :mutated)
    Ripr::R.cond("other-condition", true)
    Ripr::R.on?("other-statement")
    Ripr::R.current_test = nil
    observe(18, 18)
    Ripr::R.ret("other-return", nil)
    Ripr::R.lit("other-literal", :original, :mutated)
    Ripr::R.cond("other-condition", true)
    Ripr::R.on?("other-statement")
    snapshot = Ripr::R.probe.snapshot
    expect(snapshot.fetch("reach")).to be_empty
    expect(snapshot.fetch("load_reached")).to eq([site, "other-return", "other-literal", "other-condition", "other-statement"])
    expect(snapshot.fetch("infect")).to be_empty
  end

  it "attributes concurrent tests independently" do
    start_probe
    threads = 8.times.map do |index|
      Thread.new do
        Ripr::R.current_test = "test_#{index}"
        10.times { observe(18, 18) }
      end
    end
    threads.each(&:join)
    snapshot = Ripr::R.probe.snapshot
    expect(snapshot.fetch("reach").fetch(site).sort).to eq(Array.new(8) { |i| "test_#{i}" })
    expect(snapshot.fetch("infect").fetch("adult-boundary").sort).to eq(Array.new(8) { |i| "test_#{i}" })
    expect(Ripr::R.current_test).to eq("SampleTest#test_adult")
  end

  it "keeps the current test when tested code starts a fiber" do
    start_probe
    Fiber.new { observe(18, 18) }.resume
    expect(Ripr::R.probe.snapshot.fetch("infect").fetch("adult-boundary")).to eq(["SampleTest#test_adult"])
  end

  it "exports all supported observations as JSON without calling arbitrary inspect" do
    {
      Rational(1, 2) => "1/2", Float::INFINITY => "Infinity",
      -Float::INFINITY => "-Infinity", Float::NAN => "NaN"
    }.each do |value, label|
      start_probe
      Ripr::R.bin(site, value, value) { |l, r, k| k.zero? ? l == r : l != r }
      snapshot = Ripr::R.probe.snapshot
      expect(snapshot.fetch("samples").fetch(site)).to eq([[label, label]])
      expect(JSON.parse(JSON.generate(snapshot))).to eq(snapshot)
    end
    expect(Ripr::Value.sample(:symbol)).to eq("symbol")
  end
end
