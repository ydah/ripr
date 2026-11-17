# frozen_string_literal: true

require "json"

module Ripr
  module Engine
    module Child
      def self.call(timeout_ms:, &block)
        batch([nil], jobs: 1, timeout: ->(_) { timeout_ms }) { block.call }.first.last
      end

      def self.batch(tasks, jobs:, timeout:, on_complete: nil, &)
        pending = tasks.dup
        active = {}
        completed = []
        on_complete&.call(0, tasks.length)
        until pending.empty? && active.empty?
          while active.length < jobs && !pending.empty?
            task = pending.shift
            state = spawn_child(task, timeout.call(task), &)
            active[state.fetch(:reader)] = state
          end
          ready = IO.select(active.keys, nil, nil, 0.01)&.first || []
          ready.each { |reader| drain(active.fetch(reader)) }
          active.each_value.to_a.each do |state|
            state[:wait_status] ||= Process.waitpid2(state.fetch(:pid), Process::WNOHANG)&.last
            expired = monotonic >= state.fetch(:deadline)
            next unless expired || state[:wait_status]

            drain(state) if state[:wait_status] && !state[:eof]
            payload = state[:wait_status] ? decode(state.fetch(:buffer)) : { "status" => "timeout" }
            stop(state)
            Process.waitpid(state.fetch(:pid)) unless state[:wait_status]
            completed << [state.fetch(:task), payload]
            active.delete(state.fetch(:reader))
            state.fetch(:reader).close
            on_complete&.call(completed.length, tasks.length)
          end
        end
        completed
      ensure
        active&.each_value do |state|
          stop(state)
          begin
            Process.waitpid(state.fetch(:pid)) unless state[:wait_status]
          rescue Errno::ECHILD
            nil
          end
          state.fetch(:reader).close unless state.fetch(:reader).closed?
        end
      end

      def self.spawn_child(task, timeout_ms)
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          Process.setpgid(0, 0)
          $stdout.reopen(File::NULL, "w")
          $stderr.reopen(File::NULL, "w")
          payload = begin
            yield(task)
          rescue Exception => e # rubocop:disable Lint/RescueException -- Test code may raise SystemExit or a framework Exception subclass.
            { "status" => "error", "error" => "#{e.class}: #{e.message}" }
          end
          writer.write(JSON.generate(payload))
          writer.close
          exit! 0
        end
        writer.close
        { task: task, pid: pid, reader: reader, buffer: +"", deadline: monotonic + (timeout_ms / 1000.0) }
      end

      def self.drain(state)
        loop { state.fetch(:buffer) << state.fetch(:reader).read_nonblock(65_536) }
      rescue IO::WaitReadable
        nil
      rescue EOFError
        state[:eof] = true
      end

      def self.decode(buffer)
        value = JSON.parse(buffer)
        value.is_a?(Hash) ? value : { "status" => "error", "error" => "child returned a non-object result" }
      rescue JSON::ParserError
        { "status" => "error", "error" => "child exited without a valid result" }
      end

      def self.stop(state)
        Process.kill("KILL", -state.fetch(:pid))
      rescue Errno::ESRCH
        begin
          Process.kill("KILL", state.fetch(:pid))
        rescue StandardError
          nil
        end
      end

      def self.monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
