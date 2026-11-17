# frozen_string_literal: true

require "yaml"
require "etc"
require_relative "core/operators"

module Ripr
  class Config
    YAML_KEYS = %w[include exclude framework tests scope jobs operators arid_callees thresholds timeout samples].freeze
    DEFAULTS = {
      include: ["lib/**/*.rb"], exclude: ["lib/**/version.rb"], framework: "auto", tests: nil,
      scope: "node", jobs: Etc.nprocessors, operators: Core::Operators::NAMES,
      arid_callees: %w[logger.* puts pp warn], thresholds: { "high" => 80, "low" => 60, "break" => nil },
      timeout: { "factor" => 2.0, "base_ms" => 1000 }, samples: true,
      reporters: ["text"], report_dir: ".ripr/report", since: nil, only: [], full: false,
      dry_run: false, fail_on_survived: false, verify_not_infected: false, seed: 0
    }.freeze

    def self.load(overrides = {}, path: ".ripr.yml")
      data = File.file?(path) ? YAML.safe_load_file(path, permitted_classes: [], aliases: false) : {}
      data ||= {}
      raise ArgumentError, "#{path} must contain a mapping" unless data.is_a?(Hash)

      unknown = data.keys.map(&:to_s) - YAML_KEYS
      raise ArgumentError, "unknown configuration keys: #{unknown.join(', ')}" unless unknown.empty?

      file_values = data.transform_keys(&:to_sym)
      values = DEFAULTS.merge(file_values).merge(overrides)
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
      @values[:jobs] = Etc.nprocessors if @values[:jobs] == "auto"
      @values[:operators] = Core::Operators::NAMES if @values[:operators] == "default"
      validate
    end

    def [](key)
      @values.fetch(key)
    end

    def to_h
      @values.dup
    end

    private

    def validate
      raise ArgumentError, "framework must be auto, minitest, or rspec" unless %w[auto minitest rspec].include?(self[:framework])
      raise ArgumentError, "scope must be node or method" unless %w[node method].include?(self[:scope])
      raise ArgumentError, "jobs must be a positive integer" unless self[:jobs].is_a?(Integer) && self[:jobs].positive?
      raise ArgumentError, "seed must be an integer" unless self[:seed].is_a?(Integer)

      %i[include exclude arid_callees operators reporters only].each do |key|
        raise ArgumentError, "#{key} must be a list of strings" unless self[key].is_a?(Array) && self[key].all?(String)
      end
      unknown = self[:operators] - Core::Operators::NAMES
      raise ArgumentError, "unknown operators: #{unknown.join(', ')}" unless unknown.empty?

      unknown = self[:reporters] - %w[text agent json html github]
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

      %i[samples full dry_run fail_on_survived verify_not_infected].each do |key|
        raise ArgumentError, "#{key} must be true or false" unless [true, false].include?(self[key])
      end
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
