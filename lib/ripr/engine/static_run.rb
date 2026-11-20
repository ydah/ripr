# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

module Ripr
  module Engine
    class StaticRun
      attr_reader :boot_ms

      def initialize(config, paths, boot_ms:)
        @config = config
        @paths = paths
        @boot_ms = boot_ms
      end

      def call(full_id, test_ids)
        request = { config: @config.to_h, paths: @paths, mutant: full_id, tests: test_ids }
        script = <<~RUBY
          puts JSON.generate(Ripr::Engine::StaticRun.run(JSON.parse($stdin.read)))
          $stdout.flush
          exit! 0
        RUBY
        output, diagnostics, status = Open3.capture3(RbConfig.ruby, "-r", File.expand_path(__FILE__), "-e", script,
                                                     stdin_data: JSON.generate(request))
        return JSON.parse(output) if status.success?

        { "status" => "error", "error" => "static worker failed to boot: #{diagnostics.lines.first(4).join.strip}" }
      end

      def self.run(request)
        require_relative "../config"
        require_relative "runner"

        config = Config.new(request.fetch("config").transform_keys(&:to_sym))
        runner = Runner.new(config, request.fetch("paths"))
        runner.run_static(request.fetch("mutant"), request.fetch("tests"))
      end
    end
  end
end
