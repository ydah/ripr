# frozen_string_literal: true

module Ripr
  module Value
    TYPES = [Integer, Float, Rational, String, Symbol, NilClass, TrueClass, FalseClass].freeze
    OPERATORS = %i[>= > <= < == != + - * / % coerce ! encoding [] encode to_s].freeze
    CLASS_OF = Object.instance_method(:class)
    SINGLETON_METHODS = Object.instance_method(:singleton_methods)

    module_function

    def pure?(value)
      klass = CLASS_OF.bind_call(value)
      TYPES.include?(klass) && SINGLETON_METHODS.bind_call(value).empty? && core_ops_intact?(value)
    end

    def core_ops_intact?(*values)
      values.all? do |value|
        klass = CLASS_OF.bind_call(value)
        OPERATORS.all? do |operator|
          !klass.method_defined?(operator) || klass.instance_method(operator).source_location.nil?
        end
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
      @mutex.synchronize do
        record_reach(site)
        record_infection(site) if R.current_test
      end
    end

    def observe_bin(site, left, right, original, pure = true) # rubocop:disable Style/OptionalBooleanParameter
      @mutex.synchronize do
        record_reach(site)
        sample_operands(site, left, right)
        @site_table.fetch(site).each.with_index(1) do |id, variant|
          next if !R.current_test || @infect.fetch(id, []).include?(R.current_test)

          same = false
          if pure && Value.pure?(left) && Value.pure?(right)
            begin
              same = Value.same?(original, yield(variant))
            rescue StandardError
              same = false
            end
          end
          record(@infect, id, R.current_test) unless same
        end
      end
    end

    def observe_ret(site, value)
      @mutex.synchronize do
        record_reach(site)
        record_infection(site) unless Value::CLASS_OF.bind_call(value) == NilClass
      end
    end

    def snapshot
      @mutex.synchronize do
        { "reach" => @reach.transform_values(&:dup), "infect" => @infect.transform_values(&:dup),
          "samples" => @samples.transform_values { |pairs| pairs.map(&:dup) }, "load_reached" => @load_reached.dup }
      end
    end

    private

    def record_reach(site)
      if R.current_test
        record(@reach, site, R.current_test)
      else
        @load_reached << site unless @load_reached.include?(site)
      end
    end

    def record_infection(site)
      return unless R.current_test

      @site_table.fetch(site).each { |id| record(@infect, id, R.current_test) }
    end

    def record(table, key, test)
      entries = (table[key] ||= [])
      entries << test unless entries.include?(test)
    end

    def sample_operands(site, left, right)
      return unless @record_samples && Value.pure?(left) && Value.pure?(right)

      pairs = (@samples[site] ||= [])
      pair = [Value.sample(left), Value.sample(right)]
      pairs << pair if pairs.size < 3 && !pairs.include?(pair)
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
