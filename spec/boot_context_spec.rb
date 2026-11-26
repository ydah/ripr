# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "tmpdir"
require "ripr/engine/boot_context"
require "ripr/loader"

RSpec.describe Ripr::Engine::BootContext do
  around do |example|
    Dir.mktmpdir("ripr-boot-context") { |root| Dir.chdir(root) { example.run } }
  end

  def fingerprint(boot: "setup.rb", rails: false, sources: [], snapshots: nil)
    context = described_class.new(boot: boot, rails: rails, source_paths: sources)
    loader = Ripr::Loader.new(sources.to_h { |path| [path, File.read(path)] }).install unless sources.empty?
    context.observe { load File.expand_path(boot) }
    context.fingerprint(sqlite_snapshots: snapshots)
  ensure
    loader&.uninstall
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  it "keeps a repeatable custom boot eligible and hashes its loaded files and environment" do
    write("setup.rb", <<~RUBY)
      load File.join(__dir__, "helpers", "settings.rb")
      File.read(File.join(__dir__, "settings.yml"))
      ENV.fetch("RIPR_BOOT_SECRET", nil)
    RUBY
    write("helpers/settings.rb", "'one'\n")
    write("settings.yml", "enabled: true\n")
    initial = fingerprint

    expect(initial).to match(/\A[a-f0-9]{64}\z/)
    expect(fingerprint).to eq(initial)
    write("helpers/settings.rb", "'two'\n")
    changed_load = fingerprint
    expect(changed_load).not_to eq(initial)
    write("settings.yml", "enabled: false\n")
    changed_input = fingerprint
    expect(changed_input).not_to eq(changed_load)

    ENV["RIPR_BOOT_SECRET"] = "private boot token"
    changed_environment = fingerprint
    expect(changed_environment).to match(/\A[a-f0-9]{64}\z/)
    expect(changed_environment).not_to eq(changed_input)
    expect(changed_environment).not_to include("private boot token")
  ensure
    ENV.delete("RIPR_BOOT_SECRET")
  end

  it "tracks dirty and untracked configuration, fixtures, schema, and lockfiles" do
    write("setup.rb", "true\n")
    previous = fingerprint

    %w[config/.local.yml db/schema.rb db/structure.sql test/fixtures/widgets.yml Gemfile.lock].each do |path|
      write(path, "first\n")
      added = fingerprint
      expect(added).not_to eq(previous)
      write(path, "changed\n")
      previous = fingerprint
      expect(previous).not_to eq(added)
    end
  end

  it "tracks external file contents actually consumed by a boot file" do
    Tempfile.create do |external|
      external.write("first\n")
      external.flush
      write("setup.rb", "File.binread(#{external.path.dump})\n")
      first = fingerprint
      expect(first).to match(/\A[a-f0-9]{64}\z/)
      File.write(external.path, "second\n")
      expect(fingerprint).not_to eq(first)
    end
  end

  it "leaves dynamic processes, application time, randomness, and string evaluation opaque" do
    operations = ["system(RbConfig.ruby, '-e', 'exit 0')", "Time.now", "eval('true')",
                  "[1, 2].sample", "[1, 2].shuffle", "[1, 2].shuffle!"]
    operations.each do |code|
      write("setup.rb", "#{code}\n")
      expect(fingerprint).to be_nil
    end
  end

  it "rejects application file operations whose yielded values cannot be observed" do
    write("source.yml", "enabled: true\n")
    write("setup.rb", "File.foreach('source.yml') { |line| line }\n")
    expect(fingerprint).to be_nil
  end

  it "refuses boot code that introspects method bodies or starts a tracer" do
    operations = ["RubyVM::InstructionSequence.of(method(:puts))", "TracePoint.new(:call) {}.enable {}",
                  "Thread.current.set_trace_func(nil)"]
    operations.each do |code|
      write("setup.rb", "#{code}\n")
      expect(fingerprint).to be_nil
    end
  end

  it "keeps graph-managed methods out of the boot digest until boot executes them" do
    write("setup.rb", "load File.join(__dir__, 'lib/sample.rb')\n")
    write("lib/sample.rb", "def ripr_boot_example; 1; end\n")
    sources = ["lib/sample.rb"]
    initial = fingerprint(sources: sources)
    write("lib/sample.rb", "def ripr_boot_example; 2; end\n")
    expect(fingerprint(sources: sources)).to eq(initial)

    write("setup.rb", "load File.join(__dir__, 'lib/sample.rb')\nripr_boot_example\n")
    called = fingerprint(sources: sources)
    write("lib/sample.rb", "def ripr_boot_example; 3; end\n")
    expect(fingerprint(sources: sources)).not_to eq(called)
  ensure
    Object.send(:remove_method, :ripr_boot_example) if Object.private_method_defined?(:ripr_boot_example, false)
  end

  it "requires prepared Rails snapshots and observes both the pristine and ready state" do
    write("setup.rb", "true\n")
    expect(fingerprint(rails: true)).to be_nil
    expect(fingerprint(rails: true, snapshots: [])).to match(/\A[a-f0-9]{64}\z/)

    Dir.mktmpdir("ripr-rails-snapshots") do |directory|
      snapshots = %w[pristine ready].map { |name| File.join(directory, name) }
      snapshots.each { |path| File.write(path, "starting database state\n") }
      first = fingerprint(rails: true, snapshots: snapshots)
      expect(first).to match(/\A[a-f0-9]{64}\z/)
      File.write(snapshots.first, "modified pristine state\n")
      second = fingerprint(rails: true, snapshots: snapshots)
      expect(second).not_to eq(first)
      File.write(snapshots.last, "modified ready state\n")
      expect(fingerprint(rails: true, snapshots: snapshots)).not_to eq(second)
    end
  end
end
