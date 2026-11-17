# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

RSpec.describe "instrumented loading" do
  def isolated_loader(code, mode = "load_iseq")
    script = <<~RUBY
      require "json"
      require "tmpdir"
      require "ripr/loader"
      Dir.mktmpdir("ripr-loader") do |dir|
        #{code}
      end
    RUBY
    stdout, stderr, status = Open3.capture3({ "RIPR_LOADER" => mode }, RbConfig.ruby,
                                            "-I", File.expand_path("../lib", __dir__), "-e", script)
    expect(status.success?).to be(true), stderr
    JSON.parse(stdout)
  end

  %w[load_iseq require].each do |mode|
    it "preserves require return values and source files using #{mode}" do
      result = isolated_loader(<<~'RUBY', mode)
        path = File.join(dir, "target.rb")
        original = "$loaded_value = :original\n"
        File.write(path, original)
        loader = Ripr::Loader.new(path => "$loaded_value = :instrumented\n").install
        first = require(path)
        second = require(path)
        value = $loaded_value
        loader.uninstall
        puts JSON.generate([first, second, value, File.read(path) == original])
      RUBY
      expect(result).to eq([true, false, "instrumented", true])
    end

    it "records only code actually compiled by an active loader using #{mode}" do
      result = isolated_loader(<<~'RUBY', mode)
        path = File.join(dir, "target.rb")
        alias_path = File.join(dir, "alias.rb")
        code = "$value = :instrumented\n"
        File.write(path, "$value = :original\n")
        File.symlink(path, alias_path)
        loader = Ripr::Loader.new(path => code).install
        before = Ripr::Loader.instrumented?(path, code)
        require(path)
        during = Ripr::Loader.instrumented?(alias_path, code)
        different = Ripr::Loader.instrumented?(path, "$value = :different\n")
        loader.uninstall
        after = Ripr::Loader.instrumented?(path, code)
        load(path)
        loader.install
        reinstalled = Ripr::Loader.instrumented?(path, code)
        loader.uninstall
        puts JSON.generate([before, during, different, after, reinstalled])
      RUBY
      expect(result).to eq([false, true, false, false, false])
    end

    it "keeps original file and directory locations using #{mode}" do
      result = isolated_loader(<<~'RUBY', mode)
        path = File.join(dir, "target.rb")
        File.write(File.join(dir, "helper.rb"), "$helper_value = 42\n")
        File.write(path, "$unused = true\n")
        code = "require_relative 'helper'\n$loaded_location = [__FILE__, __dir__, __LINE__, $helper_value]\n"
        loader = Ripr::Loader.new(path => code).install
        require(path)
        loader.uninstall
        puts JSON.generate([$loaded_location, path, dir])
      RUBY
      expect(result[0]).to eq([result[1], result[2], 2, 42])
    end

    it "reevaluates load and removes its hooks on uninstall using #{mode}" do
      result = isolated_loader(<<~'RUBY', mode)
        path = File.join(dir, "target.rb")
        File.write(path, "$value = :original\n")
        loader = Ripr::Loader.new(path => "$runs = ($runs || 0) + 1\n$value = :instrumented\n").install
        load(path)
        load(path)
        instrumented = [$value, $runs]
        loader.uninstall
        load(path)
        puts JSON.generate([instrumented, $value])
      RUBY
      expect(result).to eq([["instrumented", 2], "original"])
    end
  end

  it "delegates non-target files to an existing load_iseq hook and restores it" do
    result = isolated_loader(<<~'RUBY')
      target = File.join(dir, "target.rb")
      other = File.join(dir, "other.rb")
      File.write(target, "$value = :original\n")
      File.write(other, "$other = true\n")
      delegated = []
      RubyVM::InstructionSequence.define_singleton_method(:load_iseq) do |path|
        delegated << path
        nil
      end
      original_owner = RubyVM::InstructionSequence.method(:load_iseq).owner
      loader = Ripr::Loader.new(target => "$value = :instrumented\n").install
      require(target)
      require(other)
      loader.uninstall
      puts JSON.generate([delegated.include?(other), delegated.include?(target),
                          RubyVM::InstructionSequence.method(:load_iseq).owner == original_owner])
    RUBY
    expect(result).to eq([true, false, true])
  end

  it "retains the earlier active loader registration when a nested loader is removed" do
    result = isolated_loader(<<~'RUBY')
      path = File.join(dir, "target.rb")
      code = "$value = :instrumented\n"
      File.write(path, "$value = :original\n")
      first = Ripr::Loader.new(path => code).install
      require(path)
      second = Ripr::Loader.new(path => code).install
      second.uninstall
      still_instrumented = Ripr::Loader.instrumented?(path, code)
      first.uninstall
      puts JSON.generate([still_instrumented, Ripr::Loader.instrumented?(path, code)])
    RUBY
    expect(result).to eq([true, false])
  end

  it "rejects wrapped target load rather than silently bypassing instrumentation in require mode" do
    result = isolated_loader(<<~'RUBY', "require")
      path = File.join(dir, "target.rb")
      other = File.join(dir, "other.rb")
      File.write(path, "VALUE = :original\n")
      File.write(other, "VALUE = :other\n")
      loader = Ripr::Loader.new(path => "VALUE = :instrumented\n").install
      message = begin
        load(path, true)
        nil
      rescue ArgumentError => error
        error.message
      end
      other_loaded = load(other, true)
      loader.uninstall
      puts JSON.generate([message, other_loaded, Object.const_defined?(:VALUE)])
    RUBY
    expect(result[0]).to include("wrapped load")
    expect(result[1..]).to eq([true, false])
  end

  it "keeps wrapped target constants scoped in load_iseq mode" do
    result = isolated_loader(<<~'RUBY')
      path = File.join(dir, "target.rb")
      File.write(path, "VALUE = :original\n$wrapped_value = VALUE\n")
      loader = Ripr::Loader.new(path => "VALUE = :instrumented\n$wrapped_value = VALUE\n").install
      loaded = load(path, true)
      loader.uninstall
      puts JSON.generate([loaded, $wrapped_value, Object.const_defined?(:VALUE)])
    RUBY
    expect(result).to eq([true, "instrumented", false])
  end

  it "preserves circular require and resolves names through the load path in require mode" do
    result = isolated_loader(<<~'RUBY', "require")
      path = File.join(dir, "target.rb")
      File.write(path, "$value = :original\n")
      $LOAD_PATH.unshift(dir)
      code = "$recursive = require('target')\n$value = :instrumented\n"
      loader = Ripr::Loader.new(path => code).install
      loaded = require("target")
      loader.uninstall
      puts JSON.generate([loaded, $recursive, $value])
    RUBY
    expect(result).to eq([true, false, "instrumented"])
  end

  it "instruments target load found through the load path in require mode" do
    result = isolated_loader(<<~'RUBY', "require")
      path = File.join(dir, "target.rb")
      File.write(path, "$value = :original\n")
      $LOAD_PATH.unshift(dir)
      loader = Ripr::Loader.new(path => "$value = :instrumented\n").install
      load("target.rb")
      loader.uninstall
      puts JSON.generate($value)
    RUBY
    expect(result).to eq("instrumented")
  end

  it "allows a target to be required again after removing its loaded feature" do
    result = isolated_loader(<<~'RUBY', "require")
      path = File.join(dir, "target.rb")
      File.write(path, "$value = :original\n")
      loader = Ripr::Loader.new(path => "$runs = ($runs || 0) + 1\n").install
      require(path)
      $LOADED_FEATURES.delete(path)
      reloaded = require(path)
      loader.uninstall
      puts JSON.generate([reloaded, $runs])
    RUBY
    expect(result).to eq([true, 2])
  end

  it "bypasses bootsnap for targets while retaining cache hits for other files" do
    result = isolated_loader(<<~'RUBY')
      require "bootsnap"
      Bootsnap.setup(cache_dir: File.join(dir, "cache"), development_mode: false,
                     load_path_cache: false, compile_cache_iseq: true, compile_cache_yaml: false,
                     compile_cache_json: false)
      events = []
      Bootsnap.instrumentation = ->(event, path) { events << [event.to_s, path] }
      target = File.join(dir, "target.rb")
      other = File.join(dir, "other.rb")
      File.write(target, "$value = :original\n")
      File.write(other, "$other = true\n")
      loader = Ripr::Loader.new(target => "$value = :instrumented\n").install
      require(target)
      load(other)
      load(other)
      loader.uninstall
      puts JSON.generate([$value, events.any? { |event, path| event == "hit" && path == other },
                          events.any? { |_event, path| path == target }])
    RUBY
    expect(result).to eq(["instrumented", true, false])
  end
end
