# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"

module CompareVerdicts
  ROOT = File.expand_path("..", __dir__)
  VERSION = "1.8.2"
  OPERATORS = %w[comparison arithmetic].freeze
  VERDICTS = %w[killed survived].freeze

  module_function

  def edit(file, offset, original, replacement)
    common = [original.bytesize, replacement.bytesize].min
    prefix = 0
    prefix += 1 while prefix < common && original.getbyte(prefix) == replacement.getbyte(prefix)
    suffix = 0
    suffix += 1 while suffix < common - prefix && original.getbyte(-suffix - 1) == replacement.getbyte(-suffix - 1)
    [file, offset + prefix, original.byteslice(prefix, original.bytesize - prefix - suffix),
     replacement.byteslice(prefix, replacement.bytesize - prefix - suffix)]
  end

  def capture(directory, *, rails: false)
    env = { "SEED" => "0" }
    if rails
      env.merge!("BUNDLE_GEMFILE" => File.join(directory, "Gemfile"), "RAILS_ENV" => "test",
                 "DATABASE_ADAPTER" => "sqlite", "PARALLEL_WORKERS" => "1")
    end
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, *, chdir: directory)
    raise "Command failed in #{File.basename(directory)} (exit #{status.exitstatus})\n#{stderr}\n#{stdout}" unless status.success?

    stdout
  end

  def ripr(directory, source, tests, framework, operators:, rails:)
    flags = tests.flat_map { |test| ["--tests", test] }
    flags << "--rails" if rails
    capture(directory, File.join(ROOT, "exe/ripr"), "run", "--full", "--verify-not-infected", "--jobs", "1", "--seed", "0",
            "--framework", framework, "--operators", operators.join(","), "--profile", "--reporter", "json", *flags, source, rails: rails)
    report = JSON.parse(File.read(File.join(directory, ".ripr/report/mutation.json")))
    profile = JSON.parse(File.read(File.join(directory, ".ripr/report/profile.json")))
    raise "No ripr baseline tests ran" unless profile.dig("baseline", "tests_run").positive?

    attempts = profile.dig("mutations", "attempts").to_h { |attempt| attempt.values_at("id", "tests_run") }
    report.fetch("files").flat_map do |file, data|
      contents = data.fetch("source")
      data.fetch("mutants").map do |mutant|
        offsets = mutant.fetch("location").values_at("start", "end").map do |point|
          contents.lines.first(point.fetch("line") - 1).sum(&:bytesize) + point.fetch("column") - 1
        end
        id = mutant.fetch("id")
        status = mutant.fetch("status")
        { "file" => file, "offset" => offsets.first, "original" => contents.byteslice(offsets.first...offsets.last),
          "replacement" => mutant.fetch("replacement"), "status" => status == "NoCoverage" ? "no_coverage" : status.downcase,
          "id" => id, "tests_run" => attempts.fetch(id, 0), "details" => mutant.fetch("statusReason") }
      end
    end
  end

  def mutineer(directory, source, tests, framework, package, operators:, rails:, boot:, strategy:)
    # Use the CLI's runner to obtain each executed variant's byte span alongside its verdict.
    code = <<~'RUBY'
      require "json"
      require "mutineer"
      version, source, framework, operators, boot, strategy, rails_flag, *tests = ARGV
      abort "Expected Mutineer #{version}, got #{Mutineer::VERSION}" unless Mutineer::VERSION == version
      rails = rails_flag == "true"
      $LOAD_PATH.unshift(File.expand_path("lib"))
      config = Mutineer::Config.new(sources: [source], tests: tests, framework: framework, operators: operators.split(","),
                                    rails: rails, boot: boot.empty? ? nil : boot, strategy: strategy,
                                    jobs: 1, matrix: true)
      result, sources = Mutineer::Runner.execute(config)
      puts JSON.generate(result.results.map do |entry|
        mutation = entry.mutation
        file = entry.subject.file
        original = sources.fetch(file).byteslice(mutation.start_offset...mutation.end_offset)
        { "file" => file, "offset" => mutation.start_offset, "original" => original, "replacement" => mutation.replacement,
          "status" => entry.status.to_s, "id" => entry.id, "tests_run" => entry.kills&.ran&.size || 0,
          "killed_by" => entry.kills&.killed_by || [], "details" => entry.details }
      end)
    RUBY
    stdout = capture(directory, "-I", File.join(package, "lib"), "-e", code, VERSION, source, framework, operators.join(","),
                     boot.to_s, strategy, rails.to_s, *tests, rails: rails)
    JSON.parse(stdout)
  end

  def pair(ripr, mutineer)
    left, right = [ripr, mutineer].map do |mutants|
      mutants.group_by { |mutant| edit(*mutant.values_at("file", "offset", "original", "replacement")) }
    end
    (left.keys | right.keys).map do |key|
      ripr_rows = left.fetch(key, [])
      mutineer_rows = right.fetch(key, [])
      verdict = if ripr_rows.empty? then "mutineer_only"
                elsif mutineer_rows.empty? then "ripr_only"
                elsif ripr_rows.size > 1 || mutineer_rows.size > 1 then "ambiguous_edit"
                else outcome(ripr_rows.first, mutineer_rows.first)
                end
      { "edit" => key, "ripr" => ripr_rows, "mutineer" => mutineer_rows, "comparison" => verdict }
    end
  end

  def outcome(left, right)
    statuses = [left.fetch("status"), right.fetch("status")]
    return "unreached_by_both" if statuses == %w[no_coverage no_coverage]

    both_ran = [left, right].all? { |row| VERDICTS.include?(row.fetch("status")) && row.fetch("tests_run").to_i.positive? }
    return "missing_verdict" unless both_ran

    left.fetch("status") == right.fetch("status") ? "agreed" : "disagreed"
  end

  def run(project, source, framework, patterns, package, operators: OPERATORS, rails: false, mutineer_boot: nil, mutineer_strategy: nil)
    Dir.mktmpdir("ripr-verdicts-") do |directory|
      ripr_dir, mutineer_dir = %w[ripr mutineer].map do |tool|
        checkout = File.join(directory, tool)
        FileUtils.cp_r(project, checkout)
        checkout
      end
      tests = Dir.glob(patterns, base: project).uniq
      raise "No tests match for #{project}" if tests.empty?

      left = ripr(ripr_dir, source, tests, framework, operators: operators, rails: rails)
      boot = mutineer_boot || (rails ? "config/environment.rb" : nil)
      strategy = mutineer_strategy || (rails ? "redefine" : "reload")
      right = mutineer(mutineer_dir, source, tests, framework, package, operators: operators, rails: rails, boot: boot, strategy: strategy)
      rows = pair(left, right)
      counts = rows.map { |row| row.fetch("comparison") }.tally
      identity_matches = rows.count { |row| row.values_at("ripr", "mutineer").all? { |side| side.size == 1 } }
      source_digest = Digest::SHA256.file(File.join(project, source)).hexdigest
      { "project" => File.basename(project), "source" => source, "source_sha256" => source_digest, "tests" => tests,
        "framework" => framework, "operators" => operators, "rails" => rails, "mutineer_boot" => boot, "mutineer_strategy" => strategy,
        "ripr_variants" => left.size, "mutineer_variants" => right.size, "identity_matches" => identity_matches,
        "compared_verdicts" => counts.fetch("agreed", 0) + counts.fetch("disagreed", 0), "counts" => counts, "mutants" => rows }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |cli|
    cli.banner = "Usage: bundle exec ruby script/compare_verdicts.rb [OPTIONS] MUTINEER_DIRECTORY [PROJECT SOURCE FRAMEWORK TEST ...]"
    cli.on("--operators LIST", Array) { |operators| options[:operators] = operators }
    cli.on("--rails", "Compare a prepared SQLite Rails test project") { options[:rails] = true }
    cli.on("--mutineer-boot FILE", "Load a project dependency before running Mutineer") { |file| options[:mutineer_boot] = file }
    cli.on("--mutineer-strategy NAME", %w[reload redefine]) { |strategy| options[:mutineer_strategy] = strategy }
  end
  parser.parse!(ARGV)
  package, project, source, framework, *tests = ARGV
  valid_project = %w[minitest rspec].include?(framework) && !tests.empty?
  abort parser.to_s unless package && (ARGV.length == 1 || valid_project)

  package = File.expand_path(package)
  abort "Mutineer library is missing under #{package}" unless File.file?(File.join(package, "lib/mutineer.rb"))

  scopes = if project
             [[File.expand_path(project), source, framework, tests]]
           else
             Dir.glob(File.join(CompareVerdicts::ROOT, "test/fixtures/oracle/*/expectations.json")).map do |manifest|
               [File.dirname(manifest), JSON.parse(File.read(manifest)).fetch("file"), "minitest", ["test/**/*_test.rb"]]
             end
           end
  results = scopes.map { |scope| CompareVerdicts.run(*scope, package, **options) }
  puts JSON.pretty_generate("ruby" => RUBY_DESCRIPTION, "mutineer_version" => CompareVerdicts::VERSION, "projects" => results)
  success = results.any? && results.all? do |result|
    result.fetch("compared_verdicts").positive? && result.fetch("counts").fetch("disagreed", 0).zero?
  end
  exit(success ? 0 : 1)
end
