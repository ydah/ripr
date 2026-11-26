# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require_relative "rails_database"

module Ripr
  module Integration
    class Rails
      WORKER_CONFIG = "RIPR_RAILS_WORKER_CONFIG"

      def initialize(boot: nil)
        @root = Dir.pwd
        @boot = File.expand_path(boot || "config/environment.rb", @root)
        @databases = {}
        @database_configs = []
      end

      def prepare
        %w[RAILS_ENV RACK_ENV].each do |name|
          value = ENV.fetch(name, nil)
          raise ArgumentError, "Rails mutation testing requires #{name}=test" if value && !value.empty? && value != "test"
        end
        raise ArgumentError, "Rails application was initialized before ripr" if initialized?
        raise ArgumentError, "Rails boot file not found: #{@boot}" unless File.file?(@boot)

        @environment = %w[RAILS_ENV RACK_ENV DISABLE_SPRING].to_h { |name| [name, ENV.fetch(name, nil)] }
        ENV.update("RAILS_ENV" => "test", "RACK_ENV" => "test", "DISABLE_SPRING" => "1")
        @inherited = ENV.fetch(WORKER_CONFIG, nil)
        require "active_support/lazy_load_hooks"
        ::ActiveSupport.on_load(:active_record, yield: true, run_once: true) do |base|
          guard_connections(base.connection_handler.class)
        end
        boot_config = File.join(@root, "config/boot.rb")
        require boot_config if File.file?(boot_config)
        raise ArgumentError, "Rails application was initialized before ripr" if initialized?
      end

      def boot
        ::ActiveSupport.on_load(:before_initialize, yield: true, run_once: true) do |application|
          raise ArgumentError, "Rails mutation testing requires RAILS_ENV=test" unless ::Rails.env.test?

          configure_databases(application.config) if defined?(::ActiveRecord::Railtie)
        end
        require @boot
        raise ArgumentError, "Rails boot file did not initialize the application: #{@boot}" unless initialized?
      end

      def prepare_workers(jobs)
        @jobs = jobs
        return if @database_configs.empty? || @inherited

        base = ::ActiveRecord::Base
        @pool_configs = (base.configurations.configs_for(env_name: "test", include_hidden: true) +
                         base.connection_handler.connection_pool_list(:all).map(&:db_config)).uniq
        allowed = @database_configs.map { |config| [endpoint(config), config.database] }
        unless @pool_configs.all? { |config| allowed.include?([endpoint(config), config.database]) }
          raise ArgumentError, "Rails mutation testing requires Active Record connections from the isolated test configuration"
        end

        disconnect
        @databases.values.uniq.each(&:capture)
      end

      def worker_timeout_ms
        @databases.values.any?(&:server?) ? 30_000 : 0
      end

      def cache_snapshot_paths
        return if @inherited || @databases.values.any?(&:server?)

        @databases.values.flat_map(&:snapshot_paths)
      end

      def with_worker(slot, fresh_boot: false)
        previous = ENV.fetch("TEST_ENV_NUMBER", nil)
        previous_manifest = ENV.fetch(WORKER_CONFIG, nil)
        raise ArgumentError, "invalid Rails worker slot: #{slot.inspect}" unless slot.is_a?(Integer) && (0...@jobs).cover?(slot)

        ENV["TEST_ENV_NUMBER"] = slot.zero? ? "" : (slot + 1).to_s
        return yield if @databases.empty?

        worker_started = true
        destinations = @databases.values.uniq.to_h do |database|
          [database.parent, database.worker(slot, fresh_boot: fresh_boot)]
        end
        if fresh_boot
          manifest = @database_configs.to_h do |config|
            [config.name, { "endpoint" => endpoint(config), "database" => destinations.fetch(config.database) }]
          end
          ENV[WORKER_CONFIG] = File.join(@directory, "worker-#{slot}.json")
          File.write(ENV.fetch(WORKER_CONFIG), JSON.generate(manifest), perm: 0o600)
        else
          parent_databases = @pool_configs.to_h { |config| [config, config.database] }
          parent_databases.each { |config, database| config._database = destinations.fetch(database) }
        end
        yield
      ensure
        begin
          if worker_started
            disconnect unless fresh_boot
            parent_databases&.each { |config, database| config._database = database }
            @databases.values.uniq.each { |database| database.release_worker(slot) }
          end
        ensure
          ENV["TEST_ENV_NUMBER"] = previous
          ENV[WORKER_CONFIG] = previous_manifest
        end
      end

      def close
        disconnect unless @database_configs.empty?
        @databases.values.uniq.each(&:close)
        FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
      ensure
        @connection_hook&.remove_method(:establish_connection)
        @configuration_hook&.remove_method(:database_configuration)
        @environment&.each { |name, value| ENV[name] = value }
      end

      private

      def initialized?
        defined?(::Rails) && ::Rails.application&.initialized?
      end

      def configure_databases(config)
        require "active_record/database_configurations"
        configs = ::ActiveRecord::DatabaseConfigurations.new(config.database_configuration)
        test_configs = configs.configs_for(env_name: "test", include_hidden: true)
        raise ArgumentError, "Rails application has no test database configuration" if test_configs.empty?

        @database_configs = if @inherited
                              inherited_configs(test_configs)
                            else
                              isolate_configs(test_configs, configs.configurations - test_configs)
                            end
        databases = @database_configs
        @configuration_hook = Module.new do
          define_method(:database_configuration) { databases }
        end
        config.singleton_class.prepend(@configuration_hook)
      end

      def guard_connections(connection_handler)
        isolation = self
        @connection_hook = Module.new do
          define_method(:establish_connection) do |config, **options|
            isolation.__send__(:validate_connection, config)
            super(config, **options)
          end
        end
        connection_handler.prepend(@connection_hook)
      end

      def validate_connection(config)
        resolved = ::ActiveRecord::Base.configurations.resolve(config)
        return if @database_configs.any? { |allowed| endpoint(allowed) == endpoint(resolved) && allowed.database == resolved.database }

        raise ArgumentError, "Active Record connections must use an isolated Rails test database"
      end

      def isolate_configs(test_configs, other_configs)
        shared = test_configs.find do |config|
          config.database != ":memory:" && other_configs.any? { |other| identity(other) == identity(config) }
        end
        raise ArgumentError, "Rails test database #{shared.name.inspect} is also configured outside test" if shared

        @directory = File.realpath(Dir.mktmpdir("ripr-rails-"))
        test_configs.map do |config|
          database = (@databases[identity(config)] ||= RailsDatabase.build(config, @root, @directory, @databases.size))
          sandbox_config(config, database.parent)
        end
      end

      def inherited_configs(test_configs)
        path = File.realpath(@inherited)
        stat = File.stat(path)
        unless stat.file? && stat.uid == Process.uid && stat.mode.nobits?(0o077) && File.basename(path).match?(/\Aworker-\d+\.json\z/)
          raise ArgumentError, "invalid Rails worker configuration"
        end

        manifest = JSON.parse(File.read(path))
        test_configs.map do |config|
          entry = manifest.fetch(config.name)
          database = entry.fetch("database")
          unless entry.fetch("endpoint") == endpoint(config) && RailsDatabase.worker_database?(config, database, File.dirname(path))
            raise ArgumentError, "invalid Rails worker database for #{config.name.inspect}"
          end

          sandbox_config(config, database)
        end
      end

      def sandbox_config(config, database)
        ::ActiveRecord::DatabaseConfigurations::HashConfig.new("test", config.name, config.configuration_hash.merge(database: database))
      end

      def disconnect
        ::ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
      end

      def endpoint(config)
        [config.adapter, *config.configuration_hash.values_at(:host, :port, :socket)]
      end

      def identity(config)
        database = config.database
        if config.adapter == "sqlite3" && database && database != ":memory:"
          candidate = File.expand_path(database, @root)
          database = File.exist?(candidate) ? File.realpath(candidate) : candidate
        end
        [endpoint(config), database]
      end
    end
  end
end
