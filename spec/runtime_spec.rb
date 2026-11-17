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

  it "distinguishes floating point signs and exact value classes" do
    expect(Ripr::Value.same?(0.0, -0.0)).to be(false)
    expect(Ripr::Value.same?(1, 1.0)).to be(false)
    expect(Ripr::Value.same?(Rational(1, 2), Rational(2, 4))).to be(true)
    expect(Ripr::Value.same?("x".encode(Encoding::UTF_8), "x".encode(Encoding::US_ASCII))).to be(false)
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
