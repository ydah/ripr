# frozen_string_literal: true

require_relative "../runtime"

module Ripr
  module Engine
    class ImplicitReturns
      MAX_RETURNS = 4096
      MAX_OBSERVATIONS = 4096
      MAX_CLASS_NAME_BYTES = 256
      ENCODE = String.instance_method(:encode)
      BYTESIZE = String.instance_method(:bytesize)

      def self.site(mutant)
        return unless mutant.fetch("operator") == "return_nil"

        site = mutant.fetch("site")
        site if site.end_with?("::body.return::return_nil")
      end

      def self.observe(sites, tests, &)
        return [yield, {}] if sites.empty?

        observer = new(sites, tests)
        result = R.with_return_observer(observer, &)
        [result, observer.finish]
      end

      def self.stable(first, second)
        first.each_with_object({}) do |(site, tests), retained|
          matches = tests.select do |test, prefix|
            prefix[1].is_a?(String) && prefix == second.dig(site, test)
          end
          retained[site] = matches unless matches.empty?
        end
      end

      def self.compare(original, mutant, tests)
        return unless original && mutant

        tests.each do |test|
          prefix = original[test]
          next unless prefix && mutant[test]

          ordinal = prefix[0] + 1
          next if mutant.fetch(test)[0] < ordinal

          return { "status" => "not_revealed",
                   "propagation" => { "test_id" => test, "call" => ordinal, "observation" => "implicit_return",
                                      "original" => ["return_type", prefix[1]], "mutant" => ["return", ["NilClass", nil]] } }
        end
        nil
      end

      def initialize(sites, tests)
        @sites = sites.to_h { |site| [site, true] }
        @tests = tests.to_h { |test| [test, true] }
        @observations = {}
        @remaining = MAX_OBSERVATIONS
        @lock = Mutex.new
      end

      def call(site, value)
        test = R.current_test
        return unless @sites.key?(site) && @tests.key?(test)

        @lock.synchronize do
          return if @finished

          prefix = @observations.dig(site, test)
          unless prefix
            return if @remaining.zero?

            @remaining -= 1
            prefix = (@observations[site] ||= {})[test] = [0, nil]
          end
          return unless prefix[1].nil? && prefix[0] < MAX_RETURNS

          if Value::IDENTITY.bind_call(value, nil)
            prefix[0] += 1
          else
            prefix[1] = class_name(value) || false
          end
        end
      end

      def finish
        @lock.synchronize do
          @finished = true
          @observations
        end
      end

      private

      def class_name(value)
        name = Value::NAME.bind_call(Value::CLASS_OF.bind_call(value))
        return unless name && BYTESIZE.bind_call(name) <= MAX_CLASS_NAME_BYTES

        name = ENCODE.bind_call(name, Encoding::UTF_8)
        name if BYTESIZE.bind_call(name) <= MAX_CLASS_NAME_BYTES
      rescue TypeError, EncodingError
        nil
      end
    end
  end
end
