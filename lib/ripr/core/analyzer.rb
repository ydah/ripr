# frozen_string_literal: true

require "digest"
require "prism"
require_relative "instrumenter"
require_relative "operators"

module Ripr
  module Core
    class Analyzer
      OPERATORS = Operators::NAMES

      def self.call(source, path, operators: OPERATORS, arid_callees: %w[logger.* puts pp warn], static: false, skipped: nil)
        new(source, path, operators, arid_callees, static, skipped).call
      end

      def initialize(source, path, operators, arid_callees, static, skipped = nil)
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
        @skipped = skipped
        @subjects = Hash.new(0)
        @static = 0
        @disabled = {}
      end

      def call
        parsed = Prism.parse(@source)
        @source = parsed.source.source
        if parsed.failure?
          @warnings << "#{@path}: #{parsed.errors.map(&:message).join('; ')}"
          parsed.errors.each { |error| skip(error.location, "parse error: #{error.message}") } if @skipped
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
        return if excluded?(node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = node.constant_path.location.slice
          namespace = name.start_with?("::") ? [name.delete_prefix("::")] : [*namespace, name]
          discover(node.body, namespace, false, ast_path && "#{ast_path}.body", node) if node.body
        when Prism::SingletonClassNode
          discover(node.body, namespace, true, ast_path && "#{ast_path}.body", node) if node.body
        when Prism::DefNode
          discover_body(node, node.body, namespace, node.receiver || singleton, node.name)
        when Prism::LambdaNode
          discover_body(node, node.body, namespace, singleton, "<lambda>")
        else
          discover_static(node, namespace, singleton, ast_path, parent)
          deferred = deferred_name(node)
          children(node).each do |field, child|
            if deferred && field == "block"
              discover_body(node, child.body, namespace, singleton, deferred)
            else
              discover(child, namespace, singleton, ast_path && "#{ast_path}.#{field}", node)
            end
          end
        end
      end

      def discover_body(node, body, namespace, singleton, name)
        owner = namespace.empty? ? "Object" : namespace.join("::")
        subject = "#{owner}#{singleton ? '.' : '#'}#{name}"
        @subjects[subject] += 1
        return unless body

        subject += "[#{@subjects[subject]}]" if @subjects[subject] > 1
        context = { subject: subject, method_hash: Digest::SHA256.hexdigest(node.location.slice),
                    method_start: node.location.start_line, method_end: node.location.end_line }
        walk(body, "body", context, 0)
        last = body.body.last if body.is_a?(Prism::StatementsNode)
        contextual_variants("return_nil", last, "body.return", context) if last
      end

      def define_method_block?(node)
        node.is_a?(Prism::CallNode) && node.name == :define_method && node.block.is_a?(Prism::BlockNode)
      end

      def deferred_name(node)
        return unless node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)

        case node.name
        when :define_method
          argument = node.arguments&.arguments&.first
          name = argument.unescaped if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
          "#{name}<define_method>"
        when :lambda, :proc
          receiver = node.receiver
          "<#{node.name}>" if receiver.nil? || receiver.is_a?(Prism::SelfNode) || %w[Kernel ::Kernel].include?(receiver.location.slice)
        when :new
          "<proc>" if %w[Proc ::Proc].include?(node.receiver&.location&.slice)
        end
      end

      def discover_static(node, namespace, singleton, ast_path, parent)
        variants = operator_variants(node, parent)
        unless @include_static
          @static += variants.length
          skip_static(node, variants) if @skipped
          return
        end

        owner = namespace.empty? ? "Object" : namespace.join("::")
        suffix = singleton ? "<singleton-body>" : "<load>"
        context = { subject: "#{owner}::#{suffix}", method_hash: @file_hash, method_start: node.location.start_line,
                    method_end: node.location.end_line, static: true }
        variants.each do |operator, replacement, _, location|
          if @operators.include?(operator)
            add(node, ast_path, operator, replacement, location, context)
          else
            @static += 1
          end
        end
        contextual_variants("condition_negation", node, ast_path, context)
        contextual_variants("case_when", node, ast_path, context)
        contextual_variants("case_in", node, ast_path, context)
      end

      def walk(node, ast_path, context, depth, parent = nil)
        return discover(node, context[:subject].split(/[.#]/).first.split("::"), false) if node.is_a?(Prism::DefNode)
        return if excluded?(node)

        operator_variants(node, parent).each do |operator, replacement, _, location|
          if operator == "boolean_connector" && depth >= 3
            skip(location, "boolean connector exceeds the mutation depth limit") if @operators.include?(operator)
            next
          end

          add(node, ast_path, operator, replacement, location, context)
        end
        contextual_variants("case_when", node, ast_path, context)
        contextual_variants("case_in", node, ast_path, context)
        contextual_variants("condition_negation", node, ast_path, context)
        if node.is_a?(Prism::StatementsNode) && @operators.include?("statement_removal")
          definition = Operators.fetch("statement_removal")
          node.body[0...-1].each_with_index do |statement, index|
            variants = definition.variants_for(statement)
            next if variants.empty?

            if arid?(statement)
              skip(statement.location, "statement removal suppressed by arid_callees")
              next
            end

            emit_variants("statement_removal", variants, "#{ast_path}.body.#{index}", context)
          end
        end
        next_depth = depth + (node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) ? 1 : 0)
        children(node).each do |field, child|
          if field == "block" && define_method_block?(node)
            discover_body(node, child.body, context[:subject].split(/[.#]/).first.split("::"), false, deferred_name(node))
          else
            walk(child, "#{ast_path}.#{field}", context, next_depth, node)
          end
        end
      end

      def operator_variants(node, parent)
        Operators.for(node, extended: @extended, parent: parent)
      end

      def contextual_variants(operator, node, ast_path, context)
        return unless @operators.include?(operator)

        emit_variants(operator, Operators.fetch(operator).variants_for(node), ast_path, context)
      end

      def emit_variants(operator, variants, ast_path, context)
        variants.each do |node, suffix, replacement, location|
          path = suffix ? "#{ast_path}.#{suffix}" : ast_path
          add(node, path, operator, replacement, location, context)
        end
      end

      def excluded?(node)
        if node.is_a?(Prism::DefinedNode)
          skip(node.value.location, "defined? operand requires its original syntax")
          return true
        end

        receiver = case node
                   when Prism::DefNode then node.receiver
                   when Prism::SingletonClassNode then node.expression
                   end
        return false unless receiver && !receiver.is_a?(Prism::SelfNode)

        @warnings << "#{@path}:#{node.location.start_line}: skipped unsupported singleton receiver"
        skip(node.location, "unsupported singleton receiver")
        true
      end

      def skip_static(node, variants)
        reason = "load-time expression requires --static"
        skip(node.location, reason) if variants.any? { |operator, *| @operators.include?(operator) }
        %w[condition_negation case_when].each do |operator|
          next unless @operators.include?(operator)

          Operators.fetch(operator).variants_for(node).each { |variant| skip(variant.first.location, reason) }
        end
      end

      def skip(location, reason)
        @skipped&.push([@path, location.start_line, location.start_column + 1, reason])
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

      def add(node, ast_path, operator, replacement, location, context)
        return unless @operators.include?(operator)

        definition = Operators.fetch(operator)
        key = "#{@path}::#{context.fetch(:subject)}::#{ast_path}::#{operator}"
        full_id = "#{key}::#{replacement}"
        original = node.location.slice
        offset = location.start_offset - node.location.start_offset
        mutated = definition.rewrite(original, replacement, offset, location.length)
        reason = @disabled[node.location.start_line]
        accepted = reason && (reason[0].empty? || reason[0].include?(operator)) ? reason[1] : nil
        mutant = context.merge(id: Digest::SHA256.hexdigest(full_id)[0, 10], full_id: full_id, site: key,
                               operator: operator, replacement: replacement, mode: definition.mode,
                               original: original, mutated: mutated,
                               accepted: accepted, start_offset: node.location.start_offset, end_offset: node.location.end_offset,
                               location: { file: @path, line: node.location.start_line,
                                           column: node.location.start_column + 1, end_line: node.location.end_line,
                                           end_column: node.location.end_column + 1 })
        if definition.instrument_template == :binary
          mutant[:original_operator] = node.name.to_s
          mutant[:fixed_operands] = [node.receiver, node.arguments.arguments.first].map { |operand| fixed_operand?(operand) }
        end
        if Prism.parse(Instrumenter.mutate(@source, mutant)).failure?
          return if definition.instrument_template == :pattern

          mutant[:invalid] = true
        end
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
