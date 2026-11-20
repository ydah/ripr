# frozen_string_literal: true

require "prism"

module Ripr
  module Core
    class Instrumenter
      def self.call(source, path, sites)
        new(source, path, sites).call
      end

      def self.mutate(source, mutant)
        source.byteslice(0, mutant.fetch(:start_offset)) + mutant.fetch(:mutated) + source.byteslice(mutant.fetch(:end_offset)..)
      end

      def initialize(source, path, sites)
        @source = source
        @path = path
        @sites = sites.reject { |site| site[:variants].all? { |variant| variant[:invalid] || variant[:accepted] } }
        @prefix = "__ripr"
        @prefix += "_" while @source.include?(@prefix)
      end

      def call
        selected = isolate(@sites, [])
        code = render(selected)
        selected = selected.select { |site| @emitted.include?(site[:key]) }
        rejected = @sites - selected
        { code: code, site_table: selected.to_h { |site| [site[:key], site[:variants].map { |variant| variant[:id] }] },
          invalid: rejected.flat_map { |s| s[:variants].map { |v| v[:id] } },
          warnings: rejected.empty? ? [] : ["#{@path}: excluded #{rejected.length} unsupported instrumentation sites"] }
      end

      private

      def render(sites)
        @emitted = []
        @by_node = sites.group_by { |site| [site[:node].location.start_offset, site[:node].location.end_offset, site[:node].type] }
        root = Prism.parse(@source).value
        # Prism excludes __END__ data and final whitespace from its root location.
        @source.byteslice(0, root.location.start_offset) + rewrite(root) + @source.byteslice(root.location.end_offset..)
      end

      def isolate(candidates, accepted)
        code = render(accepted + candidates)
        return accepted + candidates if code.count("\n") == @source.count("\n") && Prism.parse(code).success?
        return accepted if candidates.length <= 1

        middle = candidates.length / 2
        isolate(candidates.drop(middle), isolate(candidates.take(middle), accepted))
      end

      def rewrite(node)
        location = node.location
        cursor = location.start_offset
        rendered = {}
        text = +""
        node.compact_child_nodes.sort_by { |child| child.location.start_offset }.each do |child|
          child_location = child.location
          next if child_location.start_offset < cursor || child_location.end_offset > location.end_offset

          text << @source.byteslice(cursor, child_location.start_offset - cursor)
          rendered[child.node_id] = rewrite(child)
          text << rendered.fetch(child.node_id)
          cursor = child_location.end_offset
        end
        text << @source.byteslice(cursor, location.end_offset - cursor)
        sites = @by_node.fetch([location.start_offset, location.end_offset, node.type], [])
        priority = %w[comparison arithmetic integer_literal boolean_literal boolean_connector condition_negation statement_removal
                      return_nil]
        sites.sort_by { |site| priority.index(site[:operator]) || priority.length }.each do |site|
          text = wrap(site, node, text, rendered)
        end
        text
      end

      def wrap(site, node, text, rendered)
        @emitted << site[:key]
        key = site[:key].dump
        case site[:operator]
        when "comparison", "arithmetic"
          binary(site, node, rendered)
        when "integer_literal", "boolean_literal"
          "::Ripr::R.lit(#{key},(#{text}),#{site[:variants].map { |v| v[:replacement] }.join(',')})"
        when "condition_negation"
          "::Ripr::R.cond(#{key},((#{text}) ? true : false))"
        when "return_nil"
          "::Ripr::R.ret(#{key},(#{text}))"
        when "statement_removal"
          "(::Ripr::R.on?(#{key}) ? nil : (#{text}))"
        when "boolean_connector"
          left = rendered.fetch(node.left.node_id)
          right = rendered.fetch(node.right.node_id)
          replacement = site[:variants].first[:replacement]
          "(::Ripr::R.on?(#{key}) ? ((#{left}) #{replacement} (#{right})) : (#{text}))"
        else
          "(::Ripr::R.on?(#{key}) ? (#{site[:variants].first.fetch(:mutated)}) : (#{text}))"
        end
      end

      def binary(site, node, rendered)
        left = node.receiver
        right = node.arguments.arguments.first
        gap = @source.byteslice(left.location.end_offset, right.location.start_offset - left.location.end_offset).scan("\n").join
        lvar, rvar, kvar = %w[l r k].map { |part| "#{@prefix}_#{part}" }
        expressions = [node.name.to_s, *site[:variants].map { |variant| variant[:replacement] }]
        expression = "#{lvar} #{expressions.last} #{rvar}"
        (expressions.length - 2).downto(0) do |index|
          expression = "#{kvar} == #{index} ? #{lvar} #{expressions[index]} #{rvar} : (#{expression})"
        end
        "::Ripr::R.bin(#{site[:key].dump},(#{rendered.fetch(left.node_id)}),#{gap}(#{rewrite(right)}),#{site[:pure]}) " \
          "{ |#{lvar},#{rvar},#{kvar}| #{expression} }"
      end
    end
  end
end
