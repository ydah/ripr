# frozen_string_literal: true

require "io/wait"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "ripr/engine/child" if File.file?(File.expand_path("../lib/ripr/engine/child.rb", __dir__))
require "ripr/core/classifier" if File.file?(File.expand_path("../lib/ripr/core/classifier.rb", __dir__))

RSpec.describe "mutation execution" do
  def run_worker_program(code)
    lib = File.expand_path("../lib", __dir__)
    Open3.capture3(RbConfig.ruby, "-I", lib, "-rripr/engine/child", "-e", code)
  end

  it "reports worker progress from the parent as each task finishes" do
    updates = []
    parent = Process.pid
    results = Ripr::Engine::Child.batch([1, 2], jobs: 2, timeout: ->(_) { 1000 },
                                                on_complete: ->(done, total) { updates << [Process.pid, done, total] }) do |task|
      { "value" => task }
    end
    expect(results.to_h).to eq(1 => { "value" => 1 }, 2 => { "value" => 2 })
    expect(updates).to eq([[parent, 0, 2], [parent, 1, 2], [parent, 2, 2]])
  end

  it "reports each result and its wall time in milliseconds from the parent" do
    parent = Process.pid
    reports = []
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    report = lambda do |task, payload, milliseconds|
      finished = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      reports << [Process.pid, task, payload, milliseconds, finished - started]
    end
    results = Ripr::Engine::Child.batch(%i[first second], jobs: 2, timeout: ->(_) { 1000 }, on_result: report) do |task|
      before = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      sleep 0.02
      after = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      { "task" => task.to_s, "elapsed" => after - before }
    end

    expect(reports.map { |pid, task, payload, _, _| [pid, task, payload] })
      .to eq(results.map { |task, payload| [parent, task, payload] })
    reports.each do |_, _, payload, milliseconds, upper_bound|
      expect(milliseconds).to be_between(payload.fetch("elapsed"), upper_bound)
    end
  end

  it "isolates state and drains results larger than a pipe buffer" do
    result = Ripr::Engine::Child.call(timeout_ms: 1000) { { "value" => "x" * 200_000 } }
    expect(result.fetch("value").size).to eq(200_000)
  end

  it "assigns each concurrent worker a distinct database slot and reuses slots for pending tasks" do
    tasks = [1, 2, 3, 4].freeze
    result = Ripr::Engine::Child.batch(tasks, jobs: 2, timeout: ->(_) { 1000 }) do |_task, slot|
      { "slot" => slot }
    end
    slots = result.to_h.transform_values { |outcome| outcome.fetch("slot") }
    expect(slots.keys).to match_array(tasks)
    expect(slots.values_at(1, 2)).to contain_exactly(0, 1)
    expect(slots.values_at(3, 4)).to all(be_between(0, 1))
  end

  it "stops and reaps a timed-out worker before it can finish" do
    Dir.mktmpdir do |directory|
      worker_pid = File.join(directory, "worker.pid")
      finished = File.join(directory, "finished")
      result = Ripr::Engine::Child.call(timeout_ms: 200) do
        File.write(worker_pid, Process.pid.to_s)
        sleep 1
        File.write(finished, "finished")
        { "success" => true }
      end

      expect(result).to eq("status" => "timeout")
      expect(File.exist?(finished)).to be(false)
      expect { Process.waitpid(Integer(File.read(worker_pid))) }.to raise_error(Errno::ECHILD)
    end
  end

  it "stops a timed-out worker after its test joins another process group" do
    parent_group = Process.getpgrp
    Dir.mktmpdir do |directory|
      worker_pid = File.join(directory, "worker.pid")
      finished = File.join(directory, "finished")
      result = Ripr::Engine::Child.call(timeout_ms: 500) do
        Process.setpgid(0, parent_group)
        File.write(worker_pid, Process.pid.to_s)
        sleep 2
        File.write(finished, "finished")
        { "success" => true }
      end

      expect(result).to eq("status" => "timeout")
      expect(File.exist?(finished)).to be(false)
      expect { Process.waitpid(Integer(File.read(worker_pid))) }.to raise_error(Errno::ECHILD)
    end
  end

  it "reports why a worker failed to return an object" do
    abrupt = Ripr::Engine::Child.call(timeout_ms: 1000) { exit! 9 }
    array = Ripr::Engine::Child.call(timeout_ms: 1000) { [1, 2] }
    expect(abrupt).to eq("status" => "error", "error" => "child exited without a valid result")
    expect(array).to eq("status" => "error", "error" => "child returned a non-object result")
  end

  it "converts a worker's SystemExit to a structured result with its explanation" do
    result = Ripr::Engine::Child.call(timeout_ms: 1000) { raise SystemExit.new(9, "worker requested shutdown") }
    expect(result).to eq("status" => "error", "error" => "SystemExit: worker requested shutdown")
  end

  it "keeps worker output separate from the parent's report and diagnostics" do
    code = <<~RUBY
      result = Ripr::Engine::Child.call(timeout_ms: 1000) do
        $stdout.puts("worker stdout")
        $stdout.flush
        $stderr.puts("worker stderr")
        $stderr.flush
        { "answer" => 42 }
      end
      puts JSON.generate(result)
      warn "parent diagnostic"
    RUBY
    output, error, status = run_worker_program(code)
    expect(status).to be_success
    expect(JSON.parse(output)).to eq("answer" => 42)
    expect(error).to eq("parent diagnostic\n")
  end

  it "releases worker pipes after successful and interrupted batches without waiting for garbage collection" do
    code = <<~RUBY
      descriptors = -> { Dir.children("/dev/fd").size }
      GC.disable
      before = descriptors.call
      3.times { Ripr::Engine::Child.call(timeout_ms: 1000) { {} } }
      after_completion = descriptors.call
      timeout = ->(task) { task == :first ? 1000 : (raise ArgumentError, "invalid timeout") }
      begin
        Ripr::Engine::Child.batch(%i[first second], jobs: 2, timeout: timeout) do
          sleep 0.5
          {}
        end
      rescue ArgumentError
        after_interruption = descriptors.call
      end
      puts JSON.generate([after_completion - before, after_interruption - after_completion])
    RUBY
    output, error, status = run_worker_program(code)
    expect(status).to be_success, error
    expect(JSON.parse(output)).to eq([0, 0])
  end

  it "stops and reaps running workers if a later task cannot be scheduled" do
    Dir.mktmpdir do |directory|
      finished = File.join(directory, "finished")
      IO.pipe do |reader, writer|
        pid = nil
        timeout = lambda do |task|
          next 1500 if task == :first

          raise "first worker did not start" unless reader.wait_readable(1)

          pid = Integer(reader.gets)
          raise ArgumentError, "invalid timeout for second task"
        end
        expect do
          Ripr::Engine::Child.batch(%i[first second], jobs: 2, timeout: timeout) do
            writer.puts(Process.pid)
            writer.flush
            sleep 1
            File.write(finished, "finished")
            {}
          end
        end.to raise_error(ArgumentError, "invalid timeout for second task")
        expect(File.exist?(finished)).to be(false)
        expect { Process.waitpid(pid) }.to raise_error(Errno::ECHILD)
      end
    end
  end

  it "counts survivors and errors in the score denominator" do
    statuses = %w[killed timeout not_reached not_infected not_detected not_propagated not_revealed error accepted invalid static]
    results = statuses.map { |status| { "status" => status } }
    summary = Ripr::Core::Classifier.summary(results)
    expect(summary.fetch("score")).to eq(25.0)
    expect(summary.fetch("survived")).to eq(5)
  end

  it "collects a completed worker and stops its grandchild even when it holds the pipe open" do
    IO.pipe do |reader, writer|
      result = Ripr::Engine::Child.call(timeout_ms: 1000) do
        fork do
          sleep 2
          writer.write("grandchild is still running")
          exit! 0
        end
        { "success" => true }
      end
      writer.close
      expect(result).to eq("success" => true)
      expect(reader.wait_readable(1)).to eq(reader)
      expect(reader.read).to eq("")
    end
  end
end
