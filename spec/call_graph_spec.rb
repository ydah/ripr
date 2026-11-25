# frozen_string_literal: true

require "ripr/core/call_graph"
require "erb"
require "fileutils"
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

  def sourced_callback(root, path, code)
    file = File.join(root, "lib", path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, code)
    RubyVM::InstructionSequence.compile_file(file).eval
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
    expect(invalid.trace { :original_result }).to eq([:original_result, nil])
  end

  it "invalidates changes to the first byte or to a definition's column" do
    code = "1.to_s\ndef self.first = 2; def self.second = 3\n"
    current = graph(code)
    expect(graph(code.sub("1.to_s", "9.to_s")).structure_hash).not_to eq(current.structure_hash)
    expect(graph(code.sub("first = 2", "first = 200")).structure_hash).not_to eq(current.structure_hash)
  end

  it "records dependencies when Ruby loads a configured source through its real path" do
    code = "class Sample\n#{source}end\n"
    Dir.mktmpdir do |directory|
      directory = File.realpath(directory)
      real_path = File.join(directory, "example.rb")
      link_path = File.join(directory, "linked.rb")
      File.write(real_path, code)
      File.symlink(real_path, link_path)
      current = described_class.new(link_path => code)
      scope = Module.new

      result, dependencies = current.trace do
        load(real_path, scope)
        scope.const_get(:Sample, false).root(3)
      end
      expect(result).to eq(5)
      expect(dependencies.size).to eq(2)
      changed = described_class.new(link_path => code.sub("value + 2", "value + 5"))
      expect(changed.signature(dependencies)).not_to eq(current.signature(dependencies))
    end
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

  it "refuses evidence from instruction sequence lookup and disassembly" do
    old_graph = graph(source)
    scope = Module.new.tap { |mod| mod.module_eval(source, path) }
    method = scope.method(:leaf)
    sequence, lookup_dependencies = old_graph.trace { RubyVM::InstructionSequence.of(method) }
    disassembly, disassembly_dependencies = old_graph.trace { sequence.disasm }
    expect(disassembly).to include("leaf")
    expect(lookup_dependencies).to be_nil
    expect(disassembly_dependencies).to be_nil
  end

  it "refuses invalid dependency records" do
    current = graph(source)
    expect(current.signature(nil)).to be_nil
    expect(current.signature(["invented"])).to be_nil
  end

  it "refuses AST inspection without a method call" do
    current = graph(source)
    _, dependencies = current.trace { RubyVM::AbstractSyntaxTree.parse_file(__FILE__) }
    expect(dependencies).to be_nil
  end

  it "refuses evidence when Prism parses a file" do
    result, dependencies = graph(source).trace { Prism.parse_file(__FILE__).success? }
    expect(result).to be(true)
    expect(dependencies).to be_nil
  end

  it "refuses evidence when work is delegated to another process" do
    result, dependencies = graph(source).trace { system("true") }
    expect(result).to be(true)
    expect(dependencies).to be_nil
  end

  it "refuses evidence when traced code enables its own trace" do
    lines = []
    nested = TracePoint.new(:line) { |event| lines << event.lineno }
    expect(graph(source).trace { nested.enable { :value } }).to eq([:value, nil])
    expect(lines).not_to be_empty
  end

  it "allows ordinary methods with names shared by reflection APIs" do
    object = Object.new
    def object.enable = 1
    def object.of = 2
    def object.to_a = [3]
    def object.parse_file = 4
    def object.spawn = 5

    result, dependencies = graph(source).trace { [object.enable, object.of, object.to_a, object.parse_file, object.spawn] }
    expect(result).to eq([1, 2, [3], 4, 5])
    expect(dependencies).to eq([])
  end

  it "refuses to reuse a result when native IO observes source bytes" do
    _, dependencies = graph(source).trace { IO.copy_stream(__FILE__, StringIO.new) }
    expect(dependencies).to be_nil
  end

  it "refuses a byte order mark check from user code labeled with line zero" do
    File.open(__FILE__, "rb") do |file|
      code = '->(stream) { stream.set_encoding("bom|utf-8") }'
      check_encoding = RubyVM::InstructionSequence.compile(code, file.path, file.path, 0).eval
      _, dependencies = graph(source).trace { check_encoding.call(file) }
      expect(dependencies).to be_nil
    end
  end

  it "permits RSpec to render option files and rejects external reads from their templates" do
    current = graph(source)
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        File.write(".rspec", '<%= "--color" %>')
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

  it "refuses evidence from evaluation in user code and ordinary ERB templates" do
    current = graph(source)
    expect(current.trace { Module.new.module_eval("1 + 1", __FILE__, __LINE__) }).to eq([2, nil])
    expect(current.trace { ERB.new("<%= 2 + 3 %>").result }).to eq(["5", nil])
  end

  it "refuses application reflection and external reads while tracing Rails tests" do
    current = described_class.new({ path => source }, rails: true)
    expect(current.trace { Module.new.module_eval("1 + 1", __FILE__, __LINE__) }).to eq([2, nil])
    expect(current.trace { File.read(__FILE__) }.last).to be_nil
  end

  it "refuses thread-local changes to the active trace function" do
    current = graph(source)
    expect(current.trace { Thread.current.set_trace_func(nil) }.last).to be_nil
    expect(current.trace { Thread.current.add_trace_func(proc {}) }.last).to be_nil
  ensure
    Thread.current.set_trace_func(nil)
  end

  it "recognizes only the audited Rails generator files and operations" do
    Dir.mktmpdir do |directory|
      package = File.join(directory, "activesupport")
      suffix = "active_support/code_generator.rb"
      evaluate = '-> { Module.new.module_eval("41 + 1") }'
      generated = sourced_callback(package, suffix, evaluate)
      unrelated = sourced_callback(directory, suffix, evaluate)
      unlisted = sourced_callback(package, suffix, '-> { Module.new.class_eval("41 + 1") }')
      specs = Gem.loaded_specs
      rails = described_class.new({ path => source }, rails: true)
      allow(Gem).to receive(:loaded_specs).and_return(specs.merge("activesupport" => double(full_gem_path: package)))

      expect(rails.trace(&generated)).to eq([42, []])
      expect(graph(source).trace(&generated)).to eq([42, nil])
      expect(rails.trace(&unrelated)).to eq([42, nil])
      expect(rails.trace(&unlisted)).to eq([42, nil])

      allow(Gem).to receive(:loaded_specs).and_return(specs.except("activesupport"))
      expect(rails.trace(&generated)).to eq([42, nil])
    end
  end

  it "distinguishes Rails log writes and file sizing from reads" do
    Dir.mktmpdir do |directory|
      suffix = "logger/log_device.rb"
      write = sourced_callback(directory, suffix, '->(stream) { [stream.stat.size, stream.write("data")] }')
      read = sourced_callback(directory, suffix, "->(stream) { stream.read }")
      rails = described_class.new({ path => source }, rails: true)
      specs = Gem.loaded_specs.merge("logger" => double(full_gem_path: directory))
      allow(Gem).to receive(:loaded_specs).and_return(specs)

      File.open(File.join(directory, "test.log"), "w+b") do |stream|
        expect(rails.trace { write.call(stream) }).to eq([[0, 4], []])
        stream.rewind
        expect(rails.trace { read.call(stream) }).to eq(["data", nil])
      end
    end
  end

  it "permits RSpec mocks to define their stubs" do
    object = Object.new
    def object.label = "original"

    result, dependencies = graph(source).trace do
      allow(object).to receive(:label).and_return("stubbed")
      object.label
    end
    expect(result).to eq("stubbed")
    expect(dependencies).to eq([])
  end

  it "permits empty methods and fingerprints changes to methods defined on arbitrary receivers" do
    code = <<~RUBY
      def self.empty; end
      target = Object.new
      def target.label = 1
    RUBY
    current = graph(code)
    scope = Module.new.tap { |mod| mod.module_eval(code, path) }

    expect(current.structure_hash).not_to be_nil
    expect(current.trace { scope.empty }).to eq([nil, []])
    expect(graph(code.sub("target.label = 1", "target.label = 2")).structure_hash).not_to eq(current.structure_hash)
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
