# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"
require "shellwords"
require_relative "core/classifier"
require_relative "core/input_suggestions"
require_relative "core/operators"
require_relative "reporters/html"
require_relative "reporters/triage"

module Ripr
  module Reporters
    ACTIONS = { "not_reached" => "add_test", "not_infected" => "add_input", "not_propagated" => "add_input",
                "not_revealed" => "strengthen_assertion", "not_detected" => "strengthen_assertion" }.freeze
    HINTS = {
      "not_reached" => "Add a test that executes this method and branch.",
      "not_infected" => "Add boundary inputs that change the mutated expression's value.",
      "not_propagated" => "Try inputs that change the observed method exit, or check whether the mutation is equivalent.",
      "not_revealed" => "Assert the changed return value or exception in the covering test.",
      "not_detected" => "Check the return value and side effects for a missed assertion. Accept only if the mutation is equivalent."
    }.freeze
    LOAD_NOTE = "Reached outside a tracked test, possibly during loading or in a background thread. " \
                "Switching cannot change effects already computed before test execution."
    STATIC_NOTE = "This mutation is active before the source loads in a fresh process."
    MTE_STATUSES = { "killed" => "Killed", "timeout" => "Timeout", "error" => "RuntimeError", "not_reached" => "NoCoverage",
                     "not_infected" => "Survived", "not_detected" => "Survived", "not_propagated" => "Survived",
                     "not_revealed" => "Survived", "accepted" => "Ignored",
                     "static" => "Ignored", "invalid" => "CompileError", "planned" => "Pending" }.freeze

    def self.agent(results, run, summary = Core::Classifier.summary(results), config: nil, triage: nil)
      gaps = (triage ? triage.gaps : results).filter_map do |mutant|
        status = mutant.fetch("status")
        diagnosed = Core::Classifier::PROPAGATION.include?(status)
        kind = diagnosed && !triage ? "not_detected" : status
        next unless ACTIONS.key?(kind)

        id = mutant.fetch("id")
        hint = HINTS.fetch(status)
        observed = mutant.fetch("observed", [])
        hint += " Observed operands: #{JSON.generate(observed)}." if status == "not_infected" && !observed.empty?
        suggestion = Core::InputSuggestions.for(mutant)
        hint += " #{suggestion_message(suggestion)}" if suggestion
        hint += " #{load_note(mutant)}" if mutant["load_reached"]
        flags = ""
        flags += " --rails" if config && config[:rails]
        flags += " --boot #{Shellwords.escape(config[:boot])}" if config && config[:boot]
        flags += " --static" if mutant["static"]
        operator = mutant.fetch("operator")
        flags += " --operators #{operator}" if Core::Operators::EXTRA_NAMES.include?(operator)
        gap = mutant.slice("id", "full_id", "location", "subject", "operator", "original", "mutated", "observed", "covering_tests",
                           "load_reached")
                    .merge("action" => ACTIONS.fetch(kind), "hint" => hint,
                           "rerun" => "ripr --only #{id}#{flags}", "accept" => "ripr accept #{id}#{flags} --reason \"...\"")
        if triage
          gap["stage"] = status
          gap["priority"] = triage.priorities.fetch(mutant.fetch("full_id"))
        else
          gap["kind"] = kind
          gap["stage"] = status if diagnosed
        end
        gap["propagation"] = mutant.fetch("propagation") if mutant.key?("propagation")
        gap["suggested_inputs"] = suggestion.fetch(:inputs) if suggestion
        gap
      end
      if triage
        return { "schema" => "ripr.agent/v2", "run" => run, "summary" => summary, "gaps" => gaps,
                 "methods" => triage.method_cards, "weak_tests" => triage.weak_tests }
      end

      diagnosed = Core::Classifier::PROPAGATION.sum { |status| summary.fetch(status, 0) }
      legacy = summary.except(*Core::Classifier::PROPAGATION).merge("not_detected" => summary.fetch("not_detected") + diagnosed)
      { "schema" => "ripr.agent/v1", "run" => run, "summary" => legacy, "gaps" => gaps }
    end

    def self.mte(results, sources, thresholds)
      files = sources.to_h do |path, source|
        mutants = results.select { |m| m.fetch("location").fetch("file") == path }.map do |mutant|
          location = mutant.fetch("location")
          reason = mutant["accepted"] || mutant["invalid_reason"] || mutant["error"] || mutant.fetch("status")
          suggestion = Core::InputSuggestions.for(mutant)
          reason += ". #{suggestion_message(suggestion)}" if suggestion
          reason += ". #{propagation_message(mutant)}" if mutant["propagation"]
          reason += ". #{load_note(mutant)}" if mutant["load_reached"]
          { "id" => mutant.fetch("id"), "mutatorName" => mutant.fetch("operator"), "replacement" => mutant.fetch("mutated"),
            "status" => MTE_STATUSES.fetch(mutant.fetch("status")), "statusReason" => reason,
            "location" => { "start" => { "line" => location.fetch("line"), "column" => location.fetch("column") },
                            "end" => { "line" => location.fetch("end_line"), "column" => location.fetch("end_column") } } }
        end
        [path, { "language" => "ruby", "source" => source, "mutants" => mutants }]
      end
      { "schemaVersion" => "2", "thresholds" => thresholds.slice("high", "low"), "files" => files }
    end

    def self.write(results, runner, config, stdout: $stdout)
      summary = Core::Classifier.summary(results)
      summary["static"] += runner.static
      run = { "since" => config[:since], "scope" => config[:scope], "framework" => runner.framework, "metrics" => runner.metrics }
      reporters = config[:reporters]
      if reporters.include?("agent-v2") || (reporters.include?("text") && !config[:dry_run])
        triage = Triage.build(results, changed: runner.changed_source_lines, public_subjects: runner.public_subjects)
      end
      reporters.each do |name|
        case name
        when "text"
          write_text(stdout, results, summary, runner.metrics, triage, dry_run: config[:dry_run])
        when "agent"
          stdout.puts JSON.generate(agent(results, run, summary, config: config))
        when "agent-v2"
          stdout.puts JSON.generate(agent(results, run, summary, config: config, triage: triage))
        when "github"
          results.each do |mutant|
            next unless HINTS.key?(mutant["status"])

            location = mutant.fetch("location")
            path = location.fetch("file")
            if ENV["GITHUB_WORKSPACE"]
              path = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(ENV.fetch("GITHUB_WORKSPACE"))).to_s
            end
            file = annotation(path, property: true)
            message = "#{mutant['original']} → #{mutant['mutated']}"
            message += ". #{load_note(mutant)}" if mutant["load_reached"]
            message = annotation(message)
            stdout.puts "::warning file=#{file},line=#{location['line']},col=#{location['column']}," \
                        "title=ripr #{mutant['status']}::#{message}"
          end
        when "json", "html"
          FileUtils.mkdir_p(config[:report_dir])
          report = mte(results, runner.sources, config[:thresholds])
          File.write(File.join(config[:report_dir], "mutation.json"), "#{JSON.pretty_generate(report)}\n", encoding: "UTF-8")
          if name == "html"
            stages = results.to_h { |mutant| mutant.values_at("id", "status") }
            HTML.write(report, config[:report_dir], stages: stages)
          end
        end
      end
      summary
    end

    def self.write_text(stdout, results, summary, metrics, triage, dry_run:)
      stdout.puts "Killed #{summary['killed']} · Survived #{summary['survived']} " \
                  "(#{summary['not_infected']} not infected) · Score #{summary['score']}%"
      stdout.puts "Reused #{metrics['reused']} · Baseline #{metrics['baseline_tests_run']} tests · " \
                  "#{summary['static']} static variants excluded"
      return results.each { |mutant| write_gap(stdout, mutant) } if dry_run

      groups = triage.gaps.group_by { |mutant| [mutant.fetch("location").fetch("file"), mutant.fetch("subject")] }
      triage.method_cards.each do |method|
        file, subject = method.values_at("file", "subject")
        entries = groups.fetch([file, subject])
        stages = method.fetch("stages").map { |stage, count| "#{count} #{stage.tr('_', ' ')}" }.join(" · ")
        stdout.puts "#{subject} (#{file}) · #{stages} · Start with #{entries.first.fetch('id')}"
        entries.each { |mutant| write_gap(stdout, mutant) }
      end
      return if triage.weak_tests.empty?

      stdout.puts "Tests that reach mutations without a recorded kill"
      triage.weak_tests.each { |test| stdout.puts "  #{test.fetch('id')} (#{test.fetch('reached')} reached)" }
    end

    def self.write_gap(stdout, mutant)
      location = mutant.fetch("location")
      stdout.puts "#{mutant['status'].tr('_', ' ')} #{location['file']}:#{location['line']}:#{location['column']} " \
                  "#{mutant['original'].inspect} → #{mutant['mutated'].inspect} id=#{mutant['id']}"
      stdout.puts "  observed: #{JSON.generate(mutant['observed'])}" unless mutant.fetch("observed", []).empty?
      stdout.puts "  #{propagation_message(mutant)}" if mutant["propagation"]
      if (suggestion = Core::InputSuggestions.for(mutant))
        stdout.puts "  suggested inputs: #{JSON.generate(suggestion.fetch(:inputs))}"
        stdout.puts "  #{suggestion[:reason]}" if suggestion[:reason]
      end
      stdout.puts "  #{load_note(mutant)}" if mutant["load_reached"]
    end

    def self.annotation(value, property: false)
      escaped = value.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
      property ? escaped.gsub(":", "%3A").gsub(",", "%2C") : escaped
    end

    def self.load_note(mutant)
      mutant["static"] ? STATIC_NOTE : LOAD_NOTE
    end

    def self.suggestion_message(suggestion)
      ["Try operand pairs #{JSON.generate(suggestion.fetch(:inputs))}.", suggestion[:reason]].compact.join(" ")
    end

    def self.propagation_message(mutant)
      proof = mutant.fetch("propagation")
      test = mutant.fetch("covering_tests").find { |entry| entry["id"] == proof.fetch("test_id") }
      location = test ? "#{test.fetch('file')}:#{test.fetch('line')}" : proof.fetch("test_id")
      "#{mutant.fetch('subject')} #{describe_exit(proof.fetch('original'))} → " \
        "#{describe_exit(proof.fetch('mutant'))} in #{location} (call #{proof.fetch('call')})."
    end

    def self.describe_exit(exit)
      kind, value = exit
      case kind
      when "return"
        value = value[1] if value.is_a?(Array) && %w[TrueClass FalseClass NilClass Integer].include?(value.first)
        "returned #{JSON.generate(value)}"
      when "raise" then "raised #{value}"
      when "not_called" then "was not called"
      else "had an unknown exit"
      end
    end

    private_class_method :suggestion_message, :propagation_message, :describe_exit, :write_text, :write_gap

    def self.html(report)
      HTML.render(report)
    end
  end
end
