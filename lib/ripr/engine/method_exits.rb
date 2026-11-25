# frozen_string_literal: true

require "English"
require "json"
require_relative "../runtime"

module Ripr
  module Engine
    class MethodExits
      MAX_CALLS_PER_TEST = 32
      MAX_CALLS_PER_SUBJECT = 256
      MAX_TOTAL_CALLS = 4_096
      MAX_EXIT_BYTES = 8_192
      AMBIGUOUS_EXIT = ["ambiguous_exit"].freeze
      NOT_CALLED = ["not_called"].freeze
      UNKNOWN_EXIT = ["unknown"].freeze
      EXCEPTION_NAMES = [ArgumentError, EOFError, EncodingError, Exception, FiberError, FloatDomainError,
                         FrozenError, IndexError, IOError, KeyError, LoadError, LocalJumpError, NameError,
                         NoMethodError, NotImplementedError, RangeError, RuntimeError, ScriptError, StandardError,
                         StopIteration, SyntaxError, SystemCallError, SystemExit, SystemStackError, ThreadError,
                         TypeError, ZeroDivisionError].each_with_object({}.compare_by_identity) do |klass, names|
        names[klass] = klass.name.freeze
      end.freeze
      CONSTANT_DEFINED = Module.instance_method(:const_defined?)
      CONSTANT_AUTOLOAD = Module.instance_method(:autoload?)
      CONSTANT_LOOKUP = Module.instance_method(:const_get)
      MODULE_NAME = Module.instance_method(:name)
      IS_A = Object.instance_method(:is_a?)
      SINGLETON_CLASS = Object.instance_method(:singleton_class)
      METHOD_LOOKUP = Module.instance_method(:instance_method)
      METHOD_OWNER = UnboundMethod.instance_method(:owner)
      METHOD_NAME = UnboundMethod.instance_method(:name)
      METHOD_ORIGINAL_NAME = UnboundMethod.instance_method(:original_name)
      METHOD_SOURCE = UnboundMethod.instance_method(:source_location)
      METHOD_BIND = UnboundMethod.instance_method(:bind)
      UNBIND = Method.instance_method(:unbind)
      PUBLIC_METHOD = Module.instance_method(:public_method_defined?)

      Subject = Struct.new(:target, :calls, :call_count, :iseq)
      Frame = Struct.new(:subject, :test, :calls, :index, :ambient_exception, :raised)
      Raised = Struct.new(:exception, :exits)
      private_constant :Subject, :Frame, :Raised

      def self.targets(mutants)
        groups = mutants.reject(&:static).group_by { |mutant| mutant.subject.sub(/\[\d+\]\z/, "") }
        groups.each_with_object({}) do |(subject, entries), targets|
          next unless entries.all? { |mutant| mutant.subject == subject }

          definitions = entries.uniq { |mutant| [mutant.location.file, mutant.method_start, mutant.method_end, mutant.method_hash] }
          next unless definitions.one?

          target = resolve_target(definitions.first)
          targets[subject] = target if target
        end.freeze
      end

      def self.public_subjects(targets)
        targets.filter_map do |subject, target|
          method = target.is_a?(Method) ? UNBIND.bind_call(target) : target
          [subject, true] if PUBLIC_METHOD.bind_call(METHOD_OWNER.bind_call(method), METHOD_NAME.bind_call(method), false)
        end.to_h.freeze
      end

      def self.resolve_target(mutant)
        owner_name, method_name = mutant.subject.split(/[.#]/, 2)
        return if method_name.nil? || method_name.empty?

        owner = loaded_owner(owner_name)
        return unless owner

        singleton = mutant.subject[owner_name.length] == "."
        declared_owner = singleton ? SINGLETON_CLASS.bind_call(owner) : owner
        target = METHOD_LOOKUP.bind_call(declared_owner, method_name)
        return unless Value::IDENTITY.bind_call(METHOD_OWNER.bind_call(target), declared_owner)
        return unless METHOD_NAME.bind_call(target) == METHOD_ORIGINAL_NAME.bind_call(target)

        path, line = METHOD_SOURCE.bind_call(target)
        return unless path && line == mutant.method_start && File.realpath(path) == File.realpath(mutant.location.file)

        iseq = RubyVM::InstructionSequence.of(target)
        return unless iseq && iseq.label == iseq.base_label

        singleton ? METHOD_BIND.bind_call(target, owner) : target
      rescue NameError, SystemCallError
        nil
      end

      def self.loaded_owner(name)
        owner = name.split("::").reduce(Object) do |namespace, part|
          break unless CONSTANT_DEFINED.bind_call(namespace, part, false) && !CONSTANT_AUTOLOAD.bind_call(namespace, part, false)

          value = CONSTANT_LOOKUP.bind_call(namespace, part, false)
          break unless IS_A.bind_call(value, Module)

          value
        end
        owner if owner && MODULE_NAME.bind_call(owner) == name
      end
      private_class_method :resolve_target, :loaded_owner

      def self.observe(targets, &)
        return [yield, {}.freeze] if targets.empty?

        new(targets).observe(&)
      end

      def self.stable(first, second)
        first.select do |subject, calls|
          calls && !calls.empty? && calls == second[subject] && calls.values.all? do |observations|
            observations.all? { |exit| exit && exit != AMBIGUOUS_EXIT }
          end
        end.freeze
      end

      def self.compare(original, mutant, test_ids)
        return unless original && mutant && !test_ids.empty?

        comparable = true
        test_ids.each do |test|
          before = original[test]
          after = mutant[test]
          unless before && after
            comparable = false
            next
          end

          shared_calls = [before.size, after.size].min
          shared_calls.times do |index|
            a = before[index]
            b = after[index]
            if a && b && (b != AMBIGUOUS_EXIT || a.first == "return")
              return revealed(test, index, a, b) if a != b
            else
              comparable = false
            end
          end
          next if before.size == after.size

          a = before.fetch(shared_calls, NOT_CALLED) || UNKNOWN_EXIT
          b = after.fetch(shared_calls, NOT_CALLED) || UNKNOWN_EXIT
          return revealed(test, shared_calls, a, b)
        end
        { "status" => "not_propagated" } if comparable
      end

      def self.revealed(test, index, original, mutant)
        propagation = { "test_id" => test, "call" => index + 1, "original" => original, "mutant" => mutant }
        { "status" => "not_revealed", "propagation" => propagation }
      end
      private_class_method :revealed

      def initialize(targets)
        @subjects = targets.transform_values { |target| Subject.new(target, {}, 0) }
        @frames = {}.compare_by_identity
        @raised = {}.compare_by_identity
        @calls_remaining = MAX_TOTAL_CALLS
        @mutex = Mutex.new
      end

      def observe(&)
        traces = @subjects.values.filter_map { |subject| attach(subject) }
        value = if traces.empty?
                  yield
                else
                  TracePoint.new(:raise, :rescue) { |event| @mutex.synchronize { observe_exception(event) } }.enable(&)
                end
        [value, observations]
      ensure
        traces&.reverse_each(&:disable)
      end

      private

      def attach(subject)
        target = subject.target
        iseq = RubyVM::InstructionSequence.of(target) if target.is_a?(Method) || target.is_a?(UnboundMethod)
        unless iseq && iseq.label == iseq.base_label && target.name == target.original_name
          subject.calls = nil
          return
        end

        subject.iseq = iseq
        name = target.name
        owner = target.owner
        trace = TracePoint.new(:call, :return) do |event|
          next unless event.method_id == name && Value::IDENTITY.bind_call(event.defined_class, owner)

          @mutex.synchronize do
            if event.event == :call
              enter(subject)
            else
              leave(subject, event.return_value)
            end
          end
        end
        trace.enable(target:)
        trace
      rescue ArgumentError, TypeError
        subject.calls = nil
        nil
      end

      def observations
        @subjects.transform_values do |subject|
          next unless subject.calls && still_defined?(subject)

          subject.calls.transform_values(&:freeze).freeze
        end.freeze
      end

      def still_defined?(subject)
        target = subject.target
        iseq = RubyVM::InstructionSequence.of(METHOD_LOOKUP.bind_call(target.owner, target.name))
        Value::IDENTITY.bind_call(iseq, subject.iseq)
      rescue NameError
        false
      end

      def enter(subject)
        return unless subject.calls

        test = R.current_test
        if !test || @calls_remaining.zero? || subject.call_count >= MAX_CALLS_PER_SUBJECT
          invalidate(subject)
          return
        end

        calls = (subject.calls[test] ||= [])
        if calls.size >= MAX_CALLS_PER_TEST
          invalidate(subject)
          return
        end

        (@frames[Fiber.current] ||= []) << Frame.new(subject, test, calls, calls.size, $ERROR_INFO)
        calls << nil
        subject.call_count += 1
        @calls_remaining -= 1
      end

      def leave(subject, value)
        return unless subject.calls

        fiber = Fiber.current
        stack = @frames[fiber]
        frame = stack&.last
        unless frame && Value::IDENTITY.bind_call(frame.subject, subject) && frame.test == R.current_test
          invalidate(subject)
          return
        end

        stack.pop
        @frames.delete(fiber) if stack.empty?
        if Value::IDENTITY.bind_call(value, nil)
          frame.calls[frame.index] = AMBIGUOUS_EXIT
          raised = @raised[fiber]
          raised.exits << frame if raised && Value::IDENTITY.bind_call(frame.raised, raised)
        else
          frame.calls[frame.index] = return_exit(value)
        end
      end

      def invalidate(subject)
        subject.calls = nil
        @frames.delete_if do |_fiber, frames|
          frames.reject! { |frame| Value::IDENTITY.bind_call(frame.subject, subject) }
          frames.empty?
        end
      end

      def observe_exception(event)
        fiber = Fiber.current
        exception = event.raised_exception
        if event.event == :raise
          @raised.delete(fiber)
          frames = @frames[fiber]
          return unless frames

          raised = Raised.new(exception, [])
          @raised[fiber] = raised
          frames.each do |frame|
            frame.raised = raised unless Value::IDENTITY.bind_call(frame.ambient_exception, exception)
          end
        elsif (raised = @raised[fiber]) && Value::IDENTITY.bind_call(raised.exception, exception)
          @raised.delete(fiber)
          name = EXCEPTION_NAMES[Value::CLASS_OF.bind_call(exception)]
          return unless name

          exit = ["raise", name].freeze
          raised.exits.each { |frame| frame.calls[frame.index] = exit if frame.test == R.current_test }
        end
      end

      def return_exit(value)
        snapshot = Value.snapshot(value)
        return unless snapshot && transferable?(snapshot)
        return if JSON.generate(snapshot).bytesize > MAX_EXIT_BYTES

        ["return", snapshot].freeze
      end

      def transferable?(snapshot)
        !snapshot.is_a?(Array) || (snapshot.first != "Data" && snapshot.all? { |part| transferable?(part) })
      end
    end
  end
end
