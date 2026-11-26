# frozen_string_literal: true

require "digest"
require "json"
require_relative "../lib/ripr/core/analyzer"

def normalize(value)
  return value unless value.is_a?(Array)

  normalized = value.map { |item| normalize(item) }
  metadata = value[4]
  return normalized unless value.first == "YARVInstructionSequence/SimpleDataFormat" && metadata.is_a?(Hash) && metadata[:code_location]

  line, _, last_line, = metadata.fetch(:code_location)
  normalized[4] = metadata.except(:node_id, :node_ids).merge(code_location: [line, last_line])
  normalized
end

def signature(source, path)
  iseq = RubyVM::InstructionSequence.compile(source, path, path)
  Digest::SHA256.hexdigest(Marshal.dump(normalize(iseq.to_a)))
end

base = "def example; if true; 1; else; 2; end; end"
same = "def example; if true; 1; else; 300; end; end"
different = "def example; if true; 9; else; 2; end; end"
abort "Usage: ruby script/measure_tce.rb FILE ..." if ARGV.empty?
control = signature(base, "control.rb")
abort "dead branch control compiled differently" unless control == signature(same, "control.rb")
abort "different return values compiled identically" if control == signature(different, "control.rb")

results = ARGV.map do |path|
  analysis = Ripr::Core::Analyzer.call(File.binread(path), File.basename(path), operators: Ripr::Core::Operators::FULL_NAMES)
  source = analysis.fetch(:source)
  original = signature(source, path)
  unsupported = Ripr::Core::Instrumenter.call(source, path, analysis.fetch(:sites)).fetch(:invalid)
  mutants = analysis.fetch(:mutants).reject { |entry| entry[:accepted] || entry[:invalid] || unsupported.include?(entry.fetch(:id)) }
  matches = []
  groups = Hash.new { |hash, bytecode| hash[bytecode] = [] }
  errors = []
  mutants.each do |mutant|
    key = mutant.fetch(:full_id)
    changed = Ripr::Core::Instrumenter.mutate(source, mutant)
    mutation = signature(changed, path)
    if mutation == original
      matches << key
    else
      groups[mutation] << key
    end
  rescue SyntaxError, TypeError => e
    errors << { "id" => key, "message" => e.message }
  end
  duplicates = groups.values.select { |group| group.length > 1 }
  { "file" => path, "source_sha256" => Digest::SHA256.hexdigest(source), "planned" => mutants.size,
    "compiled" => mutants.size - errors.size, "matches" => matches, "duplicates" => duplicates, "errors" => errors }
end
puts JSON.pretty_generate("ruby" => RUBY_DESCRIPTION, "results" => results)
exit 1 if results.any? { |result| !result.fetch("errors").empty? }
