# frozen_string_literal: true

module Ripr
  module Value
    TYPES = [Integer, Float, Rational, String, Symbol, NilClass, TrueClass, FalseClass].freeze
    PROBE_METHODS = %i[>= > <= < <=> == != + - * / % coerce method_missing ! encoding [] encode to_s].freeze
    CLASS_OF = Object.instance_method(:class)
    SINGLETON_METHODS = Object.instance_method(:singleton_methods)
    PRIVATE_METHODS = Object.instance_method(:private_methods)

    module_function

    def pure?(value)
      klass = CLASS_OF.bind_call(value)
      TYPES.include?(klass) && SINGLETON_METHODS.bind_call(value).empty? &&
        !PRIVATE_METHODS.bind_call(value, false).intersect?(PROBE_METHODS) && core_ops_intact?(klass)
    end

    def core_ops_intact?(klass)
      PROBE_METHODS.all? do |name|
        next true unless klass.method_defined?(name) || klass.private_method_defined?(name)

        method = klass.instance_method(name)
        method.source_location.nil? && method.original_name == name
      end
    end

    def same?(left, right)
      klass = CLASS_OF.bind_call(left)
      return false unless klass == CLASS_OF.bind_call(right) && pure?(left) && pure?(right)
      return [left].pack("G") == [right].pack("G") if klass == Float
      return left.encoding == right.encoding && left == right if klass == String

      left == right
    end

    def sample(value)
      case CLASS_OF.bind_call(value).name
      when "String" then value[0, 32].encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      when "Symbol", "Rational" then value.to_s
      when "Float" then value < Float::INFINITY && value > -Float::INFINITY ? value : value.to_s
      else value
      end
    end
  end

  class Probe
    def initialize(site_table, samples: true)
      @site_table = site_table
      @record_samples = samples
      @reach = {}
      @infect = {}
      @samples = {}
      @load_reached = []
      @mutex = Mutex.new
    end

    def reach(site)
      test = R.current_test
      return if test && !@site_table.key?(site)

      @mutex.synchronize do
        record_reach(site, test)
        record_infection(site, test) if test
      end
    end

    def observe_bin(site, left, right, original, pure = true) # rubocop:disable Style/OptionalBooleanParameter
      variants = @site_table[site]
      test = R.current_test
      return if test && !variants

      @mutex.synchronize do
        record_reach(site, test)
        safe_operands = nil
        if variants && @record_samples && (@samples[site]&.size || 0) < 3
          safe_operands = Value.pure?(left) && Value.pure?(right)
          sample_operands(site, left, right) if safe_operands
        end
        return unless test

        variants.each.with_index(1) do |id, variant|
          next if @infect[id]&.include?(test)

          safe_operands = Value.pure?(left) && Value.pure?(right) if pure && safe_operands.nil?
          same = pure && safe_operands && begin
            Value.same?(original, yield(variant))
          rescue StandardError
            false
          end
          record(@infect, id, test) unless same
        end
      end
    end

    def observe_ret(site, value)
      test = R.current_test
      return if test && !@site_table.key?(site)

      @mutex.synchronize do
        record_reach(site, test)
        record_infection(site, test) if test && Value::CLASS_OF.bind_call(value) != NilClass
      end
    end

    def snapshot
      @mutex.synchronize do
        { "reach" => @reach.transform_values(&:dup), "infect" => @infect.transform_values(&:dup),
          "samples" => @samples.transform_values { |pairs| pairs.map(&:dup) }, "load_reached" => @load_reached.dup }
      end
    end

    private

    def record_reach(site, test)
      if test
        record(@reach, site, test)
      else
        @load_reached << site unless @load_reached.include?(site)
      end
    end

    def record_infection(site, test)
      @site_table.fetch(site).each { |id| record(@infect, id, test) }
    end

    def record(table, key, test)
      entries = (table[key] ||= [])
      entries << test unless entries.include?(test)
    end

    def sample_operands(site, left, right)
      pairs = (@samples[site] ||= [])
      pair = [Value.sample(left), Value.sample(right)]
      pairs << pair unless pairs.include?(pair)
    end
  end

  module R
    class << self
      attr_accessor :probe

      def configure(site_table, samples: true)
        reset
        @site_table = site_table
        @samples = samples
      end

      def reset
        @active_site = nil
        @active_variant = 0
        @probe = nil
        self.current_test = nil
      end

      def current_test
        Thread.current.thread_variable_get(:ripr_current_test)
      end

      def current_test=(test)
        Thread.current.thread_variable_set(:ripr_current_test, test)
      end

      def activate(site, variant)
        @active_site = site
        @active_variant = variant
      end

      def bin(site, left, right, pure = true) # rubocop:disable Style/OptionalBooleanParameter
        if (probe = @probe)
          original = begin
            yield(left, right, 0)
          rescue Exception # rubocop:disable Lint/RescueException -- Record caught test exceptions without changing their propagation.
            probe.reach(site)
            raise
          end
          probe.observe_bin(site, left, right, original, pure) { |variant| yield(left, right, variant) }
          original
        else
          yield(left, right, site == @active_site ? @active_variant : 0)
        end
      end

      def lit(site, *values)
        @probe&.reach(site)
        values[site == @active_site ? @active_variant : 0]
      end

      def cond(site, value)
        @probe&.reach(site)
        site == @active_site ? !value : value
      end

      def ret(site, value)
        @probe&.observe_ret(site, value)
        site == @active_site ? nil : value
      end

      def on?(site)
        @probe&.reach(site)
        site == @active_site
      end
    end
  end
end
