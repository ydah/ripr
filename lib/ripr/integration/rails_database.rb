# frozen_string_literal: true

require "fileutils"
require "open3"
require "securerandom"
require "tempfile"

module Ripr
  module Integration
    class RailsDatabase
      def self.build(config, root, directory, index)
        klass = case config.adapter
                when "sqlite3" then SQLite
                when "postgresql" then PostgreSQL
                when "mysql2", "trilogy" then MySQL
                else raise ArgumentError, "unsupported Rails test database adapter: #{config.adapter.inspect}"
                end
        klass.new(config.configuration_hash, root, directory, index)
      end

      def self.worker_database?(config, database, directory)
        return false unless database.is_a?(String)

        if config.adapter == "sqlite3"
          File.dirname(database) == directory && File.basename(database).match?(/\Adatabase-\d+-worker-\d+\.sqlite3\z/) &&
            File.file?(database) && !File.symlink?(database)
        else
          database.match?(/\Aripr_test_[a-f0-9]{24}_\d+_worker_\d+\z/) && File.file?(File.join(directory, "#{database}.created"))
        end
      end

      attr_reader :parent

      def initialize(config, root, directory, index)
        @config = config
        @directory = directory
        @index = index
        @stem = "ripr_test_#{SecureRandom.hex(12)}_#{index}"
        @pristine = File.join(directory, "database-#{index}-pristine")
        @ready = File.join(directory, "database-#{index}-ready")
        @parent = destination("parent")
        dump(source(config.fetch(:database), root), @pristine)
        restore(@pristine, @parent)
      rescue StandardError
        close
        raise
      end

      def capture
        dump(@parent, @ready)
      end

      def worker(slot, fresh_boot:)
        target = destination("worker_#{slot}")
        remove(target)
        restore(fresh_boot ? @pristine : @ready, target)
        target
      end

      def release_worker(slot)
        remove(destination("worker_#{slot}"))
      end

      class SQLite < RailsDatabase
        def server?
          false
        end

        def close
          remove(@parent) if @parent
        end

        private

        def source(database, root)
          return if database == ":memory:"
          raise ArgumentError, "SQLite URI databases are not supported for Rails mutation testing" if database.start_with?("file:")

          path = File.expand_path(database, root)
          path if File.file?(path)
        end

        def destination(suffix)
          File.join(@directory, "database-#{@index}-#{suffix.tr('_', '-')}.sqlite3")
        end

        def dump(input, output)
          require "sqlite3"
          ::SQLite3::Database.new(output) do |destination|
            next unless input

            ::SQLite3::Database.new(input, readonly: true) do |source|
              backup = ::SQLite3::Backup.new(destination, "main", source, "main")
              begin
                status = backup.step(-1)
                unless status == ::SQLite3::Constants::ErrorCode::DONE
                  raise ArgumentError, "could not copy the Rails SQLite database (status #{status})"
                end
              ensure
                backup.finish
              end
            end
          end
        end

        def restore(input, output)
          # The backup connection closes before these private snapshots are shared with workers.
          FileUtils.cp(input, output)
        end

        def remove(database)
          FileUtils.rm_f([database, "#{database}-wal", "#{database}-shm", "#{database}-journal"])
        end
      end

      class Server < RailsDatabase
        def server?
          true
        end

        def close
          return unless @stem

          Dir.glob(File.join(@directory, "#{@stem}_*.created")).each do |path|
            remove(File.basename(path, ".created"))
          rescue ArgumentError => e
            warn "ripr: #{e.message}"
          end
        end

        private

        def source(database, _root)
          unless database.is_a?(String) && database.match?(/\A[a-z0-9_-]+\z/i) && database.match?(/(?:\A|[_-])test(?:\z|[_-])/i)
            raise ArgumentError, "Rails server database name must contain a test component, such as app_test"
          end

          database
        end

        def destination(suffix)
          "#{@stem}_#{suffix}"
        end

        def restore(input, database)
          create_database(database) { sql("CREATE DATABASE #{identifier(database)}") }
          restore_dump(input, database)
        end

        def create_database(database)
          reservation = marker(database)
          File.open(reservation, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.puts(database) }
          begin
            yield
          rescue ArgumentError => e
            File.unlink(reservation) if duplicate_database?(e)
            raise
          end
        end

        def remove(database)
          return unless File.file?(marker(database))

          drop_database(database)
          File.unlink(marker(database))
        end

        def marker(database)
          File.join(@directory, "#{database}.created")
        end

        def identifier(database)
          raise ArgumentError, "invalid isolated Rails database name" unless database.match?(/\A#{@stem}_(?:parent|template|worker_\d+)\z/)

          "#{quote}#{database}#{quote}"
        end

        def command(environment, *arguments, stdin_data: "")
          output, error, status = Open3.capture3(environment, *arguments, stdin_data: stdin_data)
          return output if status.success?

          raise ArgumentError, "Rails database command #{arguments.first} failed: #{error.strip}"
        rescue Errno::ENOENT
          raise ArgumentError, "Rails database command #{arguments.first} was not found on PATH"
        end
      end

      class PostgreSQL < Server
        TEMPLATE_REJECTION = /\b(?:3D000|42501|55006):/
        CONNECTION_ENV = {
          host: "PGHOST", port: "PGPORT", user: "PGUSER", password: "PGPASSWORD", sslmode: "PGSSLMODE", connect_timeout: "PGCONNECT_TIMEOUT"
        }.freeze

        def initialize(config, root, directory, index)
          super
          @cache_scope = [File.expand_path(root), config.fetch(:database), index] if ENV["RIPR_POSTGRESQL_TEMPLATE_CACHE"] == "1"
        end

        def capture
          release_template_lease
          @template = nil
          @capture_identity = nil
          template = destination("template")
          remove(template)
          return super unless template_available?
          return if with_template_cache(shared: true, retain: true) { |cache| reuse_template(cache) }
          return super unless clone_database(template, identifier(@parent))

          dump(template, @ready)
          identity = snapshot_identity(template)
          return unless seal_template(template)

          @template = template
          @capture_identity = identity
          return unless identity && with_template_cache(retain: true) { |cache| cache.publish(identifier(template), identity) }

          @template = nil
          File.unlink(marker(template))
        end

        def worker(slot, fresh_boot:)
          return super if fresh_boot || !(@template || @capture_identity)

          target = destination("worker_#{slot}")
          remove(target)
          copied = if @template
                     clone_database(target, identifier(@template))
                   else
                     with_template_cache(shared: true) do |cache|
                       cache.identity == @capture_identity && clone_database(target, cache.quoted_name, cache.method(:execute))
                     end
                   end
          unless copied
            @capture_identity ? recover_cached_worker(target) : restore(@ready, target)
          end
          target
        end

        def close
          release_template_lease
        ensure
          super
        end

        private

        def with_template_cache(shared: false, retain: false)
          return unless @cache_scope

          session = cache_connection("postgres")
          return unless session

          session.exec("SET idle_session_timeout = 0") if retain && session.server_version >= 140_000
          cache = PostgreSQLTemplateCache.new(session, @cache_scope)
          cache.with_lock(parent: @parent, shared: shared) do
            result = yield cache
            if result && retain
              cache.downgrade_lock unless shared
              @cache_lease = session
              @cache_lease_pid = Process.pid
            end
            result
          end
        rescue ::PG::Error
          nil
        ensure
          session&.close unless session.equal?(@cache_lease)
        end

        def release_template_lease
          return unless @cache_lease_pid == Process.pid

          @cache_lease&.close
          @cache_lease = nil
        end

        def reuse_template(cache)
          expected = cache.identity
          return unless expected

          identity = snapshot_identity(@parent) { dump(@parent, @ready) }
          @capture_identity = identity if identity == expected && cache.identity == expected
        rescue ArgumentError
          nil
        end

        def recover_cached_worker(target)
          verified = Tempfile.create("ripr-worker-", @directory) do |file|
            archive = file.path
            next true if clone_database(target, identifier(@parent)) && worker_matches_capture?(target, archive)

            remove(target)
            restore(@ready, target)
            worker_matches_capture?(target, archive)
          end
          return if verified

          remove(target)
          raise ArgumentError, "could not recover a verified PostgreSQL worker database for this run"
        end

        def worker_matches_capture?(target, archive)
          snapshot_identity(target, archive) { dump(target, archive) } == @capture_identity
        rescue ArgumentError
          false
        end

        def snapshot_identity(database, archive = @ready)
          return unless @cache_scope

          properties = cache_connection(database) { |session| PostgreSQLTemplateCache.snapshot_properties(session) }
          return unless properties

          yield if block_given?
          PostgreSQLTemplateCache.archive_identity(properties, archive)
        end

        def cache_connection(database, &)
          require "pg"
          require_relative "postgresql_template_cache"

          ::PG.connect(connection_options.merge(dbname: database), &)
        rescue LoadError, ::PG::Error
          nil
        end

        def template_available?
          sql(<<~SQL).strip == "t"
            SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '#{@parent}')
               AND NOT EXISTS (SELECT 1 FROM pg_prepared_xacts WHERE database = '#{@parent}')
          SQL
        rescue ArgumentError => e
          raise unless TEMPLATE_REJECTION.match?(e.message)

          false
        end

        def clone_database(database, quoted_template, query = method(:sql))
          create_database(database) do
            query.call("CREATE DATABASE #{identifier(database)} TEMPLATE #{quoted_template}")
          end
          true
        rescue ArgumentError => e
          raise unless TEMPLATE_REJECTION.match?(e.message)

          File.unlink(marker(database))
          false
        end

        def seal_template(template)
          sql("ALTER DATABASE #{identifier(template)} ALLOW_CONNECTIONS false")
          true
        rescue ArgumentError => e
          raise unless TEMPLATE_REJECTION.match?(e.message)

          false
        end

        def duplicate_database?(error)
          error.message.include?("42P04:")
        end

        def drop_database(database)
          statement = "DROP DATABASE IF EXISTS #{identifier(database)}"
          sql("#{statement} WITH (FORCE)")
        rescue ArgumentError => e
          raise unless e.message.include?("42601:")

          sql(statement)
        end

        def dump(database, output)
          command(environment, "pg_dump", "--no-password", "--format=custom", "--file=#{output}", "--dbname=#{database}")
        end

        def restore_dump(input, database)
          command(environment, "pg_restore", "--no-password", "--exit-on-error", "--no-owner", "--no-privileges", "--dbname=#{database}",
                  input)
        end

        def sql(statement)
          command(environment, "psql", "--no-password", "--no-psqlrc", "--dbname=postgres", "--set=ON_ERROR_STOP=1",
                  "--set=VERBOSITY=verbose", "--tuples-only", "--no-align", "--command=#{statement}")
        end

        def quote
          '"'
        end

        def connection_options
          { host: @config[:host], port: @config[:port], user: @config[:username], password: @config[:password],
            sslmode: @config[:sslmode], connect_timeout: 5 }.compact.transform_values(&:to_s)
        end

        def environment
          connection_options.to_h { |option, value| [CONNECTION_ENV.fetch(option), value] }
        end
      end

      class MySQL < Server
        private

        def duplicate_database?(error)
          error.message.include?("ERROR 1007 (")
        end

        def drop_database(database)
          sql("DROP DATABASE IF EXISTS #{identifier(database)}")
        end

        def dump(database, output)
          command(environment, "mysqldump", "--no-defaults", *connection_options, "--single-transaction", "--skip-lock-tables",
                  "--no-tablespaces", "--set-gtid-purged=OFF", "--column-statistics=0", "--result-file=#{output}", "--", database)
        end

        def restore_dump(input, database)
          File.open(input, "rb") do |dump|
            command(environment, "mysql", "--no-defaults", *connection_options, "--database=#{database}", stdin_data: dump)
          end
        end

        def sql(statement)
          command(environment, "mysql", "--no-defaults", *connection_options, "--execute=#{statement}")
        end

        def quote
          "`"
        end

        def connection_options
          { "host" => @config[:host], "port" => @config[:port], "socket" => @config[:socket], "user" => @config[:username],
            "ssl-ca" => @config[:sslca], "ssl-capath" => @config[:sslcapath], "ssl-cert" => @config[:sslcert],
            "ssl-key" => @config[:sslkey], "ssl-mode" => @config[:ssl_mode] }.compact.map { |option, value| "--#{option}=#{value}" }
        end

        def environment
          @config[:password] ? { "MYSQL_PWD" => @config[:password].to_s } : {}
        end
      end
    end
  end
end
