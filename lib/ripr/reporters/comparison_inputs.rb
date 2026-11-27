# frozen_string_literal: true

require_relative "../core/analyzer"

module Ripr
  module Reporters
    module ComparisonInputs
      def self.enrich(results, sources)
        candidates = results.select { |entry| entry["status"] == "not_reached" && entry.fetch("subject").end_with?("#<=>") }
        return results if candidates.empty?

        records = results.to_h { |entry| [entry.fetch("full_id"), entry] }
        suggestions = {}
        candidates.group_by { |entry| entry.fetch("location").fetch("file") }.each do |path, entries|
          source = sources[path]
          next unless source

          parsed = Prism.parse(source)
          next if parsed.failure?

          definitions = method_nodes(parsed.value).to_h { |node| [Digest::SHA256.hexdigest(node.location.slice), node] }
          operators = %w[comparison statement_removal condition_negation return_nil]
          analysis = Core::Analyzer.call(source, path, operators: operators, arid_callees: [])
          current = analysis.fetch(:mutants).to_h { |entry| [entry.fetch(:full_id), entry] }
          entries.each do |entry|
            variant = current[entry.fetch("full_id")]
            next unless matches?(entry, variant)

            subject = variant.fetch(:subject)
            equality_subject = "#{subject.delete_suffix('#<=>')}#=="
            next if current.values.any? { |item| [subject, equality_subject].any? { |name| item.fetch(:subject).start_with?("#{name}[") } }

            definition = definitions[variant.fetch(:method_hash)]
            steps = chain(definition)
            next unless steps

            selected = selected_steps(variant, definition, steps)
            selected.each do |_statement, _predicate, field|
              pair = numeric_pair(analysis.fetch(:sites), records, definitions, equality_subject, field)
              next unless pair

              suggestions[entry.fetch("full_id")] = {
                "left" => field.fetch(:left), "right" => field.fetch(:right), "values" => pair,
                "zero_comparisons" => steps.filter_map { |step| step.last.fetch(:comparison) unless step.last == field }
              }
              break
            end
          end
        end
        return results if suggestions.empty?

        results.map do |entry|
          suggestion = suggestions[entry.fetch("full_id")]
          suggestion ? entry.merge("comparison_inputs" => suggestion) : entry
        end
      end

      def self.selected_steps(variant, definition, steps)
        case variant.fetch(:operator)
        when "statement_removal"
          return steps if span?(variant, steps.first.first)

          steps.select { |statement, _predicate, _field| span?(variant, statement) }
        when "condition_negation"
          steps.select { |_statement, predicate, _field| predicate && span?(variant, predicate) }
        when "return_nil"
          span?(variant, definition.body.body.last) ? steps : []
        else []
        end
      end

      def self.method_nodes(root)
        nodes = []
        pending = [root]
        until pending.empty?
          node = pending.pop
          if node.is_a?(Prism::DefNode)
            nodes << node if node.receiver.nil? && %i[<=> ==].include?(node.name)
          else
            pending.concat(node.compact_child_nodes)
          end
        end
        nodes
      end

      def self.parameter(definition)
        parameters = definition&.parameters
        argument = parameters&.requireds&.first
        argument.name if argument.is_a?(Prism::RequiredParameterNode) && parameters.compact_child_nodes == [argument]
      end

      def self.chain(definition)
        argument = parameter(definition)
        body = definition&.body
        return unless argument && body.is_a?(Prism::StatementsNode) && body.body.size >= 3

        first, *rest = body.body
        return unless first.is_a?(Prism::LocalVariableWriteNode) && first.name != argument
        return unless rest.last.is_a?(Prism::LocalVariableReadNode) && rest.last.name == first.name

        steps = [[first, nil, field(first.value, :<=>, argument)]]
        rest[0...-1].each do |statement|
          return nil unless statement.is_a?(Prism::IfNode) && statement.subsequent.nil? && statement.statements&.body&.size == 1

          predicate = statement.predicate
          return nil unless plain_call?(predicate, :zero?) && predicate.receiver.is_a?(Prism::LocalVariableReadNode) &&
                            predicate.receiver.name == first.name

          assignment = statement.statements.body.first
          return nil unless assignment.is_a?(Prism::LocalVariableWriteNode) && assignment.name == first.name

          steps << [statement, predicate, field(assignment.value, :<=>, argument)]
        end
        fields = steps.map(&:last)
        steps if fields.all? && fields.map { |item| item.fetch(:name) }.uniq.size == fields.size
      end

      def self.field(node, operator, argument)
        return unless node.is_a?(Prism::CallNode) && node.name == operator && !node.safe_navigation? && node.block.nil?
        return unless node.arguments&.arguments&.size == 1

        left = node.receiver
        right = node.arguments.arguments.first
        return unless right.is_a?(Prism::CallNode) && plain_call?(right, right.name)
        return unless right.receiver.is_a?(Prism::LocalVariableReadNode) && right.receiver.name == argument

        name = if left.is_a?(Prism::InstanceVariableReadNode)
                 left.name.to_s.delete_prefix("@")
               elsif left.is_a?(Prism::CallNode) && plain_call?(left, left.name) && left.receiver.nil?
                 left.name.to_s
               end
        { left: left.location.slice, right: right.location.slice, name: name, comparison: node.location.slice } if name == right.name.to_s
      end

      def self.plain_call?(node, name)
        node.is_a?(Prism::CallNode) && node.name == name && node.arguments.nil? && node.block.nil? && !node.safe_navigation?
      end

      def self.numeric_pair(sites, records, definitions, subject, expected_field)
        sites.each do |site|
          next unless site.fetch(:operator) == "comparison"

          variant = site.fetch(:variants).first
          next unless variant.fetch(:subject) == subject

          argument = parameter(definitions[variant.fetch(:method_hash)])
          next unless argument

          equality = field(site.fetch(:node), :==, argument)
          next unless equality && equality.values_at(:left, :name) == expected_field.values_at(:left, :name)

          record = records[variant.fetch(:full_id)]
          next unless matches?(record, variant)

          values = record.fetch("observed", []).select do |pair|
            pair.size == 2 && pair.all? { |value| Value::CLASS_OF.bind_call(value) == Integer }
          end.flatten.uniq.take(2)
          return values if values.size == 2
        end
        nil
      end

      def self.matches?(record, variant)
        return false unless record && variant

        fields = %i[id full_id subject operator original mutated method_hash start_offset end_offset]
        fields.all? { |key| record[key.to_s] == variant[key] } &&
          record["location"] == variant.fetch(:location).transform_keys(&:to_s)
      end

      def self.span?(variant, node)
        variant[:start_offset] == node.location.start_offset && variant[:end_offset] == node.location.end_offset
      end

      private_class_method :selected_steps, :method_nodes, :parameter, :chain, :field, :plain_call?, :numeric_pair, :matches?, :span?
    end
    private_constant :ComparisonInputs
  end
end
