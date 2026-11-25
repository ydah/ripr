# frozen_string_literal: true

require "open3"
require_relative "../ripr"

module Ripr
  class Git
    def initialize(root = Dir.pwd)
      @root = File.expand_path(root)
    end

    def clean_head
      cache_entry = "?? #{project_prefix}.ripr/".b
      status = execute("status", "--porcelain=v1", "-z", "--untracked-files=all").split("\0")
      raise ArgumentError, "reach-map requires a clean Git worktree" unless status.all? { |entry| entry.start_with?(cache_entry) }

      execute("rev-parse", "--verify", "HEAD^{commit}").strip
    rescue Error => e
      raise ArgumentError, e.message
    end

    def project_prefix
      execute("rev-parse", "--show-prefix").chomp.force_encoding(Encoding::UTF_8)
    end

    def merge_base(ref)
      execute("merge-base", "--", ref, "HEAD").strip
    end

    def repository_changes(base)
      changed = path_entries("diff", "--no-relative", "--name-only", "-z", "--no-renames", base, "--")
      untracked = path_entries("ls-files", "--full-name", "--others", "--exclude-standard", "-z", "--", ":/")
      changed | untracked.reject { |path| path.start_with?("#{project_prefix}.ripr/") }
    end

    def content(base, path)
      execute("show", "#{base}:#{project_prefix}#{path}")
    end

    def changed_lines(ref, paths = nil, include_all_paths: false)
      base = merge_base(ref)
      selected = Array(paths)
      entries = path_entries("diff", "--relative", "--name-status", "-z", "--find-renames", base, "--", *selected)
      changed = {}
      until entries.empty?
        status = entries.shift
        original = entries.shift
        destination = status.start_with?("R", "C") ? entries.shift : original
        changed[original] = [] if include_all_paths && status.start_with?("D", "R")
        next if status.start_with?("D") || !File.file?(File.join(@root, destination))

        diff_paths = status.start_with?("R", "C") ? [original, destination] : [destination]
        diff = execute("diff", "--relative", "--unified=0", "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames", base, "--",
                       *diff_paths)
        lines = hunk_lines(diff)
        changed[destination] = lines if include_all_paths || !lines.empty?
      end
      path_entries("ls-files", "--others", "--exclude-standard", "-z", "--", *selected).each do |path|
        absolute = File.join(@root, path)
        next unless File.file?(absolute)

        lines = File.binread(absolute).lines.count
        changed[path] = (1..lines).to_a if include_all_paths || !lines.zero?
      end
      changed
    end

    private

    def path_entries(*arguments)
      execute(*arguments).split("\0").map! { |entry| entry.force_encoding(Encoding::UTF_8) }
    end

    def execute(*arguments)
      output, error, status = Open3.capture3("git", "-C", @root, *arguments, binmode: true)
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
