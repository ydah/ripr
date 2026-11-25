# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "end-to-end benchmark script" do
  it "rejects an over-budget return when timeout delivery was delayed" do
    Dir.mktmpdir("ripr-delayed-timeout") do |directory|
      File.write(File.join(directory, "source.rb"), "42\n")
      bootstrap = File.join(directory, "delayed-timeout.rb")
      File.write(bootstrap, <<~RUBY)
        require "timeout"
        module DelayedTimeout
          def timeout(*)
            yield
          end
        end
        Timeout.singleton_class.prepend(DelayedTimeout)
      RUBY
      code = 'sleep 0.1; puts %q({"summary":{"killed":1,"survived":0}})'
      command = [RbConfig.ruby, "-e", code]
      config = { "project" => "delayed", "tool" => "ripr", "directory" => directory,
                 "file" => "source.rb", "before" => "42", "after" => "(42)", "caches" => [],
                 "full" => command, "incremental" => command, "format" => "ripr", "timeout_seconds" => 0.02,
                 "env" => { "RUBYOPT" => [ENV.fetch("RUBYOPT", nil), "-r#{bootstrap}"].compact.join(" ") } }
      manifest = File.join(directory, "manifest.json")
      destination = File.join(directory, "results.json")
      File.write(manifest, JSON.generate([config]))
      script = File.expand_path("../script/compare_benchmarks.rb", __dir__)
      _output, error, status = Open3.capture3(config.fetch("env"), RbConfig.ruby, script, manifest, destination)
      expect(status.success?).to be(true), error
      result = JSON.parse(File.read(destination)).first
      expect(result.fetch("blocked")).to include("exceeded")
      expect(result.fetch("partial").fetch("seconds")).to be >= 0.1
      expect(result).not_to have_key("full_median_seconds")
      expect(File.read(File.join(directory, "comparison-logs/cold-0.stdout"))).to include('"killed":1')
      expect(File.read(File.join(directory, "source.rb"))).to eq("42\n")
    end
  end

  it "records three independent cold and edited pairs and restores the source" do
    Dir.mktmpdir("ripr-comparison") do |directory|
      source = "def answer; 42; end\n"
      File.write(File.join(directory, "source.rb"), source)
      code = <<~RUBY
        require "json"
        if File.read("source.rb").include?("(42)")
          raise "cold cache was not retained" unless File.read(".ripr/marker") == "cold"
          File.write(".ripr/marker", "edited")
        else
          raise "cache was not cleared before cold run" if File.exist?(".ripr")
          Dir.mkdir(".ripr")
          File.write(".ripr/marker", "cold")
        end
        File.open("invocations", "a") { |file| file.puts(File.read("source.rb").strip) }
        File.write(".ripr/profile.json", JSON.generate("schema" => "ripr.profile/v1", "source" => File.read("source.rb")))
        puts JSON.generate("summary" => { "killed" => 1, "survived" => 0 })
      RUBY
      command = [RbConfig.ruby, "-e", code]
      manifest = [{ "project" => "demo", "tool" => "ripr", "directory" => directory,
                    "file" => "source.rb", "before" => "42", "after" => "(42)", "caches" => [".ripr"], "profile" => ".ripr/profile.json",
                    "full" => command, "incremental" => command, "format" => "ripr" }]
      manifest_path = File.join(directory, "manifest.json")
      output_path = File.join(directory, "results.json")
      File.write(manifest_path, JSON.generate(manifest))
      script = File.expand_path("../script/compare_benchmarks.rb", __dir__)
      _output, error, status = Open3.capture3(RbConfig.ruby, script, manifest_path, output_path)
      expect(status.success?).to be(true), error
      result = JSON.parse(File.read(output_path)).first
      expect(result.fetch("full").size).to eq(3)
      expect(result.fetch("incremental").size).to eq(3)
      expect(result.fetch("full").first.fetch("summary").fetch("total")).to eq(1)
      expect(result.fetch("full").first.fetch("profile").fetch("source")).to eq(source)
      expect(result.fetch("incremental").first.fetch("profile").fetch("source")).to eq("def answer; (42); end\n")
      invocations = File.readlines(File.join(directory, "invocations"))
      expect(invocations).to eq(["def answer; 42; end\n", "def answer; (42); end\n"] * 3)
      expect(File.read(File.join(directory, "source.rb"))).to eq(source)
    end
  end

  it "records an empty full scope as blocked instead of a performance result" do
    Dir.mktmpdir("ripr-empty-comparison") do |directory|
      File.write(File.join(directory, "source.rb"), "42\n")
      command = [RbConfig.ruby, "-e", 'puts %q({"summary":{"killed":0,"survived":0}})']
      config = { "project" => "empty", "tool" => "ripr", "directory" => directory,
                 "file" => "source.rb", "before" => "42", "after" => "(42)", "caches" => [],
                 "full" => command, "incremental" => command, "format" => "ripr" }
      manifest = File.join(directory, "manifest.json")
      destination = File.join(directory, "results.json")
      File.write(manifest, JSON.generate([config]))
      script = File.expand_path("../script/compare_benchmarks.rb", __dir__)
      _output, error, status = Open3.capture3(RbConfig.ruby, script, manifest, destination)
      expect(status.success?).to be(true), error
      expect(JSON.parse(File.read(destination)).first.fetch("blocked")).to include("No mutants")
      expect(File.read(File.join(directory, "source.rb"))).to eq("42\n")
    end
  end

  it "probes one cold execution without publishing a median" do
    Dir.mktmpdir("ripr-probe-comparison") do |directory|
      File.write(File.join(directory, "source.rb"), "42\n")
      command = [RbConfig.ruby, "-e", 'puts %q({"summary":{"killed":1,"survived":0}})']
      config = { "project" => "probe", "tool" => "ripr", "directory" => directory,
                 "file" => "source.rb", "before" => "42", "after" => "(42)", "caches" => [],
                 "full" => command, "incremental" => command, "format" => "ripr", "probe_only" => true }
      manifest = File.join(directory, "manifest.json")
      destination = File.join(directory, "results.json")
      File.write(manifest, JSON.generate([config]))
      script = File.expand_path("../script/compare_benchmarks.rb", __dir__)
      _output, error, status = Open3.capture3(RbConfig.ruby, script, manifest, destination)
      expect(status.success?).to be(true), error
      result = JSON.parse(File.read(destination)).first
      expect(result.fetch("full").size).to eq(1)
      expect(result).not_to have_key("full_median_seconds")
      expect(result).not_to have_key("incremental")
    end
  end

  it "bounds a timed out process tree and saves its partial output" do
    Dir.mktmpdir("ripr-timeout-comparison") do |directory|
      File.write(File.join(directory, "source.rb"), "42\n")
      code = <<~RUBY
        $stdout.sync = true
        fork { Process.setpgid(0, 0); puts "worker started"; sleep 3 }
        puts "progress before timeout"
        sleep 5
      RUBY
      command = [RbConfig.ruby, "-e", code]
      config = { "project" => "timeout", "tool" => "ripr", "directory" => directory,
                 "file" => "source.rb", "before" => "42", "after" => "(42)", "caches" => [],
                 "full" => command, "incremental" => command, "format" => "ripr", "timeout_seconds" => 1 }
      manifest = File.join(directory, "manifest.json")
      destination = File.join(directory, "results.json")
      File.write(manifest, JSON.generate([config]))
      script = File.expand_path("../script/compare_benchmarks.rb", __dir__)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _output, error, status = Open3.capture3(RbConfig.ruby, script, manifest, destination)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(status.success?).to be(true), error
      result = JSON.parse(File.read(destination)).first
      expect(result.fetch("blocked")).to include("exceeded")
      expect(result.fetch("partial").fetch("seconds")).to be >= 1
      expect(File.read(File.join(directory, "comparison-logs/cold-0.stdout"))).to include("progress before timeout")
      expect(elapsed).to be < 3
      expect(File.read(File.join(directory, "source.rb"))).to eq("42\n")
    end
  end

  it "bounds capture after the direct process exits and a detached descendant retains its pipes" do
    Dir.mktmpdir("ripr-detached-comparison") do |directory|
      File.write(File.join(directory, "source.rb"), "42\n")
      code = <<~RUBY
        $stdout.sync = true
        ready, signal = IO.pipe
        fork do
          ready.close
          Process.setpgid(0, 0)
          File.write("detached.pid", Process.pid)
          puts "detached worker output"
          signal.write(".")
          signal.close
          sleep 60
        end
        signal.close
        ready.read(1)
        File.write("parent-finished", "ready")
        exit! 0
      RUBY
      command = [RbConfig.ruby, "-e", code]
      config = { "project" => "detached", "tool" => "ripr", "directory" => directory,
                 "file" => "source.rb", "before" => "42", "after" => "(42)", "caches" => [],
                 "full" => command, "incremental" => command, "format" => "ripr", "timeout_seconds" => 0.4 }
      manifest = File.join(directory, "manifest.json")
      destination = File.join(directory, "results.json")
      File.write(manifest, JSON.generate([config]))
      script = File.expand_path("../script/compare_benchmarks.rb", __dir__)
      Open3.popen3(RbConfig.ruby, script, manifest, destination) do |input, _output, error, process|
        input.close
        finished = process.join(3)
        unless finished
          Process.kill("KILL", process.pid)
          process.join
        end
        expect(finished).not_to be_nil, "benchmark capture remained blocked after its timeout"
        expect(process.value.success?).to be(true), error.read
      end
      result = JSON.parse(File.read(destination)).first
      expect(result.fetch("blocked")).to include("exceeded")
      expect(result.fetch("partial").fetch("stdout_bytes")).to be_positive
      expect(File.read(File.join(directory, "comparison-logs/cold-0.stdout"))).to include("detached worker output")
      expect(File.exist?(File.join(directory, "parent-finished"))).to be(true)
      expect(File.read(File.join(directory, "source.rb"))).to eq("42\n")
    ensure
      if directory && File.file?(File.join(directory, "detached.pid"))
        pid = Integer(File.read(File.join(directory, "detached.pid")))
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end

  it "retains completed measurements when a later cold or incremental run times out" do
    %w[full incremental].each do |phase|
      Dir.mktmpdir("ripr-partial-comparison") do |directory|
        File.write(File.join(directory, "source.rb"), "42\n")
        failure_run = phase == "full" ? 2 : 3
        code = <<~RUBY
          require "json"
          count = File.exist?("attempts") ? Integer(File.read("attempts")) + 1 : 1
          File.write("attempts", count)
          sleep 60 if count == #{failure_run}
          puts JSON.generate("summary" => { "killed" => 1, "survived" => 0 })
        RUBY
        delayed = [RbConfig.ruby, "-e", code]
        immediate = [RbConfig.ruby, "-e", 'puts %q({"summary":{"killed":1,"survived":0}})']
        config = { "project" => "partial", "tool" => "ripr", "directory" => directory,
                   "file" => "source.rb", "before" => "42", "after" => "(42)", "caches" => [],
                   "full" => phase == "full" ? delayed : immediate,
                   "incremental" => phase == "incremental" ? delayed : immediate,
                   "format" => "ripr", "timeout_seconds" => 0.4 }
        manifest = File.join(directory, "manifest.json")
        destination = File.join(directory, "results.json")
        File.write(manifest, JSON.generate([config]))
        script = File.expand_path("../script/compare_benchmarks.rb", __dir__)
        _output, error, status = Open3.capture3(RbConfig.ruby, script, manifest, destination)
        expect(status.success?).to be(true), error
        result = JSON.parse(File.read(destination)).first
        expect(result.fetch("blocked")).to include("exceeded")
        expect(result.fetch(phase, []).size).to eq(failure_run - 1)
        expect(result.fetch(phase).all? { |run| run.fetch("summary").fetch("total") == 1 }).to be(true)
        expect(result.fetch("partial").fetch("phase")).to eq("#{phase == 'full' ? 'cold' : 'edited'}-#{failure_run - 1}")
        expect(result.fetch("full").size).to eq(3) if phase == "incremental"
        expect(result.fetch("incremental").size).to eq(1) if phase == "full"
        expect(File.read(File.join(directory, "source.rb"))).to eq("42\n")
      end
    end
  end

  %w[group descendant].each do |denial|
    it "keeps the deadline and owned child cleanup when #{denial} signals are denied" do
      Dir.mktmpdir("ripr-denied-signal") do |directory|
        File.write(File.join(directory, "source.rb"), "42\n")
        code = <<~RUBY
          $stdout.sync = true
          File.write("owned.pid", Process.pid)
          ready, signal = IO.pipe
          fork do
            ready.close
            Process.setpgid(0, 0)
            File.write("descendant.pid", Process.pid)
            signal.write(".")
            signal.close
            sleep 60
          end
          signal.close
          ready.read(1)
          puts "progress before denied cleanup"
          sleep 60
        RUBY
        bootstrap = File.join(directory, "deny-signals.rb")
        File.write(bootstrap, <<~RUBY)
          module DeniedBenchmarkSignals
            def kill(signal, pid)
              owned = Integer(File.read("owned.pid")) if File.file?("owned.pid")
              denied = #{denial.dump} == "group" ? pid.negative? : owned && pid.positive? && pid != owned
              if denied
                raise Errno::EPERM, "injected denial"
              end
              result = super
              File.open("signals", "a") { |file| file.puts("\#{signal}:\#{pid}:sent") }
              result
            end
          end
          Process.singleton_class.prepend(DeniedBenchmarkSignals)
        RUBY
        command = [RbConfig.ruby, "-e", code]
        config = { "project" => "denied", "tool" => "ripr", "directory" => directory,
                   "file" => "source.rb", "before" => "42", "after" => "(42)", "caches" => [],
                   "full" => command, "incremental" => command, "format" => "ripr", "timeout_seconds" => 0.4 }
        manifest = File.join(directory, "manifest.json")
        destination = File.join(directory, "results.json")
        File.write(manifest, JSON.generate([config]))
        script = File.expand_path("../script/compare_benchmarks.rb", __dir__)
        Open3.popen3(RbConfig.ruby, "-r", bootstrap, script, manifest, destination,
                     chdir: directory) do |input, _output, error, process|
          input.close
          finished = process.join(3)
          unless finished
            Process.kill("KILL", process.pid)
            process.join
          end
          expect(finished).not_to be_nil, "denied auxiliary signals prevented owned child cleanup"
          expect(process.value.success?).to be(true), error.read
        end
        result = JSON.parse(File.read(destination)).first
        expect(result.fetch("blocked")).to include("exceeded")
        owned = Integer(File.read(File.join(directory, "owned.pid")))
        descendant = Integer(File.read(File.join(directory, "descendant.pid")))
        denied_pid = denial == "group" ? -owned : descendant
        expect(result.fetch("partial").fetch("cleanup_errors").join).to include("EPERM", "STOP", "PID #{denied_pid}")
        expect(File.read(File.join(directory, "signals"))).to include("KILL:#{owned}:sent")
        expect(File.read(File.join(directory, "comparison-logs/cold-0.stdout"))).to include("progress before denied cleanup")
        expect(File.read(File.join(directory, "source.rb"))).to eq("42\n")
      ensure
        %w[owned.pid descendant.pid].each do |file|
          next unless directory && File.file?(File.join(directory, file))

          begin
            Process.kill("KILL", Integer(File.read(File.join(directory, file))))
          rescue Errno::ESRCH
            nil
          end
        end
      end
    end
  end

  it "returns an owned KILL denial without implicitly waiting for the unkillable child" do
    Dir.mktmpdir("ripr-denied-owned-kill") do |directory|
      File.write(File.join(directory, "source.rb"), "42\n")
      code = 'File.write("owned.pid", Process.pid); $stdout.sync = true; puts "owned child ready"; sleep 60'
      bootstrap = File.join(directory, "deny-owned-kill.rb")
      File.write(bootstrap, <<~RUBY)
        module DeniedOwnedKill
          def kill(signal, pid)
            owned = Integer(File.read("owned.pid")) if File.file?("owned.pid")
            raise Errno::EPERM, "injected owned denial" if signal == "KILL" && pid == owned

            super
          end
        end
        Process.singleton_class.prepend(DeniedOwnedKill)
      RUBY
      command = [RbConfig.ruby, "-e", code]
      config = { "project" => "denied-owned", "tool" => "ripr", "directory" => directory,
                 "file" => "source.rb", "before" => "42", "after" => "(42)", "caches" => [],
                 "full" => command, "incremental" => command, "format" => "ripr", "timeout_seconds" => 0.4 }
      manifest = File.join(directory, "manifest.json")
      destination = File.join(directory, "results.json")
      File.write(manifest, JSON.generate([config]))
      script = File.expand_path("../script/compare_benchmarks.rb", __dir__)
      Open3.popen3(RbConfig.ruby, "-r", bootstrap, script, manifest, destination,
                   chdir: directory) do |input, _output, error, process|
        input.close
        finished = process.join(3)
        unless finished
          Process.kill("KILL", process.pid)
          process.join
        end
        expect(finished).not_to be_nil, "owned KILL denial still waited for the child"
        expect(process.value.success?).to be(true), error.read
      end
      owned = Integer(File.read(File.join(directory, "owned.pid")))
      result = JSON.parse(File.read(destination)).first
      expect(result.fetch("blocked")).to include("Errno::EPERM", "KILL", "PID #{owned}")
      expect(File.read(File.join(directory, "source.rb"))).to eq("42\n")
    ensure
      if directory && File.file?(File.join(directory, "owned.pid"))
        begin
          Process.kill("KILL", Integer(File.read(File.join(directory, "owned.pid"))))
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end
end
