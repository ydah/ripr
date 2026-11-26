# frozen_string_literal: true

require_relative "shard_merge"
require_relative "shard_plan"

module Ripr
  module Engine
    module ShardReport
      Context = Data.define(:sources, :static, :framework, :metrics, :changed_source_lines, :public_subjects)
      private_constant :Context

      def self.write(config, plan_path, paths, stdout:)
        document = ShardPlan.read(plan_path)
        plan = document.data
        results = ShardMerge.call(plan, document.digest, paths)
        identity = plan.fetch("identity")
        raise ArgumentError, "shard plan does not match the merge runtime" unless identity.fetch("runtime") == ShardPlan.runtime_identity

        context = report_context(plan.fetch("report"), sources_for(identity))
        run = plan.fetch("report").fetch("run")
        settings = identity.fetch("settings")
        report_config = Config.new(config.to_h.merge(since: run["since"], scope: run.fetch("scope"),
                                                     rails: settings.fetch("rails"), boot: settings["boot"]))
        cache = cache_context(plan)
        inputs = verified_inputs(identity) if cache
        check_output_paths(config, [plan_path, *paths], cache: !cache.nil?)
        summary = Reporters.write(results, context, report_config, stdout: stdout)
        ResultCache.write_merged(cache, results, plan.fetch("baseline"), context.metrics, inputs:) if cache
        summary
      rescue KeyError, TypeError => e
        raise ArgumentError, "invalid shard report context (#{e.class})"
      end

      def self.sources_for(identity)
        git = Git.new
        unless git.clean_head(operation: "shard merge") == identity.fetch("head") &&
               git.project_prefix == identity.fetch("project_prefix") && Dir.pwd == identity.fetch("cwd")
          raise ArgumentError, "shard plan does not match the merge checkout"
        end

        root = "#{Dir.pwd}/"
        fingerprints = identity.fetch("sources")
        raise ArgumentError, "invalid shard source fingerprints" unless fingerprints.is_a?(Hash)

        fingerprints.to_h do |path, digest|
          absolute = File.expand_path(path)
          unless absolute.start_with?(root) && absolute.delete_prefix(root) == path && File.realpath(absolute).start_with?(root)
            raise ArgumentError, "shard source is outside the merge checkout"
          end

          content = File.open(absolute, File::RDONLY | File::NONBLOCK) do |file|
            raise ArgumentError, "shard source must be a regular file: #{path}" unless file.stat.file?

            file.binmode.read
          end
          raise ArgumentError, "shard source has changed: #{path}" unless Digest::SHA256.hexdigest(content) == digest

          [path, content]
        end
      end

      def self.report_context(report, sources)
        run = report.fetch("run")
        metrics = run.fetch("metrics")
        static = report.fetch("static")
        lines = report.fetch("changed_source_lines")
        public_subjects = report.fetch("public_subjects")
        unless run.is_a?(Hash) && [nil, "minitest", "rspec"].include?(run["framework"]) &&
               (run["since"].nil? || run["since"].is_a?(String)) && metrics.is_a?(Hash) &&
               %w[baseline_tests_run reused].all? { |key| metrics[key].is_a?(Integer) && metrics[key] >= 0 } &&
               static.is_a?(Integer) && static >= 0 && lines.is_a?(Hash) &&
               lines.values.all? { |entries| entries.is_a?(Array) && entries.all?(Integer) } &&
               public_subjects.is_a?(Hash) && public_subjects.values.all?(true)
          raise ArgumentError, "invalid shard report context"
        end

        Context.new(sources, static, run["framework"], metrics, lines, public_subjects)
      end

      def self.cache_context(plan)
        context = plan.fetch("cache")
        return context if context.nil? && plan.fetch("shards").all?(&:empty?)
        return context if context.is_a?(Hash) && digest?(context["env_hash"]) && digest?(context["source_hash"]) &&
                          context["test_hashes"].is_a?(Hash) && context["test_hashes"].values.all? { |value| digest?(value) }

        raise ArgumentError, "invalid shard cache context"
      end

      def self.digest?(value)
        value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
      end

      def self.verified_inputs(identity)
        files = identity.fetch("loaded_features").merge(identity.fetch("test_load_inputs"))
        project_inputs = identity.fetch("inputs").fetch("boot_inputs").merge(identity.fetch("test_inputs"))
        files = project_inputs.transform_keys { |path| File.expand_path(path) }.merge(files)
        raise ArgumentError, "shard plan test, Ruby, or boot inputs have changed" unless ShardPlan.feature_inputs(files.keys) == files

        { "environment" => identity.fetch("runtime").last, "files" => files }
      rescue SystemCallError, IOError
        raise ArgumentError, "cannot verify shard plan test, Ruby, or boot inputs"
      end

      def self.check_output_paths(config, inputs, cache:)
        reporters = config[:reporters]
        paths = []
        paths << File.join(config[:report_dir], "mutation.json") if reporters.intersect?(%w[json html])
        paths << File.join(config[:report_dir], "index.html") if reporters.include?("html")
        paths << ".ripr/snapshot.json" if cache
        if paths.any? { |path| inputs.any? { |input| File.expand_path(input) == File.expand_path(path) || File.identical?(input, path) } }
          raise ArgumentError, "shard merge outputs cannot replace their inputs"
        end
      end

      private_class_method :sources_for, :report_context, :cache_context, :digest?, :verified_inputs, :check_output_paths
    end
  end
end
