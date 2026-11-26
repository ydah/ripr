# frozen_string_literal: true

require "digest"
require_relative "../snapshot"
require_relative "reach_map"

module Ripr
  module Engine
    class ShardPlan
      VERSION = 1
      PATH = ".ripr/shard-plan.json"
      RESULT = "shard.json"
      MAX_SHARDS = 1024
      MAX_BYTES = 64 * 1024 * 1024
      MUTATION_FIELDS = %w[id full_id site method_hash location subject operator original mutated replacement mode accepted
                           static original_operator fixed_operands].freeze
      Document = Data.define(:data, :digest)

      attr_reader :index, :total, :document

      def self.total(value)
        unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,3}\z/) && value.to_i <= MAX_SHARDS
          raise ArgumentError, "shard count must be between 1 and #{MAX_SHARDS}"
        end

        value.to_i
      end

      def self.slice(value)
        index, total, extra = value.split("/", -1)
        unless index&.match?(/\A[1-9][0-9]{0,3}\z/) && total && !extra
          raise ArgumentError, "--shard requires INDEX/TOTAL, with a one-based index"
        end

        count = self.total(total)
        raise ArgumentError, "shard index cannot exceed the shard count" if index.to_i > count

        [index.to_i, count]
      end

      def self.read(path)
        bytes = File.open(path, File::RDONLY | File::NONBLOCK) do |file|
          raise ArgumentError, "shard plan must be a regular file" unless file.stat.file?

          file.binmode
          file.read(MAX_BYTES + 1) || ""
        end
        raise ArgumentError, "shard plan is too large" if bytes.bytesize > MAX_BYTES

        data = JSON.parse(bytes)
        unless data.is_a?(Hash) && data["version"] == VERSION && data["identity"].is_a?(Hash) && data["baseline"].is_a?(Hash) &&
               data["report"].is_a?(Hash) && valid_buckets?(data["shards"])
          raise ArgumentError, "invalid shard plan"
        end

        Document.new(data, Digest::SHA256.hexdigest(bytes))
      rescue Errno::ENOENT
        raise ArgumentError, "shard plan is missing: #{path}"
      rescue JSON::ParserError
        raise ArgumentError, "invalid shard plan JSON: #{path}"
      end

      def self.valid_buckets?(buckets)
        return false unless buckets.is_a?(Array) && buckets.length.between?(1, MAX_SHARDS) &&
                            buckets.all? { |bucket| bucket.is_a?(Array) && bucket.all? { |id| id.is_a?(String) && !id.empty? } }

        ids = buckets.flatten
        ids.uniq.length == ids.length
      end
      private_class_method :valid_buckets?

      def self.mutation_fingerprint(record)
        Digest::SHA256.hexdigest(JSON.generate(record.values_at(*MUTATION_FIELDS)))
      end

      def self.assign(costs, count)
        buckets = Array.new(count) { [] }
        totals = Array.new(count, 0)
        costs.sort_by { |id, cost| [-cost, id] }.each do |id, cost|
          index = totals.each_index.min_by { |i| [totals[i], buckets[i].length, i] }
          buckets[index] << id
          totals[index] += cost
        end
        buckets
      end

      def initialize(config, sources, probe_table, index:, total:)
        @index = index
        @total = total
        @path = File.expand_path(config[:shard_plan] || PATH)
        validate_output_path!(config[:report_dir])
        @git = Git.new
        @since = config[:since]
        if probe_table.values.flatten.tally.any? { |_, count| count > 1 }
          raise ArgumentError, "shard plan requires unique probe variant IDs"
        end

        @capture = ReachMap.new(sources, config) unless sources.empty?
        @project = project_identity(config, sources, probe_table)
        return unless @index

        @document = self.class.read(@path)
        return if @document.data.fetch("shards").length == @total && @document.data.fetch("identity").slice(*@project.keys) == @project

        raise ArgumentError, "shard plan does not match the checkout, runtime, run options, or shard count"
      end

      def capture(&)
        @capture ? @capture.capture(methods: false, &) : yield
      end

      def capture_baseline(&)
        existing = $LOADED_FEATURES.dup
        result = @capture.capture(loading: false, methods: false, &)
        observations = @capture.observations
        if observations.fetch("opaque_load") || !observations.fetch("opaque_tests").empty?
          raise ArgumentError, "shard plan cannot verify test inputs because the baseline observed opaque data or process state"
        end

        result.merge("test_load_inputs" => feature_inputs($LOADED_FEATURES - existing))
      end

      def boot_identity(framework, paths, tests, rails, load_reached)
        observations = @capture.observations
        database = @capture.database_inputs(rails)
        raise ArgumentError, "shard plan requires a readable SQLite snapshot for Rails" unless database
        raise ArgumentError, "shard plan cannot verify boot or test loading" if observations.fetch("opaque_load")

        @loaded_paths = paths + tests.map { |test| test.fetch("file") }
        @loaded_inputs = @capture.test_inputs(@loaded_paths)
        @loaded_features = feature_inputs($LOADED_FEATURES)
        { "framework" => framework, "test_load_order" => paths, "discovered" => tests,
          "test_inputs" => @loaded_inputs, "database_inputs" => database,
          "load_reads" => observations.fetch("load_reads"), "load_reached" => load_reached.sort,
          "loaded_features" => digest(@loaded_features) }
      end

      def validate_boot!(boot)
        return if @document.data.fetch("identity").slice(*boot.keys) == boot

        raise ArgumentError, "shard plan does not match loaded tests, boot inputs, or database"
      end

      def write(boot:, baseline:, shards:, selected:, report:, cache:)
        validate_stable_inputs!
        identity = @project.merge(boot).merge("mutation_fingerprints" => fingerprints(selected))
        Snapshot.new(@path).write("version" => VERSION, "identity" => identity, "baseline" => baseline, "shards" => shards,
                                  "report" => report, "cache" => cache)
        @path
      end

      def validate_test_load_inputs!(inputs)
        unless inputs.is_a?(Hash) && inputs.all? do |path, checksum|
          path.is_a?(String) && path.start_with?("/") && checksum.is_a?(String) && checksum.match?(/\A[0-9a-f]{64}\z/)
        end
          raise ArgumentError, "shard plan has invalid test load inputs"
        end
        unless feature_inputs(inputs.keys) == inputs
          raise ArgumentError, "shard plan does not match Ruby dependencies loaded by the baseline"
        end

        @test_load_inputs = inputs
      end

      def select(selected)
        validate_stable_inputs!
        expected = @document.data.fetch("shards")
        records = selected.to_h { |mutant| [mutant.full_id, mutant] }
        unless records.size == selected.length && expected.flatten.sort == records.keys.sort &&
               @document.data.fetch("identity")["mutation_fingerprints"] == fingerprints(selected)
          raise ArgumentError, "shard plan does not match the selected mutations"
        end

        expected.fetch(@index - 1).map { |id| records.fetch(id) }
      end

      def write_result(directory, results)
        path = File.expand_path(RESULT, directory)
        raise ArgumentError, "shard report cannot replace its plan" if path == @path || File.identical?(path, @path)

        validate_stable_inputs!
        Snapshot.new(path).write("version" => VERSION, "plan_digest" => @document.digest, "index" => @index, "total" => @total,
                                 "results" => results)
      end

      private

      def validate_output_path!(report_dir)
        snapshot = File.expand_path(".ripr/snapshot.json")
        reports = [RESULT, "mutation.json", "index.html", "profile.json"].map { |name| File.expand_path(name, report_dir) }
        path = canonical_output(@path)
        if [snapshot, *reports].any? { |other| path == canonical_output(other) || File.identical?(@path, other) }
          raise ArgumentError, "shard plan cannot replace a report or the ordinary snapshot"
        end
        return if @index

        return unless File.symlink?(@path) || (File.exist?(@path) && !valid_existing_plan?)

        raise ArgumentError, "shard plan cannot replace an existing non-plan file: #{@path}"
      end

      def valid_existing_plan?
        self.class.read(@path)
        true
      rescue ArgumentError
        false
      end

      def canonical_output(path)
        directory = File.dirname(path)
        File.join(File.realpath(directory), File.basename(path))
      rescue Errno::ENOENT
        File.join(canonical_output(directory), File.basename(path))
      end

      def project_identity(config, sources, probe_table)
        settings = config.to_h.slice(:include, :exclude, :framework, :tests, :operators, :arid_callees, :scope, :seed, :samples,
                                     :boot, :rails, :static, :full, :only, :include_tests_diff, :timeout, :jobs, :baseline_runs,
                                     :typecheck, :verify_killed, :verify_not_infected, :call_graph_reuse).transform_keys(&:to_s)
        { "head" => @git.clean_head(operation: "shard plan"), "project_prefix" => @git.project_prefix, "cwd" => Dir.pwd,
          "since_base" => since_base,
          "runtime" => [RUBY_DESCRIPTION, RUBY_PLATFORM, Prism::VERSION, Ripr::VERSION, Digest::SHA256.hexdigest(Marshal.dump(ENV.to_a.sort))],
          "implementation" => implementation_hash,
          "preloaded_features" => digest(feature_inputs($LOADED_FEATURES)),
          "settings" => settings, "sources" => sources.transform_values { |source| Digest::SHA256.hexdigest(source) },
          "probe_table" => Digest::SHA256.hexdigest(JSON.generate(probe_table.sort.to_h)),
          "inputs" => @capture&.provenance&.slice("boot_inputs", "external_inputs") }
      end

      def validate_stable_inputs!
        if @git.clean_head(operation: "shard plan") == @project.fetch("head") && since_base == @project.fetch("since_base") &&
           (!@capture || @capture.stable_inputs?) && (!@loaded_paths || @capture.test_inputs(@loaded_paths) == @loaded_inputs) &&
           (!@loaded_features || feature_inputs(@loaded_features.keys) == @loaded_features) &&
           (!@test_load_inputs || feature_inputs(@test_load_inputs.keys) == @test_load_inputs)
          return
        end

        raise ArgumentError, "project inputs changed while preparing the shard plan"
      end

      def since_base
        @git.merge_base(@since) if @since
      end

      def implementation_hash
        root = File.expand_path("../..", __dir__)
        content = Dir.glob("**/*.rb", base: root).sort.to_h { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }
        digest(content)
      end

      def feature_inputs(features)
        features.select { |path| path.start_with?("/") && File.file?(path) }.sort.uniq.to_h do |path|
          [path, Digest::SHA256.file(path).hexdigest]
        end
      end

      def digest(data)
        Digest::SHA256.hexdigest(JSON.generate(data))
      end

      def fingerprints(selected)
        selected.to_h { |mutant| [mutant.full_id, self.class.mutation_fingerprint(mutant.to_record)] }
      end
    end
  end
end
