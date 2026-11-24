# frozen_string_literal: true

require "rubygems"
require_relative "../lib/ripr/version"

version = Gem::Version.new(Ripr::VERSION).to_s
abort "expected release tag v#{version}, got #{ARGV.first.inspect}" unless ARGV.first == "v#{version}"

heading = "## #{version} — "
changelog = File.read(File.expand_path("../CHANGELOG.md", __dir__), encoding: "UTF-8")
section = changelog.split(/(?=^## )/).find { |entry| entry.start_with?(heading) }
notes = section.to_s.lines.drop(1).join.strip
abort "missing changelog notes for #{version}" if notes.empty?

puts notes
