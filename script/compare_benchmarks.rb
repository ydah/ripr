# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "timeout"

module CompareBenchmarks
  class TimedOut < StandardError
    attr_reader :partial

    def initialize(limit, partial)
      @partial = partial
      super("Command exceeded #{limit} seconds")
    end
  end

  module_function

  def signal_process(signal, pid)
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  rescue Errno::EPERM => e
    raise e.class, "sending #{signal} to PID #{pid}: #{e.message}", e.backtrace
  end

  # shortcut: reparented descendants in new groups escape discovery, use OS supervision if complete descendant cleanup is required.
  def kill_tree(pid)
    descendants = [pid]
    cleanup_errors = []
    try_signal = lambda do |signal, target|
      signal_process(signal, target)
    rescue Errno::EPERM => e
      cleanup_errors << "#{e.class}: #{e.message}"
    end
    begin
      try_signal.call("STOP", -pid)
      2.times do
        output, status = Open3.capture2("ps", "-eo", "pid=,ppid=")
        raise "Cannot inspect benchmark process tree" unless status.success?

        rows = output.lines.map { |line| line.split.map(&:to_i) }
        loop do
          children = rows.filter_map { |child, parent| child if descendants.include?(parent) && !descendants.include?(child) }
          break if children.empty?

          descendants.concat(children)
        end
        descendants.each { |child| try_signal.call("STOP", child) }
      end
    ensure
      signal_process("KILL", pid)
      descendants.reverse_each { |child| try_signal.call("KILL", child) unless child == pid }
      try_signal.call("KILL", -pid)
    end
    cleanup_errors
  end

  def contained(directory, relative)
    path = File.expand_path(relative, directory)
    raise ArgumentError, "path escapes benchmark directory: #{relative}" unless path.start_with?("#{directory}/")

    path
  end

  def summary(config, stdout)
    if config.fetch("format") == "mutant"
      fields = { "total" => "Mutations", "killed" => "Kills", "survived" => "Alive" }
      return fields.to_h do |key, label|
        value = stdout.scan(/^\s*#{label}:\s+(\d+)/).last
        raise "No mutant #{label} result" unless value

        [key, value.first.to_i]
      end
    end

    text = if config["report"]
             paths = Dir[contained(config.fetch("directory"), config.fetch("report"))]
             raise "Report not created" if paths.empty?

             File.read(paths.max_by { |path| File.mtime(path) })
           else
             stdout
           end
    data = JSON.parse(text)
    case config.fetch("format")
    when "ripr"
      counts = data.fetch("summary")
      total = %w[killed timeout error survived accepted].sum { |key| counts.fetch(key, 0) }
      { "total" => total, "survived" => counts.fetch("survived"), "counts" => counts }
    when "mutineer"
      counts = data.fetch("summary")
      { "total" => counts.fetch("total"), "survived" => counts.fetch("survived"), "counts" => counts }
    when "active_mutator"
      counts = data.fetch("counts")
      { "total" => counts.values.sum, "survived" => counts.fetch("survived"), "counts" => counts }
    when "henitai"
      mutants = data.fetch("files").values.flat_map { |file| file.fetch("mutants") }
      counts = mutants.group_by { |mutant| mutant.fetch("status") }.transform_values(&:size)
      { "total" => mutants.size, "survived" => counts.fetch("Survived", 0), "counts" => counts }
    else
      raise ArgumentError, "unknown report format"
    end
  end

  def run(config, command, label)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout = +"".b
    stderr = +"".b
    status = nil
    timed_out = false
    cleanup_errors = []
    input, output, error, process = Open3.popen3(config.fetch("env", {}), *command, chdir: config.fetch("directory"), pgroup: true)
    input.close
    readers = [output, error].zip([stdout, stderr]).map do |stream, buffer|
      Thread.new do
        loop { buffer << stream.readpartial(16_384) }
      rescue IOError
        nil
      end
    end
    begin
      Timeout.timeout(config.fetch("timeout_seconds", 120)) do
        status = process.value
        readers.each(&:value)
      end
    rescue Timeout::Error
      timed_out = true
      cleanup_errors = kill_tree(process.pid)
      status = process.value
    ensure
      [output, error].each { |stream| stream.close unless stream.closed? }
      readers.each(&:value)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    logs = File.join(config.fetch("directory"), "comparison-logs")
    FileUtils.mkdir_p(logs)
    File.write(File.join(logs, "#{label}.stdout"), stdout)
    File.write(File.join(logs, "#{label}.stderr"), stderr)
    if timed_out
      partial = { "seconds" => elapsed, "phase" => label, "stdout_bytes" => stdout.bytesize, "stderr_bytes" => stderr.bytesize }
      partial["cleanup_errors"] = cleanup_errors unless cleanup_errors.empty?
      raise TimedOut.new(config.fetch("timeout_seconds", 120), partial)
    end
    unless config.fetch("exit_codes", [0, 1, 2]).include?(status.exitstatus)
      raise "exit #{status.exitstatus}: #{stderr.lines.last(12).join}#{stdout.lines.last(12).join}"
    end

    counts = summary(config, stdout)
    raise "No mutants reported for the full scope" if label.start_with?("cold-") && counts.fetch("total").zero?

    { "seconds" => elapsed, "exit_code" => status.exitstatus, "summary" => counts }
  end

  def measure(config)
    directory = File.expand_path(config.fetch("directory"))
    config = config.merge("directory" => directory)
    path = contained(directory, config.fetch("file"))
    original = File.binread(path)
    before = config.fetch("before")
    raise "Expected one edit site" unless original.scan(before).size == 1

    edited = original.sub(before, config.fetch("after"))
    result = config.slice("project", "tool", "file", "format").merge("commands" => config.slice("full", "incremental"))
    clear_cache = -> { config.fetch("caches").each { |cache| FileUtils.rm_rf(contained(directory, cache)) } }
    cold_count = config["probe_only"] ? 1 : 3
    result["full"] = []
    result["incremental"] = [] unless config["probe_only"]
    cold_count.times do |index|
      File.binwrite(path, original)
      clear_cache.call
      warn "#{config.fetch('project')} #{config.fetch('tool')} cold #{index + 1}/#{cold_count}"
      result.fetch("full") << run(config, config.fetch("full"), "cold-#{index}")
      next if config["probe_only"]

      File.binwrite(path, edited)
      warn "#{config.fetch('project')} #{config.fetch('tool')} edited #{index + 1}/3"
      result.fetch("incremental") << run(config, config.fetch("incremental"), "edited-#{index}")
    end
    return result if config["probe_only"]

    %w[full incremental].each do |phase|
      result["#{phase}_median_seconds"] = result.fetch(phase).map { |run| run.fetch("seconds") }.sort.fetch(1)
    end
    result
  rescue StandardError => e
    failure = (result || config.slice("project", "tool")).merge("blocked" => "#{e.class}: #{e.message}")
    failure["partial"] = e.partial if e.is_a?(TimedOut)
    failure
  ensure
    File.binwrite(path, original) if path && original
  end
end

manifest, destination = ARGV
abort "Usage: ruby script/compare_benchmarks.rb MANIFEST.json OUTPUT.json" unless manifest && destination
results = []
JSON.parse(File.read(manifest)).each do |config|
  results << CompareBenchmarks.measure(config)
  File.write(destination, JSON.pretty_generate(results))
end
