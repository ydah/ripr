# frozen_string_literal: true

require "open3"
require_relative "../ripr"

module Ripr
  class Git
    def initialize(root = Dir.pwd)
      @root = File.expand_path(root)
    end

    def changed_lines(ref, paths = nil)
      base = execute("merge-base", "--", ref, "HEAD").strip
      selected = Array(paths)
      entries = execute("diff", "--relative", "--name-status", "-z", "--find-renames", base, "--", *selected).split("\0")
      changed = {}
      until entries.empty?
        status = entries.shift
        original = entries.shift
        destination = status.start_with?("R", "C") ? entries.shift : original
        next if status.start_with?("D") || !File.file?(File.join(@root, destination))

        diff_paths = status.start_with?("R", "C") ? [original, destination] : [destination]
        diff = execute("diff", "--relative", "--unified=0", "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames", base, "--",
                       *diff_paths)
        lines = hunk_lines(diff)
        changed[destination] = lines unless lines.empty?
      end
      execute("ls-files", "--others", "--exclude-standard", "-z", "--", *selected).split("\0").each do |path|
        absolute = File.join(@root, path)
        next unless File.file?(absolute)

        lines = File.binread(absolute).lines.count
        changed[path] = (1..lines).to_a unless lines.zero?
      end
      changed
    end

    private

    def execute(*arguments)
      output, error, status = Open3.capture3("git", "-C", @root, *arguments)
      raise Error, "git #{arguments.first} failed: #{error.strip}" unless status.success?

      output
    rescue Errno::ENOENT => e
      raise Error, "git is unavailable: #{e.message}"
    end

    def hunk_lines(diff)
      diff.scan(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/).flat_map do |start, length|
        first = start.to_i
        count = length.nil? ? 1 : length.to_i
        count.zero? ? [first, first + 1] : (first...(first + count)).to_a
      end.uniq.sort
    end
  end
end
