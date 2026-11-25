# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "bundler"
require_relative "../../ripr"
require_relative "child"

module Ripr
  module Engine
    class TypeChecker
      TIMEOUT_MS = 60_000
      BACKENDS = {
        "sorbet" => [%w[srb tc], 100, /\A[^\r\n]+\.rbi?:\d+: \S/],
        "rbs" => [%w[steep check], 1, /\A[^\r\n]+:\d+:\d+: \[(?:error|warning)\] /]
      }.freeze

      def self.open(backend)
        raise ArgumentError, "unknown type checker #{backend.inspect}" unless BACKENDS.key?(backend)

        Dir.mktmpdir("ripr-typecheck") do |directory|
          project = File.join(directory, "project")
          Dir.mkdir(project)
          files = Dir.children(".") - %w[.git .ripr]
          FileUtils.cp_r(files, project, dereference_root: false)
          checker = new(backend, directory)
          checker.verify_baseline
          yield checker
        end
      end

      def initialize(backend, directory)
        @command, @diagnostic_exit, @diagnostic_pattern = BACKENDS.fetch(backend)
        @backend = backend
        @directory = File.realpath(File.join(directory, "project"))
        @env = { "BUNDLE_GEMFILE" => Bundler.default_gemfile.to_s, "XDG_CACHE_HOME" => File.join(directory, "cache") }
        if Bundler::VERSION.to_i >= 4
          lockfile = Bundler.default_lockfile.expand_path
          @env["BUNDLE_LOCKFILE"] = File.join(directory, lockfile.basename)
          FileUtils.cp(lockfile, @env.fetch("BUNDLE_LOCKFILE")) if lockfile.file?
        else
          @env["BUNDLE_FROZEN"] = "true"
        end
      rescue Bundler::GemfileNotFound => e
        raise Error, "#{@backend} typecheck requires a project bundle: #{e.message}"
      end

      def verify_baseline
        diagnostic = run
        raise Error, "#{@backend} typecheck baseline failed: #{diagnostic}" if diagnostic
      end

      def check(path, mutated_source)
        target = source_path(path)
        File.open(target, File::RDWR | File::NOFOLLOW) do |source|
          source.binmode
          original = source.read
          write_source(source, mutated_source)
          result = run
          raise Error, "#{@backend} type checker replaced #{path}" if File.symlink?(target) || !File.identical?(target, source)

          result
        ensure
          write_source(source, original) if original
        end
      end

      private

      def write_source(file, contents)
        file.rewind
        file.write(contents)
        file.truncate(file.pos)
        file.flush
      end

      def source_path(path)
        prefix = "#{@directory}/"
        target = File.expand_path(path, @directory)
        raise ArgumentError, "cannot typecheck a source outside the project: #{path}" unless target.start_with?(prefix)

        canonical = File.realpath(target)
        unless canonical.start_with?(prefix) && File.file?(canonical)
          raise ArgumentError, "cannot typecheck a source outside the project: #{path}"
        end

        canonical
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise ArgumentError, "cannot typecheck missing project source: #{path}"
      end

      def run
        result = Child.call(timeout_ms: TIMEOUT_MS) do
          output, stderr, status = Open3.capture3(@env, "bundle", "exec", *@command, chdir: @directory, binmode: true)
          text = "#{output}\n#{stderr}".force_encoding(Encoding::UTF_8).scrub.gsub(/\e\[[0-9;]*m/, "")
          diagnostic = text.each_line.find { |line| @diagnostic_pattern.match?(line) }
          { "exit_code" => status.exitstatus, "signal" => status.termsig, "diagnostic" => diagnostic&.strip&.slice(0, 800),
            "output" => text.strip[0, 800] }
        end
        raise Error, "#{@backend} typecheck timed out after #{TIMEOUT_MS}ms" if result["status"] == "timeout"
        return if result["exit_code"]&.zero?

        diagnostic = result["diagnostic"]
        return diagnostic if result["exit_code"] == @diagnostic_exit && diagnostic

        details = result["error"] || (result["output"] unless result["output"].to_s.empty?)
        details ||= result["signal"] ? "signal #{result['signal']}" : "exit status #{result['exit_code']}"
        raise Error, "#{@backend} typecheck failed to run: #{details}"
      end
    end
  end
end
