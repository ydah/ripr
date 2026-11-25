# frozen_string_literal: true

require "open3"

module Ripr
  module Engine
    module WorkerMemory
      module_function

      def limit
        available, rss = case RUBY_PLATFORM
                         when /linux/ then linux_memory
                         when /darwin/ then mac_memory
                         end
        [available / rss, 1].max if available && rss&.positive?
      end

      def linux_memory
        available = number(read("/proc/meminfo"), /^MemAvailable:\s+(\d+) kB$/)
        rss = number(read("/proc/self/status"), /^VmRSS:\s+(\d+) kB$/)
        [[available && (available * 1024), cgroup_available].compact.min, rss && (rss * 1024)]
      end

      def cgroup_available
        path = read("/proc/self/cgroup")&.[](%r{^0::/(.*)$}, 1)
        return unless path

        components = path.split("/")
        return if components.include?("..")

        directories = ["/sys/fs/cgroup"]
        components.each { |component| directories << File.join(directories.last, component) }
        directories.filter_map do |directory|
          maximum = Integer(read(File.join(directory, "memory.max")).to_s, 10, exception: false)
          next unless maximum

          current = Integer(read(File.join(directory, "memory.current")).to_s, 10, exception: false)
          maximum - current if current
        end.min
      end

      def mac_memory
        stats = command("/usr/bin/vm_stat")
        size = number(stats, /page size of (\d+) bytes/)
        free = number(stats, /^Pages free:\s+(\d+)\./)
        purgeable = number(stats, /^Pages purgeable:\s+(\d+)\./)
        rss = Integer(command("/bin/ps", "-o", "rss=", "-p", Process.pid.to_s).to_s, 10, exception: false)
        [size && free && (size * (free + purgeable.to_i)), rss && (rss * 1024)]
      end

      def number(output, pattern)
        output&.[](pattern, 1)&.to_i
      end

      def command(*)
        output, status = Open3.capture2(*, err: File::NULL)
        output if status.success?
      rescue SystemCallError
        nil
      end

      def read(path)
        File.binread(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
