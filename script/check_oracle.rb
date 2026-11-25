# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module Oracle
  ROOT = File.expand_path("..", __dir__)
  CORPUS = File.join(ROOT, "test/fixtures/oracle")
  REPORT = ".ripr/report"

  module_function

  def run(directory, *flags)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, File.join(ROOT, "exe/ripr"), "run", "--full", "--jobs", "1", "--framework", "minitest",
      "--operators", "comparison,arithmetic", "--reporter", "agent", "--reporter", "json", "--profile", *flags, chdir: directory
    )
    raise "ripr failed for #{File.basename(directory)} (exit #{status.exitstatus})\n#{stderr}" unless status.success?

    agent = JSON.parse(stdout)
    report = File.join(directory, REPORT)
    profile = JSON.parse(File.read(File.join(report, "profile.json")))
    raise "No baseline tests ran for #{File.basename(directory)}" unless profile.dig("baseline", "tests_run").positive?

    results = JSON.parse(File.binread(File.join(report, "mutation.json")))
    [agent, results.fetch("files"), profile.fetch("mutations").fetch("attempts"), stderr]
  end

  def observations(agent, files)
    gaps = agent.fetch("gaps").to_h { |gap| [gap.fetch("id"), gap.fetch("stage", gap.fetch("kind"))] }
    files.flat_map do |path, data|
      lines = data.fetch("source").lines
      data.fetch("mutants").map do |mutant|
        start, finish = mutant.fetch("location").values_at("start", "end")
        line = lines.fetch(start.fetch("line") - 1)
        original = line.byteslice(start.fetch("column") - 1, finish.fetch("column") - start.fetch("column"))
        id = mutant.fetch("id")
        { "key" => [path, original, mutant.fetch("replacement")], "id" => id, "status" => gaps.fetch(id, mutant.fetch("status").downcase) }
      end
    end
  end

  def check(directory)
    expectation = JSON.parse(File.read(File.join(directory, "expectations.json")))
    source = expectation.fetch("file")
    agent, files, attempts = run(directory)
    remaining = observations(agent, files)
    cases = expectation.fetch("cases").map do |example|
      key = [source, *example.values_at("original", "replacement")]
      index = remaining.index { |mutant| mutant.fetch("key") == key }
      actual = remaining.delete_at(index) if index
      example.merge("actual" => actual&.fetch("status"))
    end
    raise "No mutations ran for #{File.basename(directory)}" if attempts.empty?

    candidates = agent.fetch("gaps").filter_map do |gap|
      next unless gap.fetch("kind") == "not_infected"

      id = gap.fetch("id")
      if attempts.any? { |attempt| attempt.fetch("id") == id } || gap.fetch("covering_tests").empty?
        raise "Expected #{id} to be covered and skipped during the ordinary run"
      end

      gap.slice("id", "full_id", "original", "mutated").merge("project" => File.basename(directory))
    end
    [{ "project" => File.basename(directory), "cases" => cases, "unexpected" => remaining }, candidates]
  end

  def verify(directory, selected)
    ids = selected.map { |entry| entry.fetch("full_id") }
    agent, files, attempts, stderr = run(directory, "--verify-not-infected", "--only", ids.join(","))
    statuses = observations(agent, files).to_h { |result| result.values_at("id", "status") }
    tests = attempts.to_h { |attempt| attempt.values_at("id", "tests_run") }
    unexpected = (statuses.keys | tests.keys) - selected.map { |entry| entry.fetch("id") }
    raise "Verification ran unselected mutations #{unexpected.join(', ')}" unless unexpected.empty?

    selected.map do |entry|
      id = entry.fetch("id")
      status = statuses[id]
      count = tests[id]
      discrepancy = status != "not_infected" || !count || !count.positive?
      result = entry.merge("status" => status, "tests_run" => count, "discrepancy" => discrepancy)
      result["warnings"] = stderr.lines.grep(/verification discrepancy #{Regexp.escape(id)}:/).map(&:strip) if discrepancy
      result
    end
  end

  def check_corpus(seed)
    Dir.mktmpdir("ripr-oracle-") do |workspace|
      manifests = Dir.glob("#{CORPUS}/*/expectations.json")
      raise "No oracle projects found" if manifests.empty?

      cases, candidates = manifests.map do |manifest|
        project = File.dirname(manifest)
        FileUtils.cp_r(project, workspace)
        check(File.join(workspace, File.basename(project)))
      end.transpose
      eligible = candidates.flatten(1).sort_by { |entry| entry.values_at("project", "full_id") }
      raise "At least two covered and skipped mutations are required for sampling" if eligible.size < 2

      selected = eligible.sample(eligible.size / 2, random: Random.new(seed))
      samples = selected.group_by { |entry| entry.fetch("project") }.flat_map do |project, entries|
        verify(File.join(workspace, project), entries)
      end
      errors = samples.count { |entry| entry.fetch("discrepancy") }
      unexpected = cases.sum { |result| result.fetch("unexpected").size }
      mismatched = cases.sum { |result| result.fetch("cases").count { |example| example["status"] != example["actual"] } }
      { "seed" => seed, "oracle" => cases, "oracle_mismatches" => mismatched + unexpected,
        "verification" => { "eligible" => eligible.size, "selected" => samples.size, "samples" => samples,
                            "discrepancies" => errors, "error_rate" => errors.fdiv(samples.size) } }
    end
  end
end

abort "Usage: ruby script/check_oracle.rb [SEED]" if ARGV.length > 1

report = Oracle.check_corpus(Integer(ARGV.fetch(0, "0")))
puts JSON.pretty_generate(report)
exit(report.fetch("oracle_mismatches").zero? && report.dig("verification", "discrepancies").zero? ? 0 : 1)
