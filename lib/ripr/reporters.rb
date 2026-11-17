# frozen_string_literal: true

require "json"
require "cgi"
require "fileutils"
require "pathname"
require_relative "core/classifier"

module Ripr
  module Reporters
    ACTIONS = { "not_reached" => "add_test", "not_infected" => "add_input", "not_detected" => "strengthen_assertion" }.freeze
    HINTS = {
      "not_reached" => "Add a test that executes this method and branch.",
      "not_infected" => "Add boundary inputs that change the mutated expression's value.",
      "not_detected" => "Assert the changed return value or side effect. Accept only if the mutation is equivalent."
    }.freeze
    LOAD_NOTE = "Reached outside a tracked test, possibly during loading or in a background thread. " \
                "Switching cannot change effects already computed before test execution."
    MTE_STATUSES = { "killed" => "Killed", "timeout" => "Timeout", "error" => "RuntimeError", "not_reached" => "NoCoverage",
                     "not_infected" => "Survived", "not_detected" => "Survived", "accepted" => "Ignored",
                     "static" => "Ignored", "invalid" => "CompileError", "planned" => "Pending" }.freeze

    def self.agent(results, run, summary = Core::Classifier.summary(results))
      gaps = results.filter_map do |mutant|
        status = mutant.fetch("status")
        next unless ACTIONS.key?(status)

        id = mutant.fetch("id")
        hint = HINTS.fetch(status)
        observed = mutant.fetch("observed", [])
        hint += " Observed operands: #{JSON.generate(observed)}." if status == "not_infected" && !observed.empty?
        hint += " #{LOAD_NOTE}" if mutant["load_reached"]
        mutant.slice("id", "full_id", "location", "subject", "operator", "original", "mutated", "observed", "covering_tests",
                     "load_reached")
              .merge("kind" => status, "action" => ACTIONS.fetch(status), "hint" => hint,
                     "rerun" => "ripr --only #{id}", "accept" => "ripr accept #{id} --reason \"...\"")
      end
      { "schema" => "ripr.agent/v1", "run" => run, "summary" => summary, "gaps" => gaps }
    end

    def self.mte(results, sources, thresholds)
      files = sources.to_h do |path, source|
        mutants = results.select { |m| m.fetch("location").fetch("file") == path }.map do |mutant|
          location = mutant.fetch("location")
          reason = mutant["accepted"] || mutant.fetch("status")
          reason += ". #{LOAD_NOTE}" if mutant["load_reached"]
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
      config[:reporters].each do |name|
        case name
        when "text"
          stdout.puts "Killed #{summary['killed']} · Survived #{summary['survived']} " \
                      "(#{summary['not_infected']} not infected) · Score #{summary['score']}%"
          stdout.puts "Reused #{runner.metrics['reused']} · Baseline #{runner.metrics['baseline_tests_run']} tests · " \
                      "#{summary['static']} static variants excluded"
          results.each do |mutant|
            next unless ACTIONS.key?(mutant["status"]) || config[:dry_run]

            location = mutant.fetch("location")
            stdout.puts "#{mutant['status'].tr('_', ' ')} #{location['file']}:#{location['line']}:#{location['column']} " \
                        "#{mutant['original'].inspect} → #{mutant['mutated'].inspect} id=#{mutant['id']}"
            stdout.puts "  observed: #{JSON.generate(mutant['observed'])}" unless mutant.fetch("observed", []).empty?
            stdout.puts "  #{LOAD_NOTE}" if mutant["load_reached"]
          end
        when "agent"
          stdout.puts JSON.generate(agent(results, run, summary))
        when "github"
          results.each do |mutant|
            next unless ACTIONS.key?(mutant["status"])

            location = mutant.fetch("location")
            path = location.fetch("file")
            if ENV["GITHUB_WORKSPACE"]
              path = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(ENV.fetch("GITHUB_WORKSPACE"))).to_s
            end
            file = annotation(path, property: true)
            message = "#{mutant['original']} → #{mutant['mutated']}"
            message += ". #{LOAD_NOTE}" if mutant["load_reached"]
            message = annotation(message)
            stdout.puts "::warning file=#{file},line=#{location['line']},col=#{location['column']}," \
                        "title=ripr #{mutant['status']}::#{message}"
          end
        when "json", "html"
          FileUtils.mkdir_p(config[:report_dir])
          report = mte(results, runner.sources, config[:thresholds])
          File.write(File.join(config[:report_dir], "mutation.json"), "#{JSON.pretty_generate(report)}\n")
          File.write(File.join(config[:report_dir], "index.html"), html(report)) if name == "html"
        end
      end
      summary
    end

    def self.annotation(value, property: false)
      escaped = value.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
      property ? escaped.gsub(":", "%3A").gsub(",", "%2C") : escaped
    end

    def self.html(report)
      data = JSON.generate(report).gsub("<") { "\\u003c" }
      rows = report.fetch("files").flat_map do |path, file|
        file.fetch("mutants").map do |mutant|
          values = [path, mutant.fetch("location").fetch("start").fetch("line"), mutant["mutatorName"],
                    mutant["statusReason"], mutant["replacement"]]
          "<tr>#{values.map { |v| "<td>#{CGI.escapeHTML(v.to_s)}</td>" }.join}</tr>"
        end
      end.join
      <<~HTML
        <!doctype html>
        <html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>ripr mutation report</title>
        <style>body{font:16px system-ui;margin:2rem;color:#20252b}table{border-collapse:collapse;width:100%}th,td{padding:.6rem;text-align:left;border-bottom:1px solid #ccc}td:last-child{white-space:pre-wrap;font-family:monospace}caption{font-size:1.5rem;text-align:left;margin-bottom:1rem}</style>
        <mutation-test-report-app id="interactive-report" hidden></mutation-test-report-app>
        <table id="fallback-report"><caption>ripr mutation report</caption><thead><tr><th>File</th><th>Line</th><th>Operator</th><th>Status</th><th>Replacement</th></tr></thead><tbody>#{rows}</tbody></table>
        <script type="application/json" id="mutation-report">#{data}</script>
        <script src="https://cdn.jsdelivr.net/npm/mutation-testing-elements@3.9.0/dist/mutation-test-elements.js" integrity="sha384-/dXYuoYRvO6rJ0FNtdKR+Hmq5iGrkkSDpc/TGgbSoReog26ZqhLhpSt4l+0Wwew2" crossorigin="anonymous" async></script>
        <script>
          customElements.whenDefined('mutation-test-report-app').then(() => {
            const app = document.getElementById('interactive-report');
            app.report = JSON.parse(document.getElementById('mutation-report').textContent);
            app.hidden = false;
            document.getElementById('fallback-report').hidden = true;
          });
        </script></html>
      HTML
    end
  end
end
