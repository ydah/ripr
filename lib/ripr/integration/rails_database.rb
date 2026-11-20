# frozen_string_literal: true

require "open3"
require "securerandom"

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

        alias restore dump

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
          reservation = marker(database)
          File.open(reservation, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.puts(database) }
          begin
            sql("CREATE DATABASE #{identifier(database)}")
          rescue ArgumentError => e
            File.unlink(reservation) if duplicate_database?(e)
            raise
          end
          restore_dump(input, database)
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
          raise ArgumentError, "invalid isolated Rails database name" unless database.match?(/\A#{@stem}_(?:parent|worker_\d+)\z/)

          "#{quote}#{database}#{quote}"
        end

        def command(environment, *arguments, stdin_data: "")
          _, error, status = Open3.capture3(environment, *arguments, stdin_data: stdin_data)
          return if status.success?

          raise ArgumentError, "Rails database command #{arguments.first} failed: #{error.strip}"
        rescue Errno::ENOENT
          raise ArgumentError, "Rails database command #{arguments.first} was not found on PATH"
        end
      end

      class PostgreSQL < Server
        private

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
                  "--set=VERBOSITY=verbose", "--command=#{statement}")
        end

        def quote
          '"'
        end

        def environment
          { "PGHOST" => @config[:host], "PGPORT" => @config[:port], "PGUSER" => @config[:username],
            "PGPASSWORD" => @config[:password], "PGSSLMODE" => @config[:sslmode] }.compact.transform_values(&:to_s)
            .merge("PGCONNECT_TIMEOUT" => "5")
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
