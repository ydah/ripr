# frozen_string_literal: true

require "digest"
require "open3"
require "securerandom"

module Ripr
  module Integration
    class RailsDatabase
      class PostgreSQLTemplateCache
        LOCK_KEY = "pg_catalog.hashtextextended($1, 0)"

        class SlotChanged < StandardError; end

        def self.snapshot_properties(session)
          session.exec(<<~SQL).first&.values
            SELECT pg_catalog.to_jsonb(database) - ARRAY['oid', 'datname', 'datfrozenxid', 'datminmxid'] AS properties,
                   (SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(stats) - ARRAY['tableid', 'attnum']
                                                ORDER BY schemaname, tablename, attname, inherited)
                    FROM pg_catalog.pg_stats AS stats
                    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')) AS statistics,
                   (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(nspname, relname, relpages, reltuples, relallvisible)
                                                ORDER BY nspname, relname)
                    FROM pg_catalog.pg_class JOIN pg_catalog.pg_namespace ON pg_namespace.oid = relnamespace
                    WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')) AS relations
              FROM pg_catalog.pg_database AS database
             WHERE datname = pg_catalog.current_database()
               AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname <> 'plpgsql')
               AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class
                               WHERE relkind = 'f' OR (relkind = 'm' AND relispopulated) OR relpersistence IN ('t', 'u'))
               AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend
                               WHERE classid = 'pg_catalog.pg_class'::pg_catalog.regclass AND deptype = 'e')
               AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute WHERE attgenerated <> '' AND NOT attisdropped)
               AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index WHERE NOT (indisvalid AND indisready AND indislive))
               AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_statistic_ext)
          SQL
        end

        def self.archive_identity(properties, archive)
          digest = Digest::SHA256.new.update("#{properties.join("\0")}\0")
          # The fixed restrict key makes the SQL comparable. This output is never executed.
          Open3.popen2("pg_restore", "--restrict-key=riprWorkerTemplate", "--file=-", archive, err: File::NULL) do |input, output, process|
            input.close
            output.binmode
            while (chunk = output.read(65_536))
              digest.update(chunk)
            end
            digest.hexdigest if process.value.success?
          end
        rescue Errno::ENOENT
          nil
        end

        attr_reader :quoted_name

        def initialize(session, scope)
          @session = session
          role = @session.exec("SELECT current_user").getvalue(0, 0)
          namespace = Digest::SHA256.hexdigest([*scope, role].join("\0")).slice(0, 32)
          @name = "ripr_test_cache_#{namespace}"
          @quoted_name = @session.quote_ident(@name)
          @marker = "ripr:ready-template:v1:#{namespace}:"
        end

        def with_lock(parent:, shared:)
          function = shared ? "pg_try_advisory_lock_shared" : "pg_try_advisory_lock"
          lock = @session.exec_params(<<~SQL, [@name, parent])
            SELECT pg_catalog.#{function}(#{LOCK_KEY}) AS locked
              FROM pg_catalog.pg_database
             WHERE datname = $2 AND NOT pg_catalog.pg_is_in_recovery()
          SQL
          yield self if lock.first&.fetch("locked") == "t"
        end

        def downgrade_lock
          @session.exec_params("SELECT pg_catalog.pg_advisory_lock_shared(#{LOCK_KEY})", [@name])
          @session.exec_params("SELECT pg_catalog.pg_advisory_unlock(#{LOCK_KEY})", [@name])
        end

        def identity
          owned_identity(entry(@name))
        end

        def publish(template, digest)
          previous = entry(@name)
          current = owned_identity(previous)
          return if current == false || current == digest

          retired = "#{@name}_#{SecureRandom.hex(7)}" if previous
          @session.transaction do
            if retired
              @session.exec("ALTER DATABASE #{@quoted_name} RENAME TO #{@session.quote_ident(retired)}")
              raise SlotChanged unless entry(retired) == previous
            end
            @session.exec("COMMENT ON DATABASE #{template} IS #{@session.escape_literal(@marker + digest)}")
            @session.exec("ALTER DATABASE #{template} RENAME TO #{@quoted_name}")
          end
          drop_retired(retired, previous) if retired
          digest
        rescue SlotChanged
          nil
        end

        def execute(statement)
          @session.exec(statement)
        rescue ::PG::Error => e
          state = e.result&.error_field(::PG::Result::PG_DIAG_SQLSTATE)
          raise ArgumentError, "Rails PostgreSQL template command failed: #{state}: #{e.message.strip}"
        end

        private

        def entry(name)
          @session.exec_params(<<~SQL, [name]).first
            SELECT oid, (NOT datallowconn AND NOT datistemplate
                    AND datdba = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = current_user)) AS owned,
                   pg_catalog.shobj_description(oid, 'pg_database') AS marker
              FROM pg_catalog.pg_database
             WHERE datname = $1
          SQL
        end

        def owned_identity(entry)
          return unless entry
          return false unless entry.fetch("owned") == "t"

          entry.fetch("marker").to_s[/\A#{Regexp.escape(@marker)}([a-f0-9]{64})\z/, 1] || false
        end

        def drop_retired(name, previous)
          @session.exec("DROP DATABASE #{@session.quote_ident(name)}") if entry(name) == previous
        rescue ::PG::Error
          nil
        end
      end
    end
  end
end
