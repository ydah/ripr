# frozen_string_literal: true

module Ripr
  module Core
    module Operators
      COMPARISON = { :>= => ">", :> => ">=", :<= => "<", :< => "<=", :== => "!=", :!= => "==" }.freeze
      ARITHMETIC = { :+ => "-", :- => "+", :* => "/", :/ => "*", :% => "*" }.freeze
      NAMES = %w[comparison arithmetic integer_literal boolean_literal condition_negation boolean_connector return_nil
                 statement_removal].freeze

      def self.for(node)
        case node
        when Prism::CallNode
          return [] unless node.receiver && node.arguments&.arguments&.length == 1 && !node.call_operator_loc && !node.block
          return [] if node.arguments.arguments.first.is_a?(Prism::SplatNode)

          if COMPARISON.key?(node.name)
            [["comparison", COMPARISON.fetch(node.name), "value", node.message_loc]]
          elsif ARITHMETIC.key?(node.name)
            [["arithmetic", ARITHMETIC.fetch(node.name), "value", node.message_loc]]
          else
            []
          end
        when Prism::IntegerNode
          [node.value + 1, node.value - 1, 0].uniq.reject { |v| v == node.value }.map do |value|
            ["integer_literal", value.to_s, "always", node.location]
          end
        when Prism::TrueNode, Prism::FalseNode
          [["boolean_literal", node.is_a?(Prism::TrueNode) ? "false" : "true", "always", node.location]]
        when Prism::AndNode, Prism::OrNode
          return [] if node.location.slice.include?("\n")

          replacement = { "&&" => "||", "||" => "&&", "and" => "or", "or" => "and" }.fetch(node.operator_loc.slice)
          [["boolean_connector", replacement, "unknown", node.operator_loc]]
        else
          []
        end
      end
    end
  end
end
