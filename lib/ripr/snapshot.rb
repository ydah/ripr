# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "tempfile"

module Ripr
  class Snapshot
    VERSION = 3

    def self.environment_hash
      Digest::SHA256.hexdigest(Marshal.dump(ENV.to_a.sort))
    end

    def initialize(path = ".ripr/snapshot.json")
      @path = File.expand_path(path)
    end

    def read
      return {} unless File.file?(@path)

      data = JSON.parse(File.read(@path))
      unless data.is_a?(Hash) && data["version"] == VERSION && data["mutants"].is_a?(Hash) && data["mutants"].values.all?(Hash)
        warn "ripr: ignoring unsupported snapshot #{@path}"
        return {}
      end
      data
    rescue JSON::ParserError
      warn "ripr: ignoring corrupt snapshot #{@path}"
      {}
    end

    def write(data)
      directory = File.dirname(@path)
      FileUtils.mkdir_p(directory)
      Tempfile.create(["snapshot-", ".json"], directory) do |file|
        file.write(JSON.generate(data))
        file.flush
        file.fsync
        file.close
        File.rename(file.path, @path)
      end
    end
  end
end
