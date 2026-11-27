# frozen_string_literal: true

require "prism"
require_relative "../runtime"
require_relative "operators"

module Ripr
  module Core
    module InputSuggestions
      BOUNDARY = %w[>= > <= <].freeze
      TO_FLOAT = Integer.instance_method(:to_f)
      TO_INTEGER = Float.instance_method(:to_i)

      def self.for(mutant)
        return unless mutant["status"] == "not_infected"

        original, replacement, operator = mutant.values_at("original_operator", "replacement", "operator")
        definition = Operators::REGISTRY[operator]
        infection = definition&.infection_condition
        return unless infection && original && replacement && definition.variants[original.to_sym] == replacement

        observed = mutant.fetch("observed", [])
        fixed_operands = mutant.fetch("fixed_operands", [])
        samples = observed.select { |pair| pair.all? { |value| Operators.native_operand?(value, original) } }
        right_step = 1
        if %w[+ -].include?(original) && !samples.empty? && samples.all? { |pair| pair.all? { |value| Value::CLASS_OF.bind_call(value) == Integer } }
          right_step = right_multiplier(mutant["original"], original) || 1
          return if Value::INTEGER_EQ.bind_call(right_step, 0)
        end
        inputs = samples.filter_map do |sample|
          candidates(*sample, original, right_step).find do |pair|
            fixed_values_match = pair.each_with_index.all? { |value, index| !fixed_operands[index] || Value.same?(value, sample[index]) }
            fixed_values_match && infection.call(*pair, original) == true
          end
        end.uniq
        return if inputs.empty?

        same_samples = samples.size == observed.size && samples.all? { |pair| infection.call(*pair, original) == false }
        reason = explanation(original, samples) if same_samples
        { inputs: inputs, reason: reason }
      end

      def self.right_multiplier(source, original)
        return unless source

        parsed = Prism.parse(source)
        return if parsed.failure?

        node = parsed.value.statements&.body&.first
        matcher = Operators.fetch("arithmetic").matcher
        return unless matcher.call(node, nil) && node.name.to_s == original

        right = node.arguments.arguments.first
        right = right.body&.body&.last while right.is_a?(Prism::ParenthesesNode)
        return unless matcher.call(right, nil) && right.name == :*

        operands = [right.receiver, right.arguments.arguments.first]
        return 0 if operands.all?(Prism::IntegerNode)

        operands.find { |operand| operand.is_a?(Prism::IntegerNode) }&.value
      end

      def self.candidates(left, right, original, right_step)
        return [[left, right]] if Operators::EQUALITY.include?(original)
        return [[as_type(right, left), right], [left, as_type(left, right)]] if BOUNDARY.include?(original)

        nonzero_right = as_type(%w[+ -].include?(original) ? right_step : 2, right)
        nonzero_left = as_type(3, left)
        [[left, nonzero_right], [nonzero_left, right], [left, as_type(left, right)], [nonzero_left, nonzero_right]]
      end

      def self.as_type(value, sample)
        return value if Value::CLASS_OF.bind_call(sample) == Value::CLASS_OF.bind_call(value)

        Value::CLASS_OF.bind_call(sample) == Float ? TO_FLOAT.bind_call(value) : TO_INTEGER.bind_call(value)
      end

      def self.explanation(original, samples)
        return "No sampled pair had equal operands." if BOUNDARY.include?(original)
        return "Every sampled right operand was zero." if %w[+ -].include?(original) && samples.all? { |_, b| b == as_type(0, b) }
        return "Every sampled left operand was zero." if original == "%" && samples.all? { |a, _| a == as_type(0, a) }
        if %w[* /].include?(original) && samples.all? { |a, b| a == as_type(0, a) || b == as_type(1, b) || b == as_type(-1, b) }
          return "Each sampled pair had a zero left operand or a right operand of 1 or -1."
        end

        "Both operators produced the same result for each sampled pair."
      end

      private_class_method :right_multiplier, :candidates, :as_type, :explanation
    end
  end
end
