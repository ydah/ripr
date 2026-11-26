# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "rbconfig"
require "tempfile"

module Ripr
  module Engine
    class StaticRun
      PLAN_FD = 3
      private_constant :PLAN_FD

      attr_reader :boot_ms

      def initialize(config, paths, boot_ms:, &plan)
        @config = config
        @paths = paths
        @boot_ms = boot_ms
        @plan = plan
      end

      def prepare
        return unless @plan

        bytes = JSON.generate(@plan.call)
        Tempfile.create("ripr-static-plan") do |file|
          file.binmode
          file.write(bytes)
          file.flush
          @plan_file = File.open(file.path, "rb")
        end
        @plan_identity = [bytes.bytesize, Digest::SHA256.hexdigest(bytes)]
      rescue JSON::GeneratorError, EncodingError, IOError, SystemCallError
        close
      end

      def close
        @plan_file&.close
        @plan_file = @plan_identity = nil
      end

      def call(full_id, test_ids)
        request = { config: @config.to_h, paths: @paths, mutant: full_id, tests: test_ids, plan: @plan_identity }
        options = @plan_file ? { PLAN_FD => @plan_file } : {}
        script = <<~RUBY
          puts JSON.generate(Ripr::Engine::StaticRun.run(JSON.parse($stdin.read)))
          $stdout.flush
          exit! 0
        RUBY
        output, diagnostics, status = Open3.capture3(RbConfig.ruby, "-r", File.expand_path(__FILE__), "-e", script,
                                                     stdin_data: JSON.generate(request), **options)
        return JSON.parse(output) if status.success?

        { "status" => "error", "error" => "static worker failed to boot: #{diagnostics.lines.first(4).join.strip}" }
      end

      def self.run(request)
        require_relative "../config"
        require_relative "runner"

        config = Config.new(request.fetch("config").transform_keys(&:to_sym))
        runner = Runner.new(config, request.fetch("paths"))
        runner.run_static(request.fetch("mutant"), request.fetch("tests"), prepared: read_plan(request["plan"]))
      end

      def self.read_plan(identity)
        return unless identity

        size, digest = identity
        bytes = IO.open(PLAN_FD, "rb") { |file| file.pread(size, 0) }
        JSON.parse(bytes) if Digest::SHA256.hexdigest(bytes) == digest
      rescue ArgumentError, JSON::ParserError, IOError, SystemCallError, NotImplementedError, TypeError
        nil
      end
      private_class_method :read_plan
    end
  end
end
