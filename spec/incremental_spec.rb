# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "open3"
%w[git snapshot accept_ledger core/reuse_planner].each do |name|
  file = File.expand_path("../lib/ripr/#{name}.rb", __dir__)
  require file if File.file?(file)
end

RSpec.describe "incremental mutation results" do
  def git_command(directory, *arguments)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments)
    raise error unless status.success?

    output
  end

  def with_repository
    Dir.mktmpdir("ripr-git") do |directory|
      git_command(directory, "init", "-q")
      git_command(directory, "config", "user.name", "Ripr Test")
      git_command(directory, "config", "user.email", "test@example.test")
      yield directory
    end
  end

  def commit(directory)
    git_command(directory, "add", "--all")
    git_command(directory, "commit", "-qm", "fixture")
  end

  def mutant
    { "id" => "abc123", "full_id" => "lib/a.rb::A#x::body.0::comparison::>", "method_hash" => "method-one",
      "operator" => "comparison", "original" => "x >= 18", "mutated" => "x > 18" }
  end

  it "finds staged, unstaged, and untracked lines without shell interpolation" do
    with_repository do |directory|
      File.write(File.join(directory, "space 日本語.rb"), "first\nsecond\nthird\n")
      File.write(File.join(directory, "staged.rb"), "first\nsecond\n")
      commit(directory)
      File.write(File.join(directory, "space 日本語.rb"), "first\nchanged\nthird\n")
      File.write(File.join(directory, "staged.rb"), "first\nchanged\n")
      git_command(directory, "add", "staged.rb")
      File.write(File.join(directory, "new $(echo unsafe).rb"), "one\ntwo\n")
      changed = Ripr::Git.new(directory).changed_lines("HEAD")
      expect(changed).to eq("space 日本語.rb" => [2], "staged.rb" => [2], "new $(echo unsafe).rb" => [1, 2])
      expect(Ripr::Git.new(directory).changed_lines("HEAD", ["staged.rb"])).to eq("staged.rb" => [2])
    end
  end

  it "marks both sides of a deletion and ignores deleted source files" do
    with_repository do |directory|
      File.write(File.join(directory, "a.rb"), "one\ntwo\nthree\nfour\n")
      File.write(File.join(directory, "deleted.rb"), "removed\n")
      commit(directory)
      File.write(File.join(directory, "a.rb"), "one\nthree\nfour\n")
      File.unlink(File.join(directory, "deleted.rb"))
      expect(Ripr::Git.new(directory).changed_lines("HEAD")).to eq("a.rb" => [1, 2])
    end
  end

  it "tracks edited renames using the destination path" do
    with_repository do |directory|
      original = (1..15).map { |line| "line #{line}\n" }.join
      File.write(File.join(directory, "old file.rb"), original)
      commit(directory)
      git_command(directory, "mv", "old file.rb", "renamed file.rb")
      File.write(File.join(directory, "renamed file.rb"), original.sub("line 8\n", "changed\n"))
      expect(Ripr::Git.new(directory).changed_lines("HEAD")).to eq("renamed file.rb" => [8])
    end
  end

  it "takes the merge base and treats a pure rename as unchanged" do
    with_repository do |directory|
      File.write(File.join(directory, "a.rb"), "base\n")
      commit(directory)
      git_command(directory, "branch", "base")
      File.write(File.join(directory, "a.rb"), "head\n")
      commit(directory)
      expect(Ripr::Git.new(directory).changed_lines("base")).to eq("a.rb" => [1])
      git_command(directory, "mv", "a.rb", "b.rb")
      expect(Ripr::Git.new(directory).changed_lines("HEAD")).to be_empty
      expect { Ripr::Git.new(directory).changed_lines("unknown-ref") }.to raise_error(Ripr::Error, /git/)
    end
  end

  it "returns paths relative to a project inside a repository" do
    with_repository do |directory|
      project = File.join(directory, "project")
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "a.rb"), "before\n")
      commit(directory)
      File.write(File.join(project, "a.rb"), "after\n")
      expect(Ripr::Git.new(project).changed_lines("HEAD")).to eq("a.rb" => [1])
    end
  end

  it "round trips versioned snapshots atomically and ignores damaged cache files" do
    Dir.mktmpdir("ripr-snapshot") do |directory|
      path = File.join(directory, ".ripr", "snapshot.json")
      snapshot = Ripr::Snapshot.new(path)
      expect(snapshot.read).to eq({})
      data = { "version" => Ripr::Snapshot::VERSION, "mutants" => { mutant.fetch("full_id") => mutant } }
      snapshot.write(data)
      expect(snapshot.read).to eq(data)
      allow(File).to receive(:rename).and_raise(IOError, "disk failure")
      expect { snapshot.write("version" => Ripr::Snapshot::VERSION, "mutants" => {}) }.to raise_error(IOError)
      expect(JSON.parse(File.read(path))).to eq(data)
      expect(Dir.children(File.dirname(path))).to eq(["snapshot.json"])
      File.write(path, "bad json")
      expect { expect(snapshot.read).to eq({}) }.to output(/snapshot/).to_stderr
      File.write(path, '{"version":999}')
      expect { expect(snapshot.read).to eq({}) }.to output(/snapshot/).to_stderr
      File.write(path, JSON.generate("version" => Ripr::Snapshot::VERSION, "mutants" => []))
      expect { expect(snapshot.read).to eq({}) }.to output(/snapshot/).to_stderr
    end
  end

  it "reuses only matching identities, methods, environments, and test hashes" do
    record = mutant.merge("env_hash" => "environment", "status" => "killed", "tests" => { "test/a_test.rb" => "test-one" })
    options = { env_hash: "environment", test_hashes: { "test/a_test.rb" => "test-one" } }
    expect(Ripr::Core::ReusePlanner.reusable?(record, mutant, **options)).to be(true)
    %w[full_id method_hash env_hash].each do |key|
      expect(Ripr::Core::ReusePlanner.reusable?(record.merge(key => "changed"), mutant, **options)).to be(false)
    end
    expect(Ripr::Core::ReusePlanner.reusable?(record, mutant, **options, test_hashes: {})).to be(false)
    expect(Ripr::Core::ReusePlanner.reusable?(record, mutant, **options, test_hashes: { "test/a_test.rb" => "changed" })).to be(false)
    expect(Ripr::Core::ReusePlanner.reusable?(record, mutant, **options, newly_reached: [mutant.fetch("id")])).to be(false)
    %w[accepted invalid error static].each do |status|
      expect(Ripr::Core::ReusePlanner.reusable?(record.merge("status" => status), mutant, **options)).to be(false)
    end
    expect(Ripr::Core::ReusePlanner.reusable?(nil, mutant, **options)).to be(false)
  end

  it "discards snapshots recorded before late loader hooks were supported" do
    Dir.mktmpdir("ripr-old-snapshot") do |directory|
      path = File.join(directory, "snapshot.json")
      File.write(path, JSON.generate("version" => 2, "mutants" => { mutant.fetch("full_id") => mutant }))
      expect { expect(Ripr::Snapshot.new(path).read).to eq({}) }.to output(/unsupported snapshot/).to_stderr
    end
  end

  it "persists acceptances, updates reasons, and invalidates edited methods" do
    Dir.mktmpdir("ripr-ledger") do |directory|
      ledger = Ripr::AcceptLedger.new(File.join(directory, "ripr.accepted.yml"))
      expect(ledger.read).to eq([])
      ledger.accept(mutant, reason: "Equivalent within the public contract")
      expect(ledger.reason_for(mutant)).to eq("Equivalent within the public contract")
      expect(ledger.stale?(mutant)).to be(false)
      changed = mutant.merge("method_hash" => "method-two")
      expect(ledger.reason_for(changed)).to be_nil
      expect(ledger.stale?(changed)).to be(true)
      ledger.accept(changed, reason: "Reviewed after the change")
      expect(ledger.read.length).to eq(1)
      expect(ledger.reason_for(changed)).to eq("Reviewed after the change")
      expect(ledger.read.first.fetch("recorded_at")).to match(/Z\z/)
      expect { ledger.accept(mutant, reason: " ") }.to raise_error(Ripr::Error, /reason/)
    end
  end

  it "rejects corrupt or unsafe acceptance ledgers without overwriting them" do
    Dir.mktmpdir("ripr-ledger") do |directory|
      path = File.join(directory, "ripr.accepted.yml")
      ledger = Ripr::AcceptLedger.new(path)
      File.write(path, "--- !ruby/object:Object {}\n")
      expect { ledger.read }.to raise_error(Ripr::Error, /ledger/)
      expect { ledger.accept(mutant, reason: "test") }.to raise_error(Ripr::Error, /ledger/)
      expect(File.read(path)).to include("!ruby/object")
      File.write(path, "not: an array\n")
      expect { ledger.read }.to raise_error(Ripr::Error, /ledger/)
    end
  end
end
