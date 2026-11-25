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

  it "rejects unsupported collections even when one object appears on both sides" do
    cycle = []
    cycle << cycle
    shared = [1]
    frozen_unsupported = Object.new.freeze
    values = [cycle, [shared, shared], [frozen_unsupported].freeze, Class.new(Array).new([1]),
              Array.new(1_000, 1), 100.times.reduce(1) { |value, _index| [value] }, ["x" * 100_000],
              Array.new(5) { Array.new(32, 1) }, Hash.new { raise "called a default proc" }, { x: 1 }.compare_by_identity]

    values.each do |value|
      expect(Ripr::Value.pure?(value)).to be(false)
      expect(Ripr::Value.same?(value, value)).to be(false)
    end
  end

  it "does not compare Hash keys whose insertion-time hash can differ from their current value" do
    key = [1]
    hash = { key => :value }
    key << 2

    expect(Ripr::Value.snapshot(hash)).to be_nil
    expect(Ripr::Value.same?(hash, { [1, 2] => :value })).to be(false)
  end

  it "rejects user Data methods and singleton container methods without calling them" do
    point = Data.define(:value) do
      def ==(_other)
        raise "called Data equality"
      end
    end
    accessor = Data.define(:value) do
      def value
        raise "called a Data accessor"
      end
    end
    range = 1..2
    value = [1]
    value.define_singleton_method(:length) { raise "called a singleton method" }
    odd_range = Class.new(Range).new(range.begin, range.end)

    [point.new(1), accessor.new(1), value, odd_range].each do |unsafe|
      expect(Ripr::Value.pure?(unsafe)).to be(false)
      expect(Ripr::Value.same?(unsafe, unsafe)).to be(false)
    end
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
    Ripr::R.current_test = nil
    observe(18, 18)
    Ripr::R.ret("other-return", nil)
    Ripr::R.on?("other-statement")
    snapshot = Ripr::R.probe.snapshot
    expect(snapshot.fetch("reach")).to be_empty
    expect(snapshot.fetch("load_reached")).to eq([site, "other-return", "other-statement"])
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
    start_probe
    [Rational(1, 2), :symbol, Float::INFINITY, Float::NAN].each do |value|
      Ripr::R.bin(site, value, value) { |l, r, k| k.zero? ? l == r : l != r }
    end
    expect { JSON.generate(Ripr::R.probe.snapshot) }.not_to raise_error
  end
end
