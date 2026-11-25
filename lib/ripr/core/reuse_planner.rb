# frozen_string_literal: true

require_relative "classifier"

module Ripr
  module Core
    module ReusePlanner
      REUSABLE_STATUSES = (%w[killed timeout] + Classifier::SURVIVORS).freeze

      def self.reusable?(record, mutant, env_hash:, test_hashes:, newly_reached: [])
        return false unless record.is_a?(Hash) && REUSABLE_STATUSES.include?(record["status"])
        return false unless mutant["full_id"] && record["full_id"] == mutant["full_id"]
        return false unless mutant["method_hash"] && record["method_hash"] == mutant["method_hash"]
        return false unless env_hash && record["env_hash"] == env_hash
        return false unless record["tests"].is_a?(Hash)
        return false if [mutant["id"], mutant["full_id"], mutant["site"]].compact.any? { |id| newly_reached.include?(id) }

        record["tests"].all? { |file, hash| hash && test_hashes[file] == hash }
      end
    end
  end
end
