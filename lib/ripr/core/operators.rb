# frozen_string_literal: true

module Ripr
  module Core
    module Operators
      COMPARISON = { :>= => ">", :> => ">=", :<= => "<", :< => "<=", :== => "!=", :!= => "==" }.freeze
      ARITHMETIC = { :+ => "-", :- => "+", :* => "/", :/ => "*", :% => "*" }.freeze
      NAMES = %w[comparison arithmetic integer_literal boolean_literal condition_negation boolean_connector return_nil
                 statement_removal].freeze
      EXTRA_NAMES = %w[string_literal regexp_literal collection_literal collection_method safe_navigation compound_assignment
                       case_when].freeze
      FULL_NAMES = (NAMES + EXTRA_NAMES).freeze
      COLLECTION_METHODS = { first: "last", last: "first" }.freeze

      def self.for(node, extended: false)
        variants = default_variants(node)
        variant = extended_variant(node) if extended
        variants << variant if variant
        variants
      end

      def self.default_variants(node)
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

      def self.extended_variant(node)
        location = node.location
        # shortcut: switch single-line expressions, extend when both branches can preserve multiline locations.
        return if location.start_line != location.end_line

        case node
        when Prism::StringNode
          return unless node.opening_loc && node.closing_loc && !node.opening_loc.slice.start_with?("<<")

          ["string_literal", node.unescaped.empty? ? '" "' : '""', "unknown", location]
        when Prism::RegularExpressionNode
          return if node.content_loc.slice.match?(/\(\?[<']/) || location.slice == "/(?!)/"

          ["regexp_literal", "/(?!)/", "unknown", location]
        when Prism::ArrayNode, Prism::HashNode
          return unless node.opening_loc && !node.elements.empty?

          ["collection_literal", node.is_a?(Prism::ArrayNode) ? "[]" : "{}", "unknown", location]
        when Prism::CallNode
          return if node.block

          operator = node.call_operator_loc&.slice
          if operator == "&."
            ["safe_navigation", ".", "unknown", node.call_operator_loc]
          elsif operator == "." && COLLECTION_METHODS.key?(node.name)
            ["collection_method", COLLECTION_METHODS.fetch(node.name), "unknown", node.message_loc]
          end
        else
          return unless node.respond_to?(:binary_operator_loc) && ARITHMETIC.key?(node.binary_operator)

          ["compound_assignment", "#{ARITHMETIC.fetch(node.binary_operator)}=", "unknown", node.binary_operator_loc]
        end
      end

      private_class_method :default_variants, :extended_variant
    end
  end
end
