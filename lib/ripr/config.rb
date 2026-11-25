# frozen_string_literal: true

require "yaml"
require "etc"
require_relative "core/operators"

module Ripr
  class Config
    YAML_KEYS = %w[include exclude framework tests scope jobs operators arid_callees thresholds timeout samples
                   boot rails static typecheck].freeze
    DEFAULTS = {
      include: ["lib/**/*.rb"], exclude: ["lib/**/version.rb"], framework: "auto", tests: nil,
      scope: "node", jobs: "auto", operators: Core::Operators::NAMES,
      arid_callees: %w[logger.* puts pp warn], thresholds: { "high" => 80, "low" => 60, "break" => nil },
      timeout: { "factor" => 2.0, "base_ms" => 1000 }, samples: true,
      reporters: ["text"], report_dir: ".ripr/report", since: nil, only: [], full: false,
      dry_run: false, fail_on_survived: false, verify_not_infected: false, verify_killed: false, seed: 0, boot: nil, rails: false,
      include_tests_diff: false, static: false, call_graph_reuse: false, typecheck: nil, profile: false
    }.freeze

    def self.load(overrides = {}, path: ".ripr.yml")
      data = File.file?(path) ? YAML.safe_load_file(path, permitted_classes: [], aliases: false) : {}
      data ||= {}
      raise ArgumentError, "#{path} must contain a mapping" unless data.is_a?(Hash)

      unknown = data.keys.map(&:to_s) - YAML_KEYS
      raise ArgumentError, "unknown configuration keys: #{unknown.join(', ')}" unless unknown.empty?

      file_values = data.transform_keys(&:to_sym)
      values = DEFAULTS.merge(file_values).merge(overrides)
      rails_boot = values[:boot] && %w[config/application.rb config/environment.rb].all? { |file| File.file?(file) }
      values[:rails] = true if rails_boot && !file_values.key?(:rails) && !overrides.key?(:rails)
      values[:include] += ["app/**/*.rb"] if values[:rails] && !file_values.key?(:include) && !overrides.key?(:include)
      %i[timeout thresholds].each do |key|
        next unless file_values.fetch(key, {}).is_a?(Hash) && overrides.fetch(key, {}).is_a?(Hash)

        values[key] = DEFAULTS.fetch(key).merge(file_values.fetch(key, {})).merge(overrides.fetch(key, {}))
      end
      new(values)
    rescue Psych::Exception => e
      raise ArgumentError, "invalid configuration: #{e.message}"
    end

    def initialize(values)
      @values = values
      @automatic_jobs = @values[:jobs] == "auto"
      @values[:jobs] = Etc.nprocessors if @automatic_jobs
      @values[:operators] = Core::Operators::NAMES if @values[:operators] == "default"
      @values[:operators] = Core::Operators::FULL_NAMES if @values[:operators] == "full"
      validate
    end

    def [](key)
      @values.fetch(key)
    end

    def to_h
      @values.dup
    end

    def with_worker_limit
      return self unless @automatic_jobs

      limit = yield
      limit && limit < self[:jobs] ? self.class.new(@values.merge(jobs: limit)) : self
    end

    private

    def validate
      raise ArgumentError, "framework must be auto, minitest, or rspec" unless %w[auto minitest rspec].include?(self[:framework])
      raise ArgumentError, "scope must be node or method" unless %w[node method].include?(self[:scope])
      raise ArgumentError, "jobs must be auto or a positive integer" unless self[:jobs].is_a?(Integer) && self[:jobs].positive?
      raise ArgumentError, "seed must be an integer" unless self[:seed].is_a?(Integer)

      %i[include exclude arid_callees operators reporters only].each do |key|
        raise ArgumentError, "#{key} must be a list of strings" unless self[key].is_a?(Array) && self[key].all?(String)
      end
      unknown = self[:operators] - Core::Operators::FULL_NAMES
      raise ArgumentError, "unknown operators: #{unknown.join(', ')}" unless unknown.empty?

      unknown = self[:reporters] - %w[text agent agent-v2 json html github]
      raise ArgumentError, "unknown reporters: #{unknown.join(', ')}" unless unknown.empty?

      validate_mapping(:timeout, %w[factor base_ms])
      validate_mapping(:thresholds, %w[high low break])
      self[:timeout].each_value do |value|
        raise ArgumentError, "timeout values must be finite and positive" unless finite?(value) && value.positive?
      end
      self[:thresholds].each_value do |value|
        raise ArgumentError, "threshold must be between 0 and 100" unless value.nil? || (finite?(value) && value.between?(0, 100))
      end
      %w[high low].each do |key|
        raise ArgumentError, "#{key} threshold must be an integer" unless self[:thresholds][key].is_a?(Integer)
      end
      raise ArgumentError, "tests must be a glob string or a list" unless self[:tests].nil? || self[:tests].is_a?(String) ||
                                                                          (self[:tests].is_a?(Array) && self[:tests].all?(String))

      raise ArgumentError, "boot must be a file path" unless self[:boot].nil? || (self[:boot].is_a?(String) && !self[:boot].empty?)
      raise ArgumentError, "typecheck must be sorbet or rbs" unless self[:typecheck].nil? || %w[sorbet rbs].include?(self[:typecheck])

      %i[samples full dry_run fail_on_survived verify_not_infected verify_killed rails
         include_tests_diff static call_graph_reuse profile].each do |key|
        raise ArgumentError, "#{key} must be true or false" unless [true, false].include?(self[key])
      end
      return unless self[:include_tests_diff] && !self[:full] && (!self[:since] || self[:dry_run])

      raise ArgumentError, "--include-tests-diff requires --since and a test run"
    end

    def finite?(value)
      value.is_a?(Numeric) && value.finite?
    end

    def validate_mapping(key, allowed)
      value = self[key]
      raise ArgumentError, "#{key} must be a mapping" unless value.is_a?(Hash)
      raise ArgumentError, "unknown #{key} keys" unless (value.keys - allowed).empty?

      @values[key] = DEFAULTS.fetch(key).merge(value)
    end
  end
end
