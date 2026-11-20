# frozen_string_literal: true

require "ripr/core/call_graph"
require "stringio"
require "tmpdir"

RSpec.describe Ripr::Core::CallGraph do
  let(:path) { "lib/example.rb" }
  let(:source) do
    <<~RUBY
      CONSTANT = 1
      def self.root(value)
        leaf(value * CONSTANT)
      end
      def self.leaf(value)
        value + 2
      end
      def self.unused
        42
      end
    RUBY
  end

  def graph(code)
    described_class.new(path => code)
  end

  it "tracks transitive calls and invalidates only dependencies with changed method bodies" do
    old_graph = graph(source)
    scope = Module.new.tap { |mod| mod.module_eval(source, path) }
    value, deps = old_graph.trace { scope.root(3) }
    expect(value).to eq(5)
    expect(deps.size).to eq(2)

    unrelated = graph(source.sub("42", "900"))
    callee = graph(source.sub("value + 2", "value + 5"))
    expect(unrelated.structure_hash).to eq(old_graph.structure_hash)
    expect(callee.structure_hash).to eq(old_graph.structure_hash)
    expect(unrelated.signature(deps)).to eq(old_graph.signature(deps))
    expect(callee.signature(deps)).not_to eq(old_graph.signature(deps))
  end

  it "invalidates changes outside bodies, to definition shape, or to file membership" do
    old_graph = graph(source)
    expect(graph(source.sub("CONSTANT = 1", "CONSTANT = 9")).structure_hash).not_to eq(old_graph.structure_hash)
    expect(graph(source.sub("leaf(value)", "leaf(value = 2)")).structure_hash).not_to eq(old_graph.structure_hash)
    expect(graph(source.sub("value + 2", "\nvalue + 2")).structure_hash).not_to eq(old_graph.structure_hash)
    other_path = described_class.new("lib/moved.rb" => source)
    expect(other_path.structure_hash).not_to eq(old_graph.structure_hash)
    invalid = graph("def invalid;")
    expect(invalid.structure_hash).to be_nil
    expect(invalid.signature([])).to be_nil
  end

  it "tracks a method body reached only through a block" do
    code = <<~RUBY
      def self.callback
        -> { 7 }
      end
    RUBY
    old_graph = graph(code)
    scope = Module.new.tap { |mod| mod.module_eval(code, path) }
    callback = scope.callback
    result, dependencies = old_graph.trace { callback.call }
    expect(result).to eq(7)
    expect(dependencies.size).to eq(1)
    expect(graph(code.sub("7", "8")).signature(dependencies)).not_to eq(old_graph.signature(dependencies))
  end

  it "refuses evidence from code inspection and invalid dependency records" do
    old_graph = graph(source)
    scope = Module.new.tap { |mod| mod.module_eval(source, path) }
    _, dependencies = old_graph.trace { RubyVM::InstructionSequence.of(scope.method(:leaf)).disasm }
    expect(dependencies).to be_nil
    expect(old_graph.signature(nil)).to be_nil
    expect(old_graph.signature(["invented"])).to be_nil
  end

  it "refuses AST inspection without a method call" do
    current = graph(source)
    _, dependencies = current.trace { RubyVM::AbstractSyntaxTree.parse_file(__FILE__) }
    expect(dependencies).to be_nil
  end

  it "refuses to reuse a result when native IO observes source bytes" do
    _, dependencies = graph(source).trace { IO.copy_stream(__FILE__, StringIO.new) }
    expect(dependencies).to be_nil
  end

  it "refuses a file encoding change that can inspect a byte order mark" do
    File.open(__FILE__, "rb") do |file|
      _, dependencies = graph(source).trace { file.set_encoding("bom|utf-8") }
      expect(dependencies).to be_nil
    end
  end

  it "permits RSpec to read option files and still rejects any file read by their ERB code" do
    current = graph(source)
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        File.write(".rspec", "--color\n")
        options, dependencies = current.trace { RSpec::Core::ConfigurationOptions.new([]).options }
        expect(options.fetch(:color)).to be(true)
        expect(dependencies).to eq([])

        File.write(".rspec", '<%= File.read("options.txt") %>')
        File.write("options.txt", "--color\n")
        options, dependencies = current.trace { RSpec::Core::ConfigurationOptions.new([]).options }
        expect(options.fetch(:color)).to be(true)
        expect(dependencies).to be_nil
      end
    end
  end

  it "refuses evidence from evaluation in user code" do
    _, dependencies = graph(source).trace { Module.new.module_eval("1 + 1", __FILE__, __LINE__) }
    expect(dependencies).to be_nil
  end

  it "fingerprints bodies that can define methods or execute a detached heredoc conservatively" do
    code = <<~RUBY
      def self.busy
        def nested; 1; end
      end
      def self.heredoc
        <<~TEXT
        original
        TEXT
      end
    RUBY
    old_graph = graph(code)
    expect(graph(code.sub("nested; 1;", "nested; 2;")).structure_hash).not_to eq(old_graph.structure_hash)
    expect(graph(code.sub("original", "changed")).structure_hash).not_to eq(old_graph.structure_hash)
  end
end
