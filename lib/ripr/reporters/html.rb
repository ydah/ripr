# frozen_string_literal: true

require "cgi"
require "fileutils"
require "json"

module Ripr
  module Reporters
    module HTML
      VIEWER_VERSION = "3.9.0"
      VIEWER = File.join(__dir__, "assets", "mutation-testing-elements-#{VIEWER_VERSION}").freeze
      STAGES = %w[not_reached not_infected not_propagated not_revealed not_detected killed timeout error
                  accepted invalid static planned].freeze

      def self.write(report, directory, stages: {})
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, "index.html"), render(report, stages: stages), encoding: "UTF-8")
      end

      def self.render(report, stages: {})
        mutants = report.fetch("files").flat_map do |path, file|
          file.fetch("mutants").map { |mutant| [path, mutant, stages.fetch(mutant.fetch("id"), mutant.fetch("status"))] }
        end
        visible_stages = mutants.map(&:last).uniq
        options = ((STAGES & visible_stages) + (visible_stages - STAGES)).map do |stage|
          "<option value=\"#{escape(stage)}\">#{escape(label(stage))}</option>"
        end.join
        rows = mutants.map { |path, mutant, stage| row(path, mutant, stage) }.join
        script = File.read("#{VIEWER}.js", encoding: "UTF-8")
        licenses = %w[LICENSE NOTICES].map { |suffix| File.read("#{VIEWER}.#{suffix}", encoding: "UTF-8") }.join("\n")
        <<~HTML
          <!doctype html>
          <html lang="en">
          <meta charset="utf-8"><meta name="viewport" content="width=device-width">
          <meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:">
          <title>ripr mutation report</title>
          <style>
            :root{color-scheme:light dark}
            body{font:16px system-ui;margin:2rem}
            [hidden]{display:none!important}
            table{border-collapse:collapse;width:100%}
            th,td{padding:.6rem;text-align:left;border-bottom:1px solid #8888;vertical-align:top}
            td:last-child{white-space:pre-wrap;overflow-wrap:anywhere;font-family:monospace}
            caption{font-size:1.5rem;text-align:left;margin-bottom:1rem}
            label{display:block;margin-bottom:1rem}
          </style>
          <label id="stage-control" hidden>RIPR stage <select id="ripr-stage"><option value="">All stages</option>#{options}</select></label>
          <mutation-test-report-app id="interactive-report" hidden></mutation-test-report-app>
          <table id="fallback-report"><caption>ripr mutation report</caption>
            <thead><tr><th>File</th><th>Line</th><th>Operator</th><th>Stage</th><th>Reason</th><th>Replacement</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
          <script type="application/json" id="mutation-report">#{json(report)}</script>
          <script type="application/json" id="mutation-stages">#{json(stages)}</script>
          <script type="text/plain" id="viewer-license">#{licenses}</script>
          <script data-viewer-version="#{VIEWER_VERSION}">
          #{script}
          </script>
          <script>
            const report = JSON.parse(document.getElementById('mutation-report').textContent);
            const stages = JSON.parse(document.getElementById('mutation-stages').textContent);
            const app = document.getElementById('interactive-report');
            const fallback = document.getElementById('fallback-report');
            const select = document.getElementById('ripr-stage');
            const stageOf = mutant => Object.hasOwn(stages, mutant.id) ? stages[mutant.id] : mutant.status;

            async function showStage() {
              const stage = select.value;
              for (const row of fallback.tBodies[0].rows) {
                row.hidden = Boolean(stage && stage !== row.dataset.stage);
              }
              if (!window.customElements?.get(app.localName)) return;

              try {
                const files = stage ? Object.fromEntries(Object.entries(report.files).flatMap(([path, file]) => {
                  const mutants = file.mutants.filter(mutant => stageOf(mutant) === stage);
                  return mutants.length ? [[path, { ...file, mutants }]] : [];
                })) : report.files;
                app.report = { ...report, files };
                await app.updateComplete;
                app.hidden = false;
                fallback.hidden = true;
              } catch {
                app.hidden = true;
                fallback.hidden = false;
              }
            }

            document.getElementById('stage-control').hidden = select.options.length <= 1;
            select.addEventListener('change', () => {
              if (location.hash) location.hash = '';
              showStage();
            });
            showStage();
          </script>
          </html>
        HTML
      end

      def self.json(value)
        JSON.generate(value).gsub("<") { "\\u003c" }
      end

      def self.label(stage)
        stage.tr("_", " ").sub(/\A./, &:upcase)
      end

      def self.escape(value)
        CGI.escapeHTML(value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace))
      end

      def self.row(path, mutant, stage)
        location = mutant.fetch("location").fetch("start")
        values = [path, location.fetch("line"), mutant.fetch("mutatorName"), label(stage), mutant["statusReason"], mutant["replacement"]]
        cells = values.map { |value| "<td>#{escape(value)}</td>" }.join
        "<tr data-stage=\"#{escape(stage)}\">#{cells}</tr>"
      end

      private_class_method :json, :label, :escape, :row
    end
  end
end
