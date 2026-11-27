# frozen_string_literal: true

module Ripr
  module Value
    TYPES = [Integer, Float, Rational, String, Symbol, NilClass, TrueClass, FalseClass].freeze
    PROBE_METHODS = %i[>= > <= < <=> == != + - * / % coerce method_missing ! encoding [] encode to_s].freeze
    CLASS_OF = Object.instance_method(:class)
    SINGLETON_CLASS = Object.instance_method(:singleton_class)
    SINGLETON_METHODS = Object.instance_method(:singleton_methods)
    PRIVATE_METHODS = Object.instance_method(:private_methods)
    PRIVATE_INSTANCE_METHODS = Module.instance_method(:private_instance_methods)
    INSTANCE_METHOD = Module.instance_method(:instance_method)
    PUBLIC_METHOD = Module.instance_method(:method_defined?)
    PRIVATE_METHOD = Module.instance_method(:private_method_defined?)
    SUPERCLASS = Class.instance_method(:superclass)
    IDENTITY = BasicObject.instance_method(:equal?)
    NAME = Module.instance_method(:name)
    FROZEN = Object.instance_method(:frozen?)
    FREEZE = Object.instance_method(:freeze)
    ARRAY_SIZE = Array.instance_method(:size)
    ARRAY_AT = Array.instance_method(:[])
    ARRAY_PUSH = Array.instance_method(:<<)
    ARRAY_PACK = Array.instance_method(:pack)
    STRING_EQ = String.instance_method(:==)
    INTEGER_EQ = Integer.instance_method(:==)
    FLOAT_NAN = Float.instance_method(:nan?)
    HASH_IDENTITY = Hash.instance_method(:compare_by_identity)
    HASH_KEY = Hash.instance_method(:key?)
    HASH_SET = Hash.instance_method(:[]=)
    ARRAY_COPY_OPS = %i[+ -].to_h { |name| [name, INSTANCE_METHOD.bind_call(Array, name)] }.freeze
    INTERNAL_ACCESSORS = {
      unpack1: "<internal:pack>", to_s: "<internal:symbol>", bit_length: "<internal:numeric>", frozen?: "<internal:kernel>"
    }.freeze
    PAYLOAD_ACCESSORS = {
      Array => %i[each size []], Hash => %i[each_pair size compare_by_identity? default default_proc],
      Range => %i[begin end exclude_end?], Data => %i[members deconstruct],
      String => %i[bytesize unpack1 encoding], Symbol => %i[to_s], Integer => %i[bit_length],
      Rational => %i[numerator denominator]
    }.to_h do |klass, names|
      [klass, names.to_h { |name| [name, INSTANCE_METHOD.bind_call(klass, name)] }.freeze]
    end.freeze
    VALUE_METHODS = %i[== != eql? hash <=> to_ary to_hash respond_to_missing? method_missing frozen?].freeze
    VALUE_COMPARATORS = [*TYPES, Array, Hash, Range, Data].to_h do |klass|
      methods = VALUE_METHODS.to_h do |name|
        method = INSTANCE_METHOD.bind_call(klass, name) if PUBLIC_METHOD.bind_call(klass, name) || PRIVATE_METHOD.bind_call(klass, name)
        [name, method]
      end
      [klass, methods.freeze]
    end.freeze

    module_function

    def scalar?(value)
      klass = CLASS_OF.bind_call(value)
      TYPES.include?(klass) && SINGLETON_METHODS.bind_call(value).empty? &&
        !PRIVATE_METHODS.bind_call(value, false).intersect?(PROBE_METHODS) && core_ops_intact?(klass)
    end

    def pure?(value)
      TYPES.include?(CLASS_OF.bind_call(value)) ? scalar?(value) : !snapshot(value).nil?
    end

    def core_ops_intact?(klass)
      PROBE_METHODS.all? do |name|
        next true unless klass.method_defined?(name) || klass.private_method_defined?(name)

        method = klass.instance_method(name)
        method.source_location.nil? && method.original_name == name
      end
    end

    def same?(left, right)
      return same_scalar?(left, right) if TYPES.include?(CLASS_OF.bind_call(left))

      a = snapshot(left)
      b = snapshot(right) if a
      a && b ? same_token?(a, b) : false
    end

    def same_scalar?(left, right)
      klass = CLASS_OF.bind_call(left)
      return false unless IDENTITY.bind_call(klass, CLASS_OF.bind_call(right)) && scalar?(left) && scalar?(right)
      return ARRAY_PACK.bind_call([left], "G") == ARRAY_PACK.bind_call([right], "G") if klass == Float
      return left.encoding == right.encoding && left == right if klass == String

      left == right
    end

    def snapshot(value)
      Snapshot.new.call(value)
    rescue TypeError, RuntimeError
      nil
    end

    def array_copy_operands?(left, right)
      return false unless RUBY_ENGINE == "ruby"
      return false unless IDENTITY.bind_call(CLASS_OF.bind_call(left), Array) && IDENTITY.bind_call(CLASS_OF.bind_call(right), Array)
      return false unless methods_match?(Array, PAYLOAD_ACCESSORS.fetch(Array))

      ARRAY_SIZE.bind_call(right).zero? && methods_match?(SINGLETON_CLASS.bind_call(left), ARRAY_COPY_OPS)
    end

    def empty_array_copy?(left, right, result)
      return false unless IDENTITY.bind_call(CLASS_OF.bind_call(result), Array) && array_copy_operands?(left, right)
      return false unless snapshot(left) && snapshot(right) && snapshot(result) && !FROZEN.bind_call(result)
      return false if IDENTITY.bind_call(left, result) || IDENTITY.bind_call(right, result)

      # CRuby's native + and - with an empty right operand both return fresh shallow copies.
      size = ARRAY_SIZE.bind_call(left)
      size == ARRAY_SIZE.bind_call(result) && size.times.all? do |index|
        IDENTITY.bind_call(ARRAY_AT.bind_call(left, index), ARRAY_AT.bind_call(result, index))
      end
    end

    def methods_match?(klass, expected)
      expected.all? do |name, method|
        next !PUBLIC_METHOD.bind_call(klass, name) && !PRIVATE_METHOD.bind_call(klass, name) unless method

        location = method.source_location
        method.original_name == name && (location.nil? || location.first == INTERNAL_ACCESSORS[name]) &&
          INSTANCE_METHOD.bind_call(klass, name) == method
      end
    rescue NameError
      false
    end

    def same_token?(left, right)
      return true if IDENTITY.bind_call(left, right)

      klass = CLASS_OF.bind_call(left)
      return false unless IDENTITY.bind_call(klass, CLASS_OF.bind_call(right))
      return STRING_EQ.bind_call(left, right) if IDENTITY.bind_call(klass, String)
      return INTEGER_EQ.bind_call(left, right) if IDENTITY.bind_call(klass, Integer)
      return false unless IDENTITY.bind_call(klass, Array)

      size = ARRAY_SIZE.bind_call(left)
      size == ARRAY_SIZE.bind_call(right) && size.times.all? do |index|
        same_token?(ARRAY_AT.bind_call(left, index), ARRAY_AT.bind_call(right, index))
      end
    end
    private_class_method :same_token?

    def sample(value)
      case NAME.bind_call(CLASS_OF.bind_call(value))
      when "String" then value[0, 32].encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      when "Symbol", "Rational" then value.to_s
      when "Float" then value < Float::INFINITY && value > -Float::INFINITY ? value : value.to_s
      else value
      end
    end

    class Snapshot
      MAX_DEPTH = 4
      MAX_ITEMS = 32
      MAX_NODES = 128
      MAX_BYTES = 1_024
      INSTANCE_VARIABLES = Object.instance_method(:instance_variables)
      INSTANCE_ID = BasicObject.instance_method(:__id__)
      ENCODING_NAME = Encoding.instance_method(:name)

      def call(value)
        @remaining = MAX_NODES
        @seen = HASH_IDENTITY.bind_call({})
        catch(:ripr_unknown_value) { encode(value, 0) }
      end

      private

      def encode(value, depth)
        @remaining -= 1
        unknown if depth > MAX_DEPTH || @remaining.negative?

        klass = CLASS_OF.bind_call(value)
        return scalar(value, klass) if TYPES.include?(klass)

        owner = [Array, Hash, Range].find { |type| IDENTITY.bind_call(klass, type) }
        owner ||= Data if IDENTITY.bind_call(SUPERCLASS.bind_call(klass), Data)
        unknown unless owner && Value.methods_match?(klass, VALUE_COMPARATORS.fetch(owner))
        unknown unless plain?(value, klass, owner)
        unknown unless Value.methods_match?(klass, PAYLOAD_ACCESSORS.fetch(owner))

        track(value)
        token(kind(value, owner), FROZEN.bind_call(value), contents(value, owner, depth + 1))
      end

      def plain?(value, klass, owner)
        return false unless SINGLETON_METHODS.bind_call(value).empty? && INSTANCE_VARIABLES.bind_call(value).empty?

        singleton = SINGLETON_CLASS.bind_call(value)
        return false unless PRIVATE_INSTANCE_METHODS.bind_call(singleton, false).empty?

        Value.methods_match?(singleton, VALUE_COMPARATORS.fetch(owner))
      rescue TypeError
        IDENTITY.bind_call(klass, String) && FROZEN.bind_call(value)
      end

      def method_for(klass, name)
        INSTANCE_METHOD.bind_call(klass, name)
      rescue NameError
        nil
      end

      def track(value)
        unknown if HASH_KEY.bind_call(@seen, value)

        HASH_SET.bind_call(@seen, value, true)
      end

      def scalar(value, klass)
        unknown unless Value.methods_match?(klass, VALUE_COMPARATORS.fetch(klass))
        accessors = PAYLOAD_ACCESSORS[klass]
        unknown if accessors && !Value.methods_match?(klass, accessors)

        case NAME.bind_call(klass)
        when "String"
          unknown unless plain?(value, klass, String)

          track(value)
          token("String", FROZEN.bind_call(value), string(value))
        when "Symbol" then token("Symbol", string(access(Symbol, :to_s, value)))
        when "Float" then token("Float", string(ARRAY_PACK.bind_call([value], "G")))
        when "Rational"
          token("Rational", integer(access(Rational, :numerator, value)), integer(access(Rational, :denominator, value)))
        when "Integer" then token("Integer", integer(value))
        else token(FREEZE.bind_call(NAME.bind_call(klass)), value)
        end
      end

      def integer(value)
        unknown if access(Integer, :bit_length, value) > MAX_BYTES * 8

        value
      end

      def string(value)
        unknown if access(String, :bytesize, value) > MAX_BYTES

        encoding = access(String, :encoding, value)
        token(FREEZE.bind_call(ENCODING_NAME.bind_call(encoding)), FREEZE.bind_call(access(String, :unpack1, value, "H*")))
      end

      def kind(value, owner)
        return FREEZE.bind_call(NAME.bind_call(owner)) unless IDENTITY.bind_call(owner, Data)

        klass = CLASS_OF.bind_call(value)
        token("Data", FREEZE.bind_call(NAME.bind_call(klass)), INSTANCE_ID.bind_call(klass))
      end

      def contents(value, owner, depth)
        case NAME.bind_call(owner)
        when "Array"
          unknown if access(Array, :size, value) > MAX_ITEMS

          items = []
          access(Array, :each, value) { |item| ARRAY_PUSH.bind_call(items, encode(item, depth)) }
          FREEZE.bind_call(items)
        when "Hash"
          hash_contents(value, depth)
        when "Range"
          token(access(Range, :exclude_end?, value), encode(access(Range, :begin, value), depth), encode(access(Range, :end, value), depth))
        when "Data"
          data_contents(value, depth)
        end
      end

      def hash_contents(value, depth)
        unknown if access(Hash, :size, value) > MAX_ITEMS
        unknown if access(Hash, :compare_by_identity?, value) || access(Hash, :default_proc, value)

        items = [encode(access(Hash, :default, value), depth)]
        access(Hash, :each_pair, value) do |key, item|
          klass = CLASS_OF.bind_call(key)
          unknown unless TYPES.include?(klass)
          unknown if (klass == String && !FROZEN.bind_call(key)) || (klass == Float && FLOAT_NAN.bind_call(key))

          ARRAY_PUSH.bind_call(items, token(encode(key, depth), encode(item, depth)))
        end
        FREEZE.bind_call(items)
      end

      def data_contents(value, depth)
        members = access(Data, :members, value)
        klass = CLASS_OF.bind_call(value)
        unknown if members.size > MAX_ITEMS || !members.all? do |name|
          method = method_for(klass, name)
          method && IDENTITY.bind_call(method.owner, klass) && method.source_location.nil? && method.original_name == name
        end

        FREEZE.bind_call(access(Data, :deconstruct, value).map { |item| encode(item, depth) })
      end

      def access(owner, name, value, *, &)
        PAYLOAD_ACCESSORS.fetch(owner).fetch(name).bind_call(value, *, &)
      end

      def token(*fields)
        FREEZE.bind_call(fields)
      end

      def unknown
        throw :ripr_unknown_value
      end
    end
    private_constant :Snapshot
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

    def observe_bin(site, left, right, original, pure = true, array_copy = false) # rubocop:disable Style/OptionalBooleanParameter
      variants = @site_table[site]
      test = R.current_test
      return if test && !variants

      @mutex.synchronize do
        record_reach(site, test)
        safe_operands = nil
        if variants && @record_samples && (@samples[site]&.size || 0) < 3
          safe_operands = Value.scalar?(left) && Value.scalar?(right)
          sample_operands(site, left, right) if safe_operands
        end
        return unless test

        variants.each.with_index(1) do |id, variant|
          next if @infect[id]&.include?(test)

          safe_operands = Value.scalar?(left) && Value.scalar?(right) if pure && safe_operands.nil?
          same = pure && begin
            if safe_operands
              Value.same_scalar?(original, yield(variant))
            elsif array_copy
              Value.empty_array_copy?(left, right, original)
            end
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
      pair = [Value::FREEZE.bind_call(Value.sample(left)), Value::FREEZE.bind_call(Value.sample(right))]
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
        @return_observer = nil
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

      def with_return_observer(observer)
        previous = @return_observer
        @return_observer = observer
        yield
      ensure
        @return_observer = previous
      end

      def bin(site, left, right, pure = true, array_copy = false) # rubocop:disable Style/OptionalBooleanParameter
        if (probe = @probe)
          array_copy = array_copy && pure && Value.array_copy_operands?(left, right)
          original = begin
            yield(left, right, 0)
          rescue Exception # rubocop:disable Lint/RescueException -- Record caught test exceptions without changing their propagation.
            probe.reach(site)
            raise
          end
          probe.observe_bin(site, left, right, original, pure, array_copy) { |variant| yield(left, right, variant) }
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
        result = site == @active_site ? nil : value
        @return_observer&.call(site, result)
        result
      end

      def on?(site)
        @probe&.reach(site)
        site == @active_site
      end
    end
  end
end
