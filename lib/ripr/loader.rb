# frozen_string_literal: true

require "monitor"

module Ripr
  class Loader
    def initialize(code_by_path)
      @code = code_by_path.to_h { |path, code| [File.expand_path(path), code] }
      @paths = @code.keys.to_h { |path| [File.realpath(path), path] }
      @hooks = []
      @loading = []
      @required = {}
      @lock = Monitor.new
    end

    def install
      return self unless @hooks.empty?

      if ENV["RIPR_LOADER"] == "require"
        install_require_hook(Kernel, private_methods: true)
        install_require_hook(Kernel.singleton_class, private_methods: false)
      else
        install_iseq_hook
      end
      self
    end

    def uninstall
      @hooks.each do |hook|
        (hook.instance_methods(false) + hook.private_instance_methods(false)).each do |name|
          hook.send(:remove_method, name)
        end
      end
      @hooks.clear
      self
    end

    def code_for(path)
      @code[@paths[File.realpath(path)]]
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def resolve_require(feature, extension: true)
      feature = File.path(feature)
      names = if !extension || feature.end_with?(".rb")
                [feature]
              else
                ["#{feature}.rb", "#{feature}.so", "#{feature}.bundle"]
              end
      directories = feature.start_with?("/", "./", "../") ? [Dir.pwd] : $LOAD_PATH
      directories += [Dir.pwd] unless extension
      directories.each do |directory|
        names.each do |name|
          path = File.expand_path(name, directory)
          next unless File.file?(path)

          return code_for(path) ? path : nil
        end
      end
      nil
    end

    def require_target(path)
      @lock.synchronize do
        canonical = File.realpath(path)
        return false if $LOADED_FEATURES.include?(path) || $LOADED_FEATURES.include?(@required[canonical]) || @loading.include?(canonical)

        @loading << canonical
        begin
          evaluate(path)
          $LOADED_FEATURES << path
          @required[canonical] = path
          true
        ensure
          @loading.delete(canonical)
        end
      end
    end

    def evaluate(path)
      RubyVM::InstructionSequence.compile(code_for(path), path, path).eval
    end

    private

    def install_iseq_hook
      loader = self
      hook = Module.new do
        define_method(:load_iseq) do |path|
          code = loader.code_for(path)
          if code
            RubyVM::InstructionSequence.compile(code, path, path)
          else
            defined?(super) ? super(path) : nil
          end
        end
      end
      RubyVM::InstructionSequence.singleton_class.prepend(hook)
      @hooks << hook
    end

    def install_require_hook(target, private_methods:)
      loader = self
      hook = Module.new do
        define_method(:require) do |feature|
          path = loader.resolve_require(feature)
          path ? loader.require_target(path) : super(feature)
        end

        define_method(:require_relative) do |feature|
          location = caller_locations(1, 1).first
          base = location&.absolute_path
          raise LoadError, "cannot infer basepath" unless base

          require(File.expand_path(File.path(feature), File.dirname(base)))
        end

        define_method(:load) do |feature, wrap = false|
          path = loader.resolve_require(feature, extension: false)
          if path
            if wrap
              raise ArgumentError,
                    "ripr require loader does not support wrapped load for instrumented files; use load_iseq"
            end
            loader.evaluate(path)
            true
          else
            super(feature, wrap)
          end
        end
        private :require, :require_relative, :load if private_methods
      end
      target.prepend(hook)
      @hooks << hook
    end
  end
end
