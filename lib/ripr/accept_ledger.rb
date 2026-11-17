# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "time"
require "yaml"
require_relative "../ripr"

module Ripr
  class AcceptLedger
    def initialize(path = "ripr.accepted.yml")
      @path = File.expand_path(path)
    end

    def read
      return [] unless File.file?(@path)

      data = YAML.safe_load_file(@path, permitted_classes: [], permitted_symbols: [], aliases: false)
      valid = data.is_a?(Array) && data.all? do |entry|
        entry.is_a?(Hash) && %w[full_id method_hash reason].all? { |key| entry[key].is_a?(String) && !entry[key].strip.empty? }
      end
      raise Error, "invalid acceptance ledger #{@path}: expected an array of acceptances" unless valid

      data
    rescue Psych::Exception => e
      raise Error, "invalid acceptance ledger #{@path}: #{e.message}"
    end

    def accept(mutant, reason:)
      raise Error, "acceptance reason must not be empty" unless reason.is_a?(String) && !reason.strip.empty?

      entries = read.reject { |entry| entry["full_id"] == mutant.fetch("full_id") }
      entry = mutant.slice("id", "full_id", "operator", "original", "mutated", "method_hash")
                    .merge("reason" => reason, "recorded_at" => Time.now.utc.iso8601)
      entries << entry
      directory = File.dirname(@path)
      FileUtils.mkdir_p(directory)
      Tempfile.create(["accepted-", ".yml"], directory) do |file|
        file.write(YAML.dump(entries))
        file.flush
        file.fsync
        file.close
        File.rename(file.path, @path)
      end
      entry
    end

    def reason_for(mutant)
      entry = read.find { |item| item["full_id"] == mutant["full_id"] && item["method_hash"] == mutant["method_hash"] }
      entry && entry["reason"]
    end

    def stale?(mutant)
      read.any? { |entry| entry["full_id"] == mutant["full_id"] && entry["method_hash"] != mutant["method_hash"] }
    end
  end
end
