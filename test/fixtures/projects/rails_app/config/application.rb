# frozen_string_literal: true

require_relative "boot"
require "rails"
require "active_record/railtie"

module RiprFixture
  class Application < Rails::Application
    config.load_defaults 8.1
    config.eager_load = false
    config.active_record.maintain_test_schema = false

    config.after_initialize do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.create_table(:widgets, if_not_exists: true) do |table|
          table.string :label
          table.integer :stock
        end
        connection.execute("INSERT INTO widgets (label, stock) VALUES ('booted', 12)")
      end
    end
  end
end
