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

    it "copies captured SQLite snapshots without acquiring a database lock" do
      counts = run_fixture(<<~RUBY)
        require "ripr/integration/rails_database"
        require "sqlite3"
        require "fileutils"
        require "json"

        FileUtils.mkdir_p("isolated")
        SQLite3::Database.new("test.sqlite3") do |original|
          original.execute("PRAGMA journal_mode = WAL")
          original.execute("PRAGMA wal_autocheckpoint = 0")
          original.execute("CREATE TABLE widgets (id INTEGER)")
          original.execute("INSERT INTO widgets VALUES (1)")
          database = Ripr::Integration::RailsDatabase::SQLite.new({ database: "test.sqlite3" }, Dir.pwd, "isolated", 0)
          SQLite3::Database.new(database.parent) { |parent| parent.execute("INSERT INTO widgets VALUES (2)") }
          database.capture

          counts = []
          SQLite3::Database.new("isolated/database-0-ready") do |snapshot|
            snapshot.execute("PRAGMA journal_mode = DELETE")
            snapshot.execute("BEGIN EXCLUSIVE")
            worker = database.worker(0, fresh_boot: false)
            SQLite3::Database.new(worker) { |copy| counts << copy.get_first_value("SELECT count(*) FROM widgets") }
          end
          pristine = database.worker(0, fresh_boot: true)
          SQLite3::Database.new(pristine) { |copy| counts << copy.get_first_value("SELECT count(*) FROM widgets") }
          puts JSON.generate(counts << original.get_first_value("SELECT count(*) FROM widgets"))
        end
      RUBY

      expect(counts).to eq([2, 1, 1])
    end

    if (postgresql_url = ENV.fetch("RIPR_TEST_POSTGRESQL", nil))
      it "clones disconnected PostgreSQL snapshots and falls back to the same captured data" do
        results = run_fixture(<<~'RUBY', url: postgresql_url)
          require "json"
          require "pg"
          require "ripr/integration/rails_database"
          require "tmpdir"

          source = "ripr_snapshot_#{SecureRandom.hex(8)}_test"
          admin = PG.connect(ENV.fetch("RIPR_TEST_DATABASE_URL"))
          connection = admin.conninfo_hash.reject { |_, value| value.nil? || value.empty? }
          connect = ->(name, &block) { PG.connect(connection.merge(dbname: name), &block) }
          config = { database: source, host: connection[:host], port: connection[:port], username: connection[:user],
                     password: connection[:password], sslmode: connection[:sslmode] }
          rows = ->(session) { session.exec("SELECT label FROM widgets ORDER BY label").column_values(0) }
          implementation = Ripr::Integration::RailsDatabase::PostgreSQL
          with_late_write = Class.new(implementation) do
            define_method(:dump) do |name, output|
              super(name, output)
              if output.end_with?("-ready")
                connect.call(parent) { |session| session.exec("INSERT INTO widgets (label) VALUES ('during capture')") }
              end
            end
          end
          begin
            admin.exec("CREATE DATABASE #{admin.quote_ident(source)}")
            connect.call(source) do |original|
              original.exec("CREATE TABLE widgets (id bigserial PRIMARY KEY, label text NOT NULL)")
              original.exec("INSERT INTO widgets (label) VALUES ('original')")
            end

            prefixes = []
            samples = [false, true].map.with_index do |connected, index|
              Dir.mktmpdir do |directory|
                database = (connected ? implementation : with_late_write).new(config, Dir.pwd, directory, index)
                prefix = database.parent.delete_suffix("parent")
                prefixes << prefix
                parent = connect.call(database.parent)
                parent.exec("INSERT INTO widgets (label) VALUES ('booted')")
                parent.exec("ANALYZE widgets")
                parent.close unless connected
                database.capture

                parent = connect.call(database.parent) unless connected
                parent.exec("INSERT INTO widgets (label) VALUES ('after capture')")
                parent.close
                worker = database.worker(0, fresh_boot: false)
                copied = connect.call(worker) do |session|
                  statistics = session.exec("SELECT 1 FROM pg_stats WHERE tablename = 'widgets'")
                  [rows.call(session), statistics.ntuples.positive?]
                end
                unless connected
                  template = admin.exec_params("SELECT datname FROM pg_database WHERE starts_with(datname, $1) AND NOT datallowconn", [prefix])
                  admin.exec("DROP DATABASE #{admin.quote_ident(template[0].fetch('datname'))}")
                end
                fallback = connect.call(database.worker(0, fresh_boot: false), &rows)
                pristine = database.worker(0, fresh_boot: true)
                [*copied, fallback, connect.call(pristine, &rows)]
              ensure
                parent&.close unless parent&.finished?
                database&.close
              end
            end
            leaked = admin.exec("SELECT datname FROM pg_database").column_values(0).select do |name|
              prefixes.any? { |prefix| name.start_with?(prefix) }
            end
            puts JSON.generate([samples, connect.call(source, &rows), leaked])
          ensure
            admin.exec("DROP DATABASE IF EXISTS #{admin.quote_ident(source)}")
            admin.close
          end
        RUBY

        expect(results).to eq([[[%w[booted original], true, %w[booted original], ["original"]],
                                [%w[booted original], false, %w[booted original], ["original"]]], ["original"], []])
      end

      it "reuses a sealed PostgreSQL template only for equivalent booted database content" do
        restore_help, = Open3.capture2("pg_restore", "--help")
        skip "pg_restore has no stable restrict key option" unless restore_help.include?("--restrict-key")

        copies, original, materialized, unlogged, concurrent, ambiguous, collision = run_fixture(<<~'RUBY', url: postgresql_url)
          require "digest"
          require "json"
          require "pg"
          require "ripr/integration/rails_database"
          require "tmpdir"

          ENV["RIPR_POSTGRESQL_TEMPLATE_CACHE"] = "1"
          source = "ripr_snapshot_#{SecureRandom.hex(8)}_test"
          admin = PG.connect(ENV.fetch("RIPR_TEST_DATABASE_URL"))
          connection = admin.conninfo_hash.reject { |_, value| value.nil? || value.empty? }
          connect = ->(name, &block) { PG.connect(connection.merge(dbname: name), &block) }
          config = { database: source, host: connection[:host], port: connection[:port], username: connection[:user],
                     password: connection[:password], sslmode: connection[:sslmode] }
          role = admin.exec("SELECT current_user").getvalue(0, 0)
          scope = Digest::SHA256.hexdigest([Dir.pwd, source, 0, role].join("\0")).slice(0, 32)
          slot = "ripr_test_cache_#{scope}"
          template = lambda do
            admin.exec_params(<<~SQL, [slot]).first
              SELECT oid, datallowconn, shobj_description(oid, 'pg_database') AS marker
                FROM pg_database
               WHERE datname = $1
            SQL
          end
          raise "test cache slot already exists" if template.call
          own_slot = true
          rows = ->(session) { session.exec("SELECT label FROM widgets ORDER BY id").column_values(0) }
          analyzed = ->(session) { session.exec("SELECT 1 FROM pg_stats WHERE tablename = 'widgets'").ntuples.positive? }
          implementation = Ripr::Integration::RailsDatabase::PostgreSQL

          begin
            admin.exec("CREATE DATABASE #{admin.quote_ident(source)}")
            own_source = true
            connect.call(source) do |session|
              session.exec("CREATE TABLE widgets (id bigserial PRIMARY KEY, label text NOT NULL)")
              session.exec("INSERT INTO widgets (label) VALUES ('original')")
            end

            capture = lambda do |label, advance: false, schema: false, view: nil, unlogged: false, idle_timeout: nil, &observe|
              Dir.mktmpdir do |directory|
                database = implementation.new(config, Dir.pwd, directory, 0)
                connect.call(database.parent) do |session|
                  session.exec_params("INSERT INTO widgets (id, label) VALUES (2, $1)", [label])
                  session.exec("SELECT setval('widgets_id_seq', 10)") if advance
                  session.exec("ALTER TABLE widgets ADD COLUMN stock integer") if schema
                  session.exec("ALTER TABLE widgets SET UNLOGGED") if unlogged
                  if view
                    session.exec_params("SELECT set_config('ripr.fixture_value', $1, false)", [view])
                    session.exec("CREATE MATERIALIZED VIEW capture_value AS SELECT current_setting('ripr.fixture_value', true) AS value")
                  end
                  session.exec("ANALYZE widgets")
                end
                previous_options = ENV["PGOPTIONS"]
                begin
                  ENV["PGOPTIONS"] = "#{previous_options} -c idle_session_timeout=#{idle_timeout}" if idle_timeout
                  database.capture
                ensure
                  ENV["PGOPTIONS"] = previous_options
                end
                observe.call(database)
              ensure
                database&.close
              end
            end

            samples = 5.times.map do |run|
              capture.call(run >= 2 ? "changed" : "booted", advance: run >= 3, schema: run >= 4) do |database|
                ready = connect.call(database.worker(0, fresh_boot: false)) do |worker|
                  state = [rows.call(worker), worker.exec("SELECT last_value FROM widgets_id_seq").getvalue(0, 0),
                           worker.exec("SELECT * FROM widgets LIMIT 0").fields, analyzed.call(worker)]
                  worker.exec("INSERT INTO widgets (id, label) VALUES (99, 'written by worker')")
                  state
                end
                local = database.parent.delete_suffix("parent") + "template"
                local_template = admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [local]).ntuples.positive?
                [template.call, ready, connect.call(database.worker(0, fresh_boot: true), &rows), local_template]
              end
            end

            previous = template.call
            materialized = %w[first second].map do |view|
              capture.call("changed", advance: true, schema: true, view: view) do |database|
                actual = connect.call(database.worker(0, fresh_boot: false)) do |worker|
                  worker.exec("SELECT value FROM capture_value").getvalue(0, 0)
                end
                [actual, template.call == previous]
              end
            end
            unlogged = capture.call("unlogged", unlogged: true) do |database|
              [connect.call(database.worker(0, fresh_boot: false), &rows), template.call == previous]
            end

            idle_timeout = 200 if admin.server_version >= 140_000
            scenarios = idle_timeout ? %i[idle terminated] : [:idle]
            concurrent = scenarios.to_h do |scenario|
              result = capture.call("older run", idle_timeout: idle_timeout) do |older|
                previous = template.call
                if scenario == :terminated
                  lease = older.instance_variable_get(:@cache_lease)
                  terminated = admin.exec_params("SELECT pg_terminate_backend($1, 5000)", [lease.backend_pid]).getvalue(0, 0)
                  raise "could not terminate test lease" unless terminated == "t"
                elsif idle_timeout
                  sleep 0.45
                end
                capture.call("newer run") do |newer|
                  workers = [older, newer].map do |database|
                    connect.call(database.worker(0, fresh_boot: false)) { |worker| [rows.call(worker), analyzed.call(worker)] }
                  end
                  [template.call == previous, workers]
                end
              end
              [scenario, result]
            end

            missed_acknowledgement = true
            Ripr::Integration::RailsDatabase::PostgreSQLTemplateCache.prepend(Module.new do
              define_method(:downgrade_lock) do
                if missed_acknowledgement
                  missed_acknowledgement = false
                  raise PG::Error, "simulated lost publication acknowledgement"
                end
                super()
              end
            end)
            previous = template.call
            ambiguous = capture.call("published during connection loss") do |database|
              state = connect.call(database.worker(0, fresh_boot: false)) { |worker| [rows.call(worker), analyzed.call(worker)] }
              [!missed_acknowledgement && template.call != previous, state]
            end

            unrelated = "managed separately"
            admin.exec("COMMENT ON DATABASE #{admin.quote_ident(slot)} IS #{admin.escape_literal(unrelated)}")
            previous = template.call
            collision = capture.call("separate database") do |database|
              [connect.call(database.worker(0, fresh_boot: false), &rows), template.call == previous]
            end

            puts JSON.generate([samples, connect.call(source, &rows), materialized, unlogged, concurrent, ambiguous, collision])
          ensure
            admin.exec("DROP DATABASE IF EXISTS #{admin.quote_ident(slot)}") if own_slot
            admin.exec("DROP DATABASE IF EXISTS #{admin.quote_ident(source)}") if own_source
            admin.close
          end
        RUBY

        templates = copies.map(&:first)
        expect(templates).to all(include("datallowconn" => "f"))
        expect(templates[0]).to eq(templates[1])
        expect(templates.map { |template| template.fetch("oid") }.uniq.size).to eq(4)
        expect(copies.map { |_, ready, _, _| ready }).to eq(
          [[%w[original booted], "1", %w[id label], true], [%w[original booted], "1", %w[id label], true],
           [%w[original changed], "1", %w[id label], true], [%w[original changed], "10", %w[id label], true],
           [%w[original changed], "10", %w[id label stock], true]]
        )
        expect(copies.map { |_, _, pristine, _| pristine }).to eq([["original"]] * 5)
        expect(copies[1].last).to be(false)
        expect(original).to eq(["original"])
        expect(materialized).to eq([["first", true], ["second", true]])
        expect(unlogged).to eq([%w[original unlogged], true])
        workers = [[["original", "older run"], true], [["original", "newer run"], true]]
        expect(concurrent.fetch("idle")).to eq([true, workers])
        expect(concurrent.fetch("terminated")).to eq([false, workers]) if concurrent.key?("terminated")
        expect(ambiguous).to eq([true, [["original", "published during connection loss"], true]])
        expect(collision).to eq([["original", "separate database"], true])
      end
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
