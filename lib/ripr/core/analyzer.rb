# frozen_string_literal: true

require "digest"
require "prism"
require_relative "instrumenter"
require_relative "operators"

module Ripr
  module Core
    class Analyzer
      OPERATORS = Operators::NAMES
      CONDITIONALS = [Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode].freeze

      def self.call(source, path, operators: OPERATORS, arid_callees: %w[logger.* puts pp warn], static: false)
        new(source, path, operators, arid_callees, static).call
      end

      def initialize(source, path, operators, arid_callees, static)
        @source = source
        @path = path
        @operators = operators
        @extended = @operators.intersect?(Operators::EXTRA_NAMES)
        @include_static = static
        @file_hash = Digest::SHA256.hexdigest(source) if static
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
        @source = parsed.source.source
        if parsed.failure?
          @warnings << "#{@path}: #{parsed.errors.map(&:message).join('; ')}"
        else
          parsed.comments.each { |comment| disable(comment) }
          discover(parsed.value, [], false, @include_static ? "root" : nil)
        end
        { source: @source, sites: @sites, mutants: @mutants, warnings: @warnings, static: @static }
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

      def discover(node, namespace, singleton, ast_path = nil, parent = nil)
        return if unsupported?(node)
        return if @include_static && node.is_a?(Prism::DefinedNode)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = node.constant_path.location.slice
          namespace = name.start_with?("::") ? [name.delete_prefix("::")] : [*namespace, name]
          discover(node.body, namespace, false, ast_path && "#{ast_path}.body", node) if node.body
        when Prism::SingletonClassNode
          discover(node.body, namespace, true, ast_path && "#{ast_path}.body", node) if node.body
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
          discover_static(node, namespace, singleton, ast_path, parent)
          children(node).each { |field, child| discover(child, namespace, singleton, ast_path && "#{ast_path}.#{field}", node) }
        end
      end

      def discover_static(node, namespace, singleton, ast_path, parent)
        variants = operator_variants(node, parent)
        unless @include_static
          @static += variants.length
          return
        end

        owner = namespace.empty? ? "Object" : namespace.join("::")
        suffix = singleton ? "<singleton-body>" : "<load>"
        context = { subject: "#{owner}::#{suffix}", method_hash: @file_hash, method_start: node.location.start_line,
                    method_end: node.location.end_line, static: true }
        variants.each do |operator, replacement, mode, location|
          if @operators.include?(operator)
            add(node, ast_path, operator, replacement, mode, location, context)
          else
            @static += 1
          end
        end
        condition_variant(node, ast_path, context)
        case_variants(node, ast_path, context)
      end

      def walk(node, ast_path, context, depth, parent = nil)
        return if unsupported?(node)
        # defined? inspects its operand's syntax without evaluating it.
        return if node.is_a?(Prism::DefinedNode)

        return discover(node, context[:subject].split(/[.#]/).first.split("::"), false) if node.is_a?(Prism::DefNode)

        operator_variants(node, parent).each do |operator, replacement, mode, location|
          next if operator == "boolean_connector" && depth >= 3

          add(node, ast_path, operator, replacement, mode, location, context)
        end
        case_variants(node, ast_path, context)
        condition_variant(node, ast_path, context)
        if node.is_a?(Prism::StatementsNode)
          node.body[0...-1].each_with_index do |statement, index|
            next if control?(statement) || arid?(statement)

            add(statement, "#{ast_path}.body.#{index}", "statement_removal", "nil", "unknown", statement.location, context)
          end
        end
        next_depth = depth + (node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) ? 1 : 0)
        children(node).each { |field, child| walk(child, "#{ast_path}.#{field}", context, next_depth, node) }
      end

      def operator_variants(node, parent)
        return [] if @extended && node.is_a?(Prism::StringNode) && parent.is_a?(Prism::InterpolatedStringNode)

        Operators.for(node, extended: @extended)
      end

      def condition_variant(node, ast_path, context)
        return unless CONDITIONALS.any? { |klass| node.is_a?(klass) }

        predicate = node.predicate
        add(predicate, "#{ast_path}.predicate", "condition_negation", "!", "always", predicate.location, context)
      end

      def case_variants(node, ast_path, context)
        return unless node.is_a?(Prism::CaseNode) && @operators.include?("case_when")

        replacement = node.predicate ? "->(*) { false }" : "false"
        node.conditions.each_with_index do |branch, branch_index|
          branch.conditions.each_with_index do |condition, index|
            next if condition.is_a?(Prism::SplatNode) || condition.is_a?(Prism::MatchLastLineNode)
            next if condition.location.start_line != condition.location.end_line || condition.location.slice == replacement

            add(condition, "#{ast_path}.conditions.#{branch_index}.conditions.#{index}", "case_when", replacement, "unknown",
                condition.location, context)
          end
        end
      end

      def control?(node)
        %i[return_node break_node next_node redo_node retry_node def_node class_node module_node].include?(node.type) ||
          (node.is_a?(Prism::CallNode) && %i[raise fail].include?(node.name))
      end

      def unsupported?(node)
        reason = if node.is_a?(Prism::CallNode) && node.name == :define_method && node.block
                   "define_method block"
                 elsif node.is_a?(Prism::SingletonClassNode) && !node.expression.is_a?(Prism::SelfNode)
                   "singleton receiver"
                 end
        return false unless reason

        @warnings << "#{@path}:#{node.location.start_line}: skipped unsupported #{reason}"
        true
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
                               accepted: accepted, start_offset: node.location.start_offset, end_offset: node.location.end_offset,
                               location: { file: @path, line: node.location.start_line,
                                           column: node.location.start_column + 1, end_line: node.location.end_line,
                                           end_column: node.location.end_column + 1 })
        if %w[comparison arithmetic].include?(operator)
          mutant[:original_operator] = node.name.to_s
          mutant[:fixed_operands] = [node.receiver, node.arguments.arguments.first].map { |operand| fixed_operand?(operand) }
        end
        mutant[:invalid] = true if Prism.parse(Instrumenter.mutate(@source, mutant)).failure?
        @mutants << mutant
        site = @sites.find { |entry| entry[:key] == key }
        unless site
          site = { key: key, node: node, operator: operator, variants: [], pure: !@source.match?(/\b(using|refine)\b/) }
          @sites << site
        end
        site[:variants] << mutant
      end

      def fixed_operand?(node)
        node = node.body&.body&.last while node.is_a?(Prism::ParenthesesNode)
        node.nil? || node.static_literal? || node.is_a?(Prism::StringNode) || node.is_a?(Prism::SourceFileNode)
      end
    end
  end
end
