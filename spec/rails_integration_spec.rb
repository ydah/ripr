# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

if ENV["RIPR_TEST_RAILS"]
  RSpec.describe "Rails integration" do
    let(:lib) { File.expand_path("../lib", __dir__) }
    let(:fixture) { File.expand_path("../test/fixtures/projects/rails_app", __dir__) }

    def run_fixture(script, url: nil)
      Dir.mktmpdir("ripr-rails-spec") do |directory|
        FileUtils.cp_r(File.join(fixture, "."), directory)
        environment = { "RAILS_ENV" => nil, "RACK_ENV" => nil, "DISABLE_SPRING" => "0", "RIPR_TEST_DATABASE_URL" => url,
                        "DATABASE_URL" => nil, "PRIMARY_DATABASE_URL" => nil }
        output, error, status = Open3.capture3(environment, RbConfig.ruby, "-I", lib, "-e", script, chdir: directory)
        expect(status.success?).to be(true), "#{output}\n#{error}"
        JSON.parse(output)
      end
    end

    it "rejects an explicit reconnect to the original test database" do
      message = run_fixture(<<~RUBY)
        require "ripr/integration/rails"
        rails = Ripr::Integration::Rails.new
        rails.prepare
        rails.boot
        begin
          ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: "test.sqlite3")
          puts JSON.generate(nil)
        rescue ArgumentError => error
          puts JSON.generate(error.message)
        ensure
          rails.close
        end
      RUBY
      expect(message).to include("isolated Rails test database")
    end

    it "runs static Rails mutations and verifies kills through the CLI" do
      code, summary, mutations, created_test_database = run_fixture(<<~RUBY)
        require "ripr/cli"
        require "stringio"

        output = StringIO.new
        args = %w[--rails --static --verify-killed --operators integer_literal --jobs 2 --reporter agent]
        status = Ripr::CLI.start(args, stdout: output)
        snapshot = JSON.parse(File.read(".ripr/snapshot.json"))
        puts JSON.generate([status, JSON.parse(output.string).fetch("summary"), snapshot.fetch("mutants").values,
                            File.exist?("test.sqlite3")])
      RUBY

      expect(code).to eq(0)
      expect(summary).to include("killed" => 2, "timeout" => 0, "error" => 0)
      expect(mutations).to all(include("static" => true, "status" => "killed", "killed_by" => "WidgetTest#test_stocked"))
      expect(created_test_database).to be(false)
    end

    %w[sqlite postgresql mysql].each do |adapter|
      url = ENV.fetch("RIPR_TEST_#{adapter.upcase}", nil)
      next unless adapter == "sqlite" || url

      it "isolates Rails #{adapter} trials and supports a fresh boot with Bootsnap, Zeitwerk, and Spring installed" do
        result = run_fixture(<<~'RUBY', url: url)
          require "json"
          require "open3"
          require "rbconfig"
          require "ripr/integration/rails"

          # A zero-byte source also catches accidental initializers writing into the original SQLite DB.
          File.write("test.sqlite3", "") unless ENV["RIPR_TEST_DATABASE_URL"]
          rails = Ripr::Integration::Rails.new
          rails.prepare
          rails.boot
          raise "Zeitwerk failed to load Widget" unless Widget.find_by!(label: "booted").stocked?
          raise "Bootsnap was not loaded" unless defined?(Bootsnap)
          raise "Spring binstub was not loaded" unless $LOADED_FEATURES.any? { |path| path.end_with?("spring/binstub.rb") }
          raise "Spring was not bypassed" unless ENV["DISABLE_SPRING"] == "1"
          parent_database = ActiveRecord::Base.connection_db_config.database
          Widget.create!(label: "before fork", stock: 1)
          rails.prepare_workers(2)

          workers = [0, 1].map do |slot|
            fork do
              rails.with_worker(slot) do
                before = Widget.count
                Widget.create!(label: "child mutation", stock: 1)
                File.write("worker-#{slot}.json", JSON.generate([ActiveRecord::Base.connection_db_config.database, before, Widget.count]))
              end
              exit! 0
            end
          end
          workers.each do |worker|
            Process.wait(worker)
            raise "worker failed" unless $?.success?
          end

          child = fork do
            rails.with_worker(0, fresh_boot: true) do
              script = <<~FRESH
                require "ripr/integration/rails"
                fresh = Ripr::Integration::Rails.new
                fresh.prepare
                fresh.boot
                puts JSON.generate([ActiveRecord::Base.connection_db_config.database, Widget.count])
                fresh.close
              FRESH
              output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.dirname($LOADED_FEATURES.grep(/ripr\/integration\/rails\.rb/).first, 3), "-e", script)
              raise error unless status.success?
              File.write("fresh.json", output)
            end
            exit! 0
          end
          Process.wait(child)
          raise "fresh boot failed" unless $?.success?

          rails.close
          source_unchanged = !File.exist?("test.sqlite3") || File.size("test.sqlite3").zero?
          puts JSON.generate([parent_database, *[0, 1].map { |slot| JSON.parse(File.read("worker-#{slot}.json")) },
                              JSON.parse(File.read("fresh.json")), source_unchanged, ENV["DISABLE_SPRING"]])
        RUBY

        parent, first, second, fresh, source_unchanged, spring = result
        expect([parent, first.first, second.first].uniq.size).to eq(3)
        expect(first.drop(1)).to eq([2, 3])
        expect(second.drop(1)).to eq([2, 3])
        expect(fresh).to eq([first.first, 1])
        expect(source_unchanged).to be(true)
        expect(spring).to eq("0")
      end
    end
  end
end
