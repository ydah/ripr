# frozen_string_literal: true

require "ripr/engine/worker_memory"

RSpec.describe Ripr::Engine::WorkerMemory do
  context "on Linux" do
    before do
      stub_const("RUBY_PLATFORM", "x86_64-linux")
      allow(File).to receive(:binread).and_call_original
      allow(File).to receive(:binread).with("/proc/meminfo").and_return("MemAvailable: 20000 kB\n")
      allow(File).to receive(:binread).with("/proc/self/status").and_return("VmRSS: 2000 kB\n")
      allow(File).to receive(:binread).with("/proc/self/cgroup").and_return("0::/parent/test\n")
      allow(File).to receive(:binread).with("/sys/fs/cgroup/memory.max").and_return("max\n")
      allow(File).to receive(:binread).with("/sys/fs/cgroup/parent/memory.max").and_return("8192000\n")
      allow(File).to receive(:binread).with("/sys/fs/cgroup/parent/memory.current").and_return("2048000\n")
      allow(File).to receive(:binread).with("/sys/fs/cgroup/parent/test/memory.max").and_return("max\n")
    end

    it "divides the smallest available memory budget by the parent RSS" do
      expect(described_class.limit).to eq(3)
    end

    it "uses the tighter nested quota beneath an unlimited cgroup" do
      allow(File).to receive(:binread).with("/sys/fs/cgroup/memory.current").and_return("1024000\n")
      allow(File).to receive(:binread).with("/sys/fs/cgroup/parent/test/memory.max").and_return("4096000\n")
      allow(File).to receive(:binread).with("/sys/fs/cgroup/parent/test/memory.current").and_return("2048000\n")

      expect(described_class.limit).to eq(1)
    end

    it "ignores cgroup paths that escape their reported hierarchy" do
      allow(File).to receive(:binread).with("/proc/self/cgroup").and_return("0::/parent/../test\n")

      expect(described_class.limit).to eq(10)
    end

    it "ignores an unreadable usage value while retaining another valid quota" do
      allow(File).to receive(:binread).with("/sys/fs/cgroup/memory.max").and_return("4096000\n")
      allow(File).to receive(:binread).with("/sys/fs/cgroup/memory.current").and_return("unavailable\n")

      expect(described_class.limit).to eq(3)
    end

    it "allows one worker even when the remaining memory estimate is exhausted" do
      allow(File).to receive(:binread).with("/sys/fs/cgroup/parent/memory.current").and_return("8192000\n")
      expect(described_class.limit).to eq(1)
    end

    it "falls back to host memory when cgroup files are absent" do
      allow(File).to receive(:binread).with("/proc/self/cgroup").and_raise(Errno::ENOENT)
      expect(described_class.limit).to eq(10)
    end

    it "converts host and resident kilobytes before rounding down the worker count" do
      allow(File).to receive(:binread).with("/proc/self/cgroup").and_raise(Errno::ENOENT)
      allow(File).to receive(:binread).with("/proc/meminfo").and_return("MemAvailable: 19999 kB\n")

      expect(described_class.limit).to eq(9)
    end

    it "uses the cgroup budget when host available memory is not reported" do
      allow(File).to receive(:binread).with("/proc/meminfo").and_return("MemFree: 20000 kB\n")

      expect(described_class.limit).to eq(3)
    end

    it "leaves the worker count to the CPU limit when the parent RSS is unavailable" do
      allow(File).to receive(:binread).with("/proc/self/status").and_raise(Errno::EACCES)
      expect(described_class.limit).to be_nil
    end
  end

  it "uses the macOS page size and the parent RSS in kilobytes" do
    stub_const("RUBY_PLATFORM", "arm64-darwin25")
    vm_stat = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages purgeable: 250.\n"
    success = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture2).with("/usr/bin/vm_stat", err: File::NULL).and_return([vm_stat, success])
    allow(Open3).to receive(:capture2).with("/bin/ps", "-o", "rss=", "-p", Process.pid.to_s, err: File::NULL)
                                      .and_return([" 4096\n", success])

    expect(described_class.limit).to eq(4)

    [[1023, 3], [1024, 4]].each do |pages, workers|
      stats = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: #{pages}.\nPages purgeable: 0.\n"
      allow(Open3).to receive(:capture2).with("/usr/bin/vm_stat", err: File::NULL).and_return([stats, success])

      expect(described_class.limit).to eq(workers)
    end
  end

  it "leaves the worker count to the CPU limit when macOS RSS cannot be read" do
    stub_const("RUBY_PLATFORM", "arm64-darwin25")
    stats = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1024.\nPages purgeable: 0.\n"
    success = instance_double(Process::Status, success?: true)
    failure = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture2).with("/usr/bin/vm_stat", err: File::NULL).and_return([stats, success])
    allow(Open3).to receive(:capture2).with("/bin/ps", "-o", "rss=", "-p", Process.pid.to_s, err: File::NULL)
                                      .and_return(["", failure])

    expect(described_class.limit).to be_nil
  end
end
