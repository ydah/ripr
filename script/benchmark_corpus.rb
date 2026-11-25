# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module BenchmarkCorpus
  ROOT = File.expand_path("..", __dir__)
  WORKLOADS = [
    { repository: "halostatue/diff-lcs", revision: "aca4bd72c80231e0646071ad533c65820a4ecc93",
      file: "lib/diff/lcs/change.rb", line: "      (action == other.action) and", framework: "rspec", tests: "spec/**/*_spec.rb" },
    { repository: "tzinfo/tzinfo", revision: "d5893c99bbcd842af86023f02a84fac1659b3031",
      file: "lib/tzinfo/timestamp.rb",
      line: "      raise RangeError, 'sub_second must be >= 0 and < 1' if sub_second < 0 || sub_second >= 1",
      framework: "minitest", tests: "test/tc_timestamp{,_with_offset}.rb" },
    { repository: "liufengyun/hashdiff", revision: "d6ac7e74ee5b362e067e27312ec7545c7845ce45",
      file: "lib/hashdiff/util.rb", line: "    (1 - diffs / (count_a + count_b).to_f) >= opts[:similarity]",
      framework: "rspec", tests: "spec/**/*_spec.rb" },
    { repository: "basecamp/fizzy", revision: "0ecbccecdd76fe8f1850da4c5233998dfd148ea6",
      file: "app/models/assignment.rb", line: "      if card.assignments.count >= LIMIT",
      framework: "minitest", tests: "test/models/{assignment,card,comment}_test.rb", rails: true }
  ].freeze

  module_function

  def prepare(workload, workspace, gemfile)
    repository = workload.fetch(:repository)
    project = File.basename(repository)
    directory = File.join(workspace, project)
    archive = "#{directory}.tar.gz"
    revision = workload.fetch(:revision)
    FileUtils.mkdir_p(directory)
    system("curl", "-fsSL", "--retry", "3", "-o", archive, "https://codeload.github.com/#{repository}/tar.gz/#{revision}", exception: true)
    system("tar", "-xzf", archive, "--strip-components=1", "-C", directory, exception: true)

    file = workload.fetch(:file)
    system("git", "init", "-q", chdir: directory, exception: true)
    system("git", "add", "--", file, chdir: directory, exception: true)
    system("git", "-c", "user.name=Ripr", "-c", "user.email=ripr@example.com", "commit", "-qm", revision, chdir: directory, exception: true)

    env = { "BUNDLE_GEMFILE" => gemfile }
    command = ["bundle", "exec", "ripr", "run", "--profile", "--reporter", "agent", "--jobs", "1", "--operators", "comparison",
               "--framework", workload.fetch(:framework), "--tests", workload.fetch(:tests)]
    if workload[:rails]
      app_gemfile = File.join(directory, "Gemfile")
      File.write(app_gemfile, "\ngem \"ripr\", path: #{ROOT.dump}, require: false\n", mode: "a")
      env.merge!("BUNDLE_GEMFILE" => app_gemfile, "RAILS_ENV" => "test", "DATABASE_ADAPTER" => "sqlite", "PARALLEL_WORKERS" => "1")
      system(env, "bundle", "install", "--jobs", "4", chdir: directory, exception: true)
      system(env, "bundle", "exec", "rails", "db:prepare", chdir: directory, exception: true)
      command << "--rails"
    end

    line = workload.fetch(:line)
    { "project" => project, "tool" => "ripr", "directory" => directory, "format" => "ripr", "file" => file,
      "before" => "#{line}\n", "after" => "#{line} # benchmark edit\n", "caches" => [".ripr"], "timeout_seconds" => 180,
      "profile" => ".ripr/report/profile.json", "exit_codes" => [0], "samples" => 5, "env" => env,
      "full" => command + ["--full", file], "incremental" => command + ["--since", "HEAD", file] }
  end

  def verify(result)
    raise "#{result.fetch('project')}: #{result.fetch('blocked')}" if result.key?("blocked")

    result.fetch("full").each do |run|
      profile = run.fetch("profile")
      raise "#{result.fetch('project')}: empty cold baseline" unless profile.fetch("baseline").fetch("tests_run").positive?
      raise "#{result.fetch('project')}: no comparison mutants exercised" unless profile.fetch("mutations").fetch("attempted").positive?
    end
    %w[full incremental].each do |phase|
      result.fetch(phase).each do |run|
        counts = run.fetch("summary").fetch("counts")
        unless run.fetch("summary").fetch("total").positive? && counts.fetch("error").zero? && counts.fetch("timeout").zero?
          raise "#{result.fetch('project')} #{phase}: #{counts.inspect}"
        end
      end
    end
  end

  def run(destination)
    FileUtils.mkdir_p(File.dirname(destination))
    Dir.mktmpdir("ripr-corpus-") do |workspace|
      gemfile = File.join(workspace, "Gemfile")
      File.write(gemfile, <<~GEMFILE)
        source "https://rubygems.org"
        gem "ripr", path: #{ROOT.dump}, require: false
        gem "rspec", "3.13.2", require: false
        gem "rspec-core", "3.13.7", require: false
        gem "rspec-expectations", "3.13.6", require: false
        gem "rspec-mocks", "3.13.9", require: false
        gem "rspec-support", "3.13.8", require: false
        gem "diff-lcs", "1.6.2", require: false
        gem "minitest", "6.0.6", require: false
        gem "concurrent-ruby", "1.3.8", require: false
      GEMFILE
      system({ "BUNDLE_GEMFILE" => gemfile }, "bundle", "install", chdir: workspace, exception: true)
      configs = WORKLOADS.map { |workload| prepare(workload, workspace, gemfile) }
      manifest = File.join(workspace, "manifest.json")
      comparison = File.join(workspace, "comparison.json")
      File.write(manifest, JSON.generate(configs))
      system(RbConfig.ruby, File.join(__dir__, "compare_benchmarks.rb"), manifest, comparison, exception: true)
      results = JSON.parse(File.read(comparison))
      results.zip(WORKLOADS, configs).each do |result, workload, config|
        verify(result)
        result.merge!(workload.slice(:repository, :revision, :tests))
        next if workload[:rails]

        warn "#{result.fetch('project')} disabled instrumentation overhead"
        output, error, status = Open3.capture3(
          config.fetch("env"), "bundle", "exec", "ruby", File.join(__dir__, "benchmark.rb"),
          workload.fetch(:framework), workload.fetch(:tests), chdir: config.fetch("directory")
        )
        raise "#{result.fetch('project')} disabled overhead: #{error}\n#{output}" unless status.success?

        result["instrumentation"] = JSON.parse(output)
      end
      commit, status = Open3.capture2("git", "rev-parse", "HEAD", chdir: ROOT)
      raise "Cannot identify the benchmarked ripr revision" unless status.success?

      File.write(destination, JSON.pretty_generate("commit" => commit.strip, "ruby" => RUBY_DESCRIPTION, "projects" => results))
    end
  end

  def sparkline(values)
    minimum, maximum = values.minmax
    bars = "▁▂▃▄▅▆▇█"
    values.map { |value| bars[maximum == minimum ? 3 : (7 * (value - minimum) / (maximum - minimum)).round] }.join
  end

  def trend(paths)
    history = paths.map { |path| JSON.parse(File.read(path)) }
    current = history.last
    puts "## Benchmark trend\n\n"
    puts "Runs from oldest to newest are #{history.map { |run| "`#{run.fetch('commit')[0, 7]}`" }.join(' → ')}.\n\n"
    puts "Each chart uses its own range. Cold and edited values are median wall seconds. Disabled overhead is a fraction.\n\n"
    puts "| Project | Metric | Recent runs | Range | Latest |", "| --- | --- | --- | ---: | ---: |"
    current.fetch("projects").each do |project|
      name = project.fetch("project")
      scope = project.values_at("project", "revision", "file", "tests")
      matching = history.map do |run|
        run.fetch("projects").find { |entry| entry.values_at("project", "revision", "file", "tests") == scope }
      end
      metrics = { "Cold" => ->(run) { run["full_median_seconds"] }, "Edited" => ->(run) { run["incremental_median_seconds"] },
                  "Disabled overhead" => ->(run) { run.dig("instrumentation", "disabled_overhead") } }
      metrics.each do |label, metric|
        values = matching.compact.filter_map(&metric)
        next if values.empty?

        range = values.minmax.map { |value| format("%.4f", value) }.join("–")
        puts "| #{name} | #{label} | #{sparkline(values)} | #{range} | #{format('%.4f', values.last)} |"
      end
    end
  end
end

command, *arguments = ARGV
case command
when "run"
  abort "Usage: ruby script/benchmark_corpus.rb run OUTPUT.json" unless arguments.size == 1

  BenchmarkCorpus.run(File.expand_path(arguments.first))
when "trend"
  abort "Usage: ruby script/benchmark_corpus.rb trend OLDEST.json ... NEWEST.json" if arguments.empty?

  BenchmarkCorpus.trend(arguments)
else
  abort "Usage: ruby script/benchmark_corpus.rb run OUTPUT.json | trend RESULTS.json ..."
end
