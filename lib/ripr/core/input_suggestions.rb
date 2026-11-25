# frozen_string_literal: true

require_relative "../runtime"
require_relative "operators"

module Ripr
  module Core
    module InputSuggestions
      OPERATORS = { "comparison" => Operators::COMPARISON, "arithmetic" => Operators::ARITHMETIC }.freeze
      BOUNDARY = %w[>= > <= <].freeze
      EQUALITY = %w[== !=].freeze
      TO_FLOAT = Integer.instance_method(:to_f)
      TO_INTEGER = Float.instance_method(:to_i)
      FINITE = Float.instance_method(:finite?)

      def self.for(mutant)
        return unless mutant["status"] == "not_infected"

        original, replacement, operator = mutant.values_at("original_operator", "replacement", "operator")
        operators = OPERATORS[operator]
        return unless operators && original && replacement && operators[original.to_sym] == replacement

        observed = mutant.fetch("observed", [])
        fixed_operands = mutant.fetch("fixed_operands", [])
        samples = observed.select { |pair| pair.all? { |value| supported?(value, original) } }
        inputs = samples.filter_map do |sample|
          candidates(*sample, original).find do |pair|
            valid_operands = pair.each_with_index.all? do |value, index|
              supported?(value, original) && (!fixed_operands[index] || Value.same?(value, sample[index]))
            end
            valid_operands && same_outcome?(*pair, original, replacement) == false
          end
        end.uniq
        return if inputs.empty?

        same_samples = samples.size == observed.size && samples.all? { |a, b| same_outcome?(a, b, original, replacement) }
        reason = explanation(original, samples) if same_samples
        { inputs: inputs, reason: reason }
      end

      def self.supported?(value, original)
        klass = Value::CLASS_OF.bind_call(value)
        return false unless Value.pure?(value)
        return true if klass == Integer || (klass == Float && FINITE.bind_call(value))

        EQUALITY.include?(original) && [TrueClass, FalseClass, NilClass].include?(klass)
      end

      def self.candidates(left, right, original)
        return [[left, right]] if EQUALITY.include?(original)
        return [[as_type(right, left), right], [left, as_type(left, right)]] if BOUNDARY.include?(original)

        nonzero_right = as_type(%w[+ -].include?(original) ? 1 : 2, right)
        nonzero_left = as_type(3, left)
        [[left, nonzero_right], [nonzero_left, right], [left, as_type(left, right)], [nonzero_left, nonzero_right]]
      end

      def self.as_type(value, sample)
        return value if Value::CLASS_OF.bind_call(sample) == Value::CLASS_OF.bind_call(value)

        Value::CLASS_OF.bind_call(sample) == Float ? TO_FLOAT.bind_call(value) : TO_INTEGER.bind_call(value)
      end

      def self.same_outcome?(left, right, original, replacement)
        klass = Value::CLASS_OF.bind_call(left)
        a = klass.instance_method(original).bind_call(left, right)
        b = klass.instance_method(replacement).bind_call(left, right)
        Value.same?(a, b) if Value.pure?(a) && Value.pure?(b)
      rescue StandardError
        nil
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

      private_class_method :supported?, :candidates, :as_type, :same_outcome?, :explanation
    end
  end
end
