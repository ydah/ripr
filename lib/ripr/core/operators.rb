# frozen_string_literal: true

require_relative "../runtime"

module Ripr
  module Core
    module Operators
      EQUALITY = %w[== !=].freeze
      FINITE = Float.instance_method(:finite?)

      Definition = Data.define(:node_types, :matcher, :variants, :mode, :infection_condition, :comparator, :instrument_template) do
        def variants_for(node, parent = nil)
          return [] if matcher && !matcher.call(node, parent)
          return variants.call(node) unless variants.is_a?(Hash)

          replacement = variants[node.name]
          replacement ? [[node, nil, replacement, node.message_loc]] : []
        end

        def rewrite(original, replacement, offset, length)
          case instrument_template
          when :condition then "!(#{original})"
          when :return then "(#{original}; nil)"
          else original.byteslice(0, offset) + replacement + original.byteslice((offset + length)..)
          end
        end
      end

      def self.definition(variants, nodes: [], matcher: nil, mode: "unknown", infection_condition: nil, comparator: nil, template: :switch)
        Definition.new(nodes.freeze, matcher, variants, mode, infection_condition, comparator, template)
      end

      def self.binary_definition(variants, comparator:)
        infection = ->(left, right, original) { native_infection(left, right, original, variants[original.to_sym]) }
        definition(
          variants.freeze,
          nodes: [:call_node], matcher: method(:binary_call?), mode: "value",
          infection_condition: infection, comparator: comparator, template: :binary
        )
      end

      def self.native_operand?(value, original)
        klass = Value::CLASS_OF.bind_call(value)
        return false unless Value.pure?(value)
        return true if klass == Integer || (klass == Float && FINITE.bind_call(value))

        EQUALITY.include?(original) && [TrueClass, FalseClass, NilClass].include?(klass)
      end

      def self.native_infection(left, right, original, replacement)
        return unless replacement && native_operand?(left, original) && native_operand?(right, original)

        klass = Value::CLASS_OF.bind_call(left)
        before = klass.instance_method(original).bind_call(left, right)
        after = klass.instance_method(replacement).bind_call(left, right)
        !Value.same?(before, after) if Value.pure?(before) && Value.pure?(after)
      rescue StandardError
        nil
      end

      def self.binary_call?(node, _parent)
        node.is_a?(Prism::CallNode) && node.receiver && node.arguments&.arguments&.length == 1 && !node.call_operator_loc && !node.block &&
          !node.arguments.arguments.first.is_a?(Prism::SplatNode)
      end

      def self.integer_variants(node)
        [node.value + 1, node.value - 1, 0].uniq.reject { |value| value == node.value }.map do |value|
          [node, nil, value.to_s, node.location]
        end
      end

      def self.boolean_variants(node)
        [[node, nil, node.is_a?(Prism::TrueNode) ? "false" : "true", node.location]]
      end

      def self.connector_variants(node)
        replacement = { "&&" => "||", "||" => "&&", "and" => "or", "or" => "and" }.fetch(node.operator_loc.slice)
        [[node, nil, replacement, node.operator_loc]]
      end

      def self.connector?(node, _parent)
        !node.location.slice.include?("\n")
      end

      def self.conditional?(node, _parent)
        %i[if_node unless_node while_node until_node].include?(node.type)
      end

      def self.condition_variants(node)
        predicate = node.predicate
        [[predicate, "predicate", "!", predicate.location]]
      end

      def self.execution_expression?(node, _parent)
        !%i[return_node break_node next_node redo_node retry_node def_node class_node module_node].include?(node.type) &&
          !(node.is_a?(Prism::CallNode) && %i[raise fail].include?(node.name))
      end

      def self.nil_variants(node)
        [[node, nil, "nil", node.location]]
      end

      def self.single_line?(node)
        node.location.start_line == node.location.end_line
      end

      def self.string_literal?(node, parent)
        single_line?(node) && !parent.is_a?(Prism::InterpolatedStringNode) && node.opening_loc && node.closing_loc &&
          !node.opening_loc.slice.start_with?("<<")
      end

      def self.string_variants(node)
        [[node, nil, node.unescaped.empty? ? '" "' : '""', node.location]]
      end

      def self.regexp_literal?(node, _parent)
        single_line?(node) && !node.content_loc.slice.match?(/\(\?[<']/) && node.location.slice != "/(?!)/"
      end

      def self.regexp_variants(node)
        [[node, nil, "/(?!)/", node.location]]
      end

      def self.collection_literal?(node, _parent)
        single_line?(node) && node.opening_loc && !node.elements.empty?
      end

      def self.collection_variants(node)
        [[node, nil, node.is_a?(Prism::ArrayNode) ? "[]" : "{}", node.location]]
      end

      def self.collection_call?(node, _parent)
        single_line?(node) && !node.block && node.call_operator_loc&.slice == "."
      end

      def self.safe_navigation?(node, _parent)
        single_line?(node) && !node.block && node.call_operator_loc&.slice == "&."
      end

      def self.safe_navigation_variants(node)
        [[node, nil, ".", node.call_operator_loc]]
      end

      def self.compound_variants(node)
        operator = fetch("arithmetic").variants[node.binary_operator]
        operator ? [[node, nil, "#{operator}=", node.binary_operator_loc]] : []
      end

      def self.case_variants(node)
        replacement = node.predicate ? "->(*) { false }" : "false"
        node.conditions.each_with_index.flat_map do |branch, branch_index|
          branch.conditions.each_with_index.filter_map do |condition, index|
            next if condition.is_a?(Prism::SplatNode) || condition.is_a?(Prism::MatchLastLineNode)
            next unless single_line?(condition) && condition.location.slice != replacement

            [condition, "conditions.#{branch_index}.conditions.#{index}", replacement, condition.location]
          end
        end
      end

      DEFAULT = {
        "comparison" => binary_definition(
          { :>= => ">", :> => ">=", :<= => "<", :< => "<=", :== => "!=", :!= => "==" }, comparator: :scalar
        ),
        "arithmetic" => binary_definition({ :+ => "-", :- => "+", :* => "/", :/ => "*", :% => "*" }, comparator: :native_array_copy),
        "integer_literal" => definition(method(:integer_variants), nodes: [:integer_node], mode: "always", template: :literal),
        "boolean_literal" => definition(method(:boolean_variants), nodes: %i[true_node false_node], mode: "always", template: :literal),
        "condition_negation" => definition(
          method(:condition_variants), matcher: method(:conditional?), mode: "always", template: :condition
        ),
        "boolean_connector" => definition(
          method(:connector_variants), nodes: %i[and_node or_node], matcher: method(:connector?), template: :connector
        ),
        "return_nil" => definition(method(:nil_variants), matcher: method(:execution_expression?), mode: "value", template: :return),
        "statement_removal" => definition(method(:nil_variants), matcher: method(:execution_expression?), template: :removal)
      }.freeze
      EXTENDED = {
        "string_literal" => definition(method(:string_variants), nodes: [:string_node], matcher: method(:string_literal?)),
        "regexp_literal" => definition(method(:regexp_variants), nodes: [:regular_expression_node], matcher: method(:regexp_literal?)),
        "collection_literal" => definition(
          method(:collection_variants), nodes: %i[array_node hash_node], matcher: method(:collection_literal?)
        ),
        "collection_method" => definition({ first: "last", last: "first" }.freeze, nodes: [:call_node], matcher: method(:collection_call?)),
        "safe_navigation" => definition(method(:safe_navigation_variants), nodes: [:call_node], matcher: method(:safe_navigation?)),
        "compound_assignment" => definition(
          method(:compound_variants), nodes: [:other], matcher: ->(node, _) { single_line?(node) && node.respond_to?(:binary_operator_loc) }
        ),
        "case_when" => definition(method(:case_variants), matcher: ->(node, _) { node.is_a?(Prism::CaseNode) })
      }.freeze
      REGISTRY = DEFAULT.merge(EXTENDED).freeze
      NAMES = DEFAULT.keys.freeze
      EXTRA_NAMES = EXTENDED.keys.freeze
      FULL_NAMES = REGISTRY.keys.freeze

      def self.by_node_type(definitions)
        definitions.each_with_object({}) do |(name, definition), types|
          definition.node_types.each { |type| (types[type] ||= []) << name }
        end.transform_values(&:freeze).freeze
      end

      DEFAULT_EXPRESSIONS = by_node_type(DEFAULT)
      FULL_EXPRESSIONS = by_node_type(REGISTRY)

      def self.fetch(name)
        REGISTRY.fetch(name)
      end

      def self.for(node, extended: false, parent: nil)
        profiles = extended ? FULL_EXPRESSIONS : DEFAULT_EXPRESSIONS
        names = profiles.fetch(node.type) { profiles.fetch(:other, []) }
        names.flat_map do |name|
          definition = fetch(name)
          definition.variants_for(node, parent).map do |_, _, replacement, location|
            [name, replacement, definition.mode, location]
          end
        end
      end

      private_class_method :definition, :binary_definition, :native_infection, :by_node_type,
                           :binary_call?, :integer_variants, :boolean_variants, :connector_variants,
                           :connector?, :conditional?,
                           :condition_variants, :execution_expression?, :nil_variants, :single_line?, :string_literal?, :string_variants,
                           :regexp_literal?, :regexp_variants, :collection_literal?, :collection_variants, :collection_call?,
                           :safe_navigation?, :safe_navigation_variants, :compound_variants, :case_variants
    end
  end
end
