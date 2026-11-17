# frozen_string_literal: true

require "digest"
require "prism"
require_relative "operators"

module Ripr
  module Core
    class Analyzer
      OPERATORS = Operators::NAMES

      def self.call(source, path, operators: OPERATORS, arid_callees: %w[logger.* puts pp warn])
        new(source, path, operators, arid_callees).call
      end

      def initialize(source, path, operators, arid_callees)
        @source = source
        @path = path
        @operators = operators
        @arid_callees = arid_callees
        @sites = []
        @mutants = []
        @warnings = []
        @subjects = Hash.new(0)
        @static = 0
        @disabled = {}
      end

      def call
        parsed = Prism.parse(@source)
        if parsed.failure?
          @warnings << "#{@path}: #{parsed.errors.map(&:message).join('; ')}"
        else
          parsed.comments.each { |comment| disable(comment) }
          discover(parsed.value, [], false)
        end
        { sites: @sites, mutants: @mutants, warnings: @warnings, static: @static }
      end

      private

      def children(node)
        node.deconstruct_keys(nil).flat_map do |field, value|
          if value.is_a?(Prism::Node)
            [[field.to_s, value]]
          elsif value.is_a?(Array)
            value.each_with_index.filter_map { |child, index| ["#{field}.#{index}", child] if child.is_a?(Prism::Node) }
          else
            []
          end
        end
      end

      def discover(node, namespace, singleton)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = node.constant_path.location.slice
          namespace = name.start_with?("::") ? [name.delete_prefix("::")] : [*namespace, name]
          discover(node.body, namespace, false) if node.body
        when Prism::SingletonClassNode
          discover(node.body, namespace, true) if node.body
        when Prism::DefNode
          if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
            @warnings << "#{@path}:#{node.location.start_line}: skipped unsupported singleton receiver"
            return
          end
          owner = namespace.empty? ? "Object" : namespace.join("::")
          separator = node.receiver || singleton ? "." : "#"
          subject = "#{owner}#{separator}#{node.name}"
          @subjects[subject] += 1
          subject += "[#{@subjects[subject]}]" if @subjects[subject] > 1
          context = { subject: subject, method_hash: Digest::SHA256.hexdigest(node.location.slice),
                      method_start: node.location.start_line, method_end: node.location.end_line }
          walk(node.body, "body", context, 0) if node.body
          last = node.body.body.last if node.body.is_a?(Prism::StatementsNode)
          add(last, "body.return", "return_nil", "nil", "value", last.location, context) if last && !control?(last)
        else
          @static += Operators.for(node).length
          children(node).each { |entry| discover(entry[1], namespace, singleton) }
        end
      end

      def walk(node, ast_path, context, depth)
        return discover(node, context[:subject].split(/[.#]/).first.split("::"), false) if node.is_a?(Prism::DefNode)

        Operators.for(node).each do |operator, replacement, mode, location|
          next if operator == "boolean_connector" && depth >= 3

          add(node, ast_path, operator, replacement, mode, location, context)
        end
        if [Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode].any? { |klass| node.is_a?(klass) }
          predicate = node.predicate
          add(predicate, "#{ast_path}.predicate", "condition_negation", "!", "always", predicate.location, context)
        end
        if node.is_a?(Prism::StatementsNode)
          node.body[0...-1].each_with_index do |statement, index|
            next if control?(statement) || arid?(statement)

            add(statement, "#{ast_path}.body.#{index}", "statement_removal", "nil", "unknown", statement.location, context)
          end
        end
        next_depth = depth + (node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) ? 1 : 0)
        children(node).each { |field, child| walk(child, "#{ast_path}.#{field}", context, next_depth) }
      end

      def control?(node)
        %i[return_node break_node next_node redo_node retry_node def_node class_node module_node].include?(node.type) ||
          (node.is_a?(Prism::CallNode) && %i[raise fail].include?(node.name))
      end

      def arid?(node)
        return true if node.is_a?(Prism::CallNode) && @arid_callees.any? do |pattern|
          callee = node.receiver ? "#{node.receiver.location.slice}.#{node.name}" : node.name.to_s
          File.fnmatch?(pattern, callee)
        end

        node.compact_child_nodes.any? { |child| arid?(child) }
      end

      def disable(comment)
        match = comment.location.slice.match(/#\s*ripr:disable-(line|next-line)\s*(.*?)\s*(?:--\s*(.*))?$/)
        return unless match

        line = comment.location.start_line + (match[1] == "next-line" ? 1 : 0)
        @disabled[line] = [match[2].split(/[\s,]+/), match[3] || "inline disable"]
      end

      def add(node, ast_path, operator, replacement, mode, location, context)
        return unless @operators.include?(operator)

        key = "#{@path}::#{context.fetch(:subject)}::#{ast_path}::#{operator}"
        full_id = "#{key}::#{replacement}"
        original = node.location.slice
        mutated = case operator
                  when "condition_negation" then "!(#{original})"
                  when "return_nil" then "(#{original}; nil)"
                  when "statement_removal" then "nil"
                  else
                    offset = location.start_offset - node.location.start_offset
                    original.byteslice(0, offset) + replacement + original.byteslice((offset + location.length)..)
                  end
        reason = @disabled[node.location.start_line]
        accepted = reason && (reason[0].empty? || reason[0].include?(operator)) ? reason[1] : nil
        mutant = context.merge(id: Digest::SHA256.hexdigest(full_id)[0, 10], full_id: full_id, site: key,
                               operator: operator, replacement: replacement, mode: mode, original: original, mutated: mutated,
                               accepted: accepted, location: { file: @path, line: node.location.start_line,
                                                               column: node.location.start_column + 1, end_line: node.location.end_line,
                                                               end_column: node.location.end_column + 1 })
        candidate = @source.byteslice(0, node.location.start_offset) + mutated + @source.byteslice(node.location.end_offset..)
        mutant[:invalid] = true if Prism.parse(candidate).failure?
        @mutants << mutant
        site = @sites.find { |entry| entry[:key] == key }
        unless site
          site = { key: key, node: node, operator: operator, variants: [], pure: !@source.match?(/\b(using|refine)\b/) }
          @sites << site
        end
        site[:variants] << mutant
      end
    end
  end
end
