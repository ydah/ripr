# frozen_string_literal: true

module Ripr
  module Core
    module Classifier
      PROPAGATION = %w[not_propagated not_revealed].freeze
      SURVIVORS = (%w[not_reached not_infected not_detected] + PROPAGATION).freeze
      STATUSES = (%w[killed timeout error] + SURVIVORS + %w[accepted static invalid]).freeze

      def self.summary(results)
        counts = STATUSES.to_h { |status| [status, results.count { |result| result["status"] == status }] }
        counts["survived"] = SURVIVORS.sum { |status| counts.fetch(status) }
        detected = counts.fetch("killed") + counts.fetch("timeout")
        total = detected + counts.fetch("survived") + counts.fetch("error")
        counts.merge("score" => total.zero? ? 100.0 : (detected * 100.0 / total).round(1))
      end
    end
  end
end
