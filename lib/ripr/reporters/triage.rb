# frozen_string_literal: true

require_relative "../core/classifier"

module Ripr
  module Reporters
    Triage = Data.define(:gaps, :priorities, :method_cards, :weak_tests) do
      def self.build(results, changed:, public_subjects:)
        gaps = results.select { |mutant| Core::Classifier::SURVIVORS.include?(mutant.fetch("status")) }
        priorities = gaps.to_h do |mutant|
          location = mutant.fetch("location")
          lines = location.fetch("line")..location.fetch("end_line")
          edited = changed.fetch(location.fetch("file"), []).any? { |line| lines.cover?(line) }
          public_method = public_subjects.key?(mutant.fetch("subject"))
          priority = [edited, mutant.fetch("covering_tests", []).empty?, mutant["status"] == "not_revealed", public_method].count(true)
          [mutant.fetch("full_id"), priority]
        end
        gaps.sort_by! do |mutant|
          location = mutant.fetch("location")
          [-priorities.fetch(mutant.fetch("full_id")), location.fetch("file"), location.fetch("line"), mutant.fetch("full_id")]
        end
        groups = gaps.group_by { |mutant| [mutant.fetch("location").fetch("file"), mutant.fetch("subject")] }
        methods = groups.map do |(file, subject), entries|
          { "file" => file, "subject" => subject, "stages" => entries.map { |entry| entry.fetch("status") }.tally,
            "first_gap" => entries.first.fetch("full_id") }
        end
        new(gaps: gaps, priorities: priorities, method_cards: methods, weak_tests: tests_without_kills(results))
      end

      def self.tests_without_kills(results)
        killed_by = results.filter_map { |mutant| [mutant["killed_by"], true] if mutant["status"] == "killed" }.to_h
        reach = {}
        results.each do |mutant|
          next if %w[accepted invalid static planned].include?(mutant.fetch("status"))

          mutant.fetch("covering_tests", []).each do |test|
            id = test.fetch("id")
            next if killed_by.include?(id)

            entry = (reach[id] ||= test.slice("id", "file", "line").merge("reached" => 0))
            entry["reached"] += 1
          end
        end
        reach.values.sort_by { |entry| [-entry.fetch("reached"), entry.fetch("id")] }
      end
      private_class_method :tests_without_kills
    end
  end
end
