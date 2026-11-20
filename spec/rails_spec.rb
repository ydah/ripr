# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Rails boot safety" do
  it "rejects a production environment before loading application code" do
    lib = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      require "ripr/integration/rails"
      begin
        Ripr::Integration::Rails.new.prepare
      rescue ArgumentError => error
        puts error.message
      end
    RUBY
    output, error, status = Open3.capture3({ "RAILS_ENV" => "production" }, RbConfig.ruby, "-I", lib, "-e", script)

    expect(status.success?).to be(true), error
    expect(output).to include("RAILS_ENV=test")
  end

  if ENV["RIPR_TEST_RAILS"]
    it "blocks explicit connections from config/boot.rb before initialization" do
      lib = File.expand_path("../lib", __dir__)
      Dir.mktmpdir("ripr-early-rails-boot") do |directory|
        Dir.mkdir(File.join(directory, "config"))
        File.write(File.join(directory, "config/environment.rb"), "")
        File.write(File.join(directory, "config/boot.rb"), <<~RUBY)
          require "active_record"
          ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: "original.sqlite3")
          ActiveRecord::Base.connection.execute("CREATE TABLE unexpected (id integer)")
        RUBY
        script = <<~RUBY
          require "ripr/integration/rails"
          rails = Ripr::Integration::Rails.new
          begin
            rails.prepare
          rescue ArgumentError => error
            puts error.message
          ensure
            rails.close
          end
        RUBY
        env = { "RAILS_ENV" => nil, "RACK_ENV" => nil }
        output, error, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", script, chdir: directory)
        expect(status.success?).to be(true), error
        expect(output).to include("must use an isolated Rails test database")
        expect(File.exist?(File.join(directory, "original.sqlite3"))).to be(false)
      end
    end
  end
end
