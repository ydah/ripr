# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "GitHub Actions reach maps" do
  let(:action_script) { File.expand_path("../script/reach_map_action.sh", __dir__) }

  def git(directory, *arguments)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments)
    raise error unless status.success?

    output.strip
  end

  def with_checkout
    Dir.mktmpdir("ripr-reach-map-action") do |directory|
      project = File.join(directory, "project")
      tools = File.join(directory, "bin")
      FileUtils.mkdir_p([project, tools])
      git(project, "init", "-q", "-b", "main")
      git(project, "-c", "user.name=Ripr Test", "-c", "user.email=test@example.test", "-c", "commit.gpgSign=false", "commit",
          "--allow-empty", "-qm", "fixture")
      File.write(File.join(tools, "bundle"), <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        if ARGV == %w[exec ripr reach-map]
          Dir.mkdir(".ripr") unless File.directory?(".ripr")
          File.write(".ripr/reach-map.json", "{}")
        end
        puts JSON.generate("args" => ARGV, "env" => ENV.to_h)
      RUBY
      File.write(File.join(tools, "gh"), <<~SH)
        #!/usr/bin/env bash
        set -eu
        test "$GH_TOKEN" = fake-token
        if [[ $1 == api ]]; then
          printf '%s\\n' "$RIPR_TEST_RUNS"
        else
          test "$1 $2 $3" = 'run download 42'
          test "$4 $5 $6" = '--repo example/project --name'
          [[ $7 == ripr-reach-map-* && $8 == --dir ]]
          printf '{}' > "$9/reach-map.json"
        fi
      SH
      FileUtils.chmod(0o755, Dir.glob(File.join(tools, "*")))
      base = git(project, "rev-parse", "HEAD")
      env = { "PATH" => "#{tools}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}", "RUNNER_TEMP" => directory,
              "GITHUB_OUTPUT" => File.join(directory, "output"), "GITHUB_REPOSITORY" => "example/project", "GITHUB_SHA" => base,
              "GH_TOKEN" => "fake-token", "GITHUB_TOKEN" => "other-token", "GITHUB_WORKSPACE" => project,
              "GITHUB_REF" => "refs/heads/main", "GITHUB_EVENT_NAME" => "push", "GITHUB_RUN_ID" => "1234",
              "RIPR_ACTION_DEFAULT_BRANCH" => "main", "RIPR_ACTION_BASE_BRANCH" => "", "RIPR_ACTION_SINCE" => "main",
              "RIPR_ACTION_REACH_MAP_WORKFLOW" => "mutations.yml", "RIPR_ACTION_REACH_MAP_ENV" => "APP_MODE",
              "RIPR_ACTION_FAIL" => "true", "RIPR_ACTION_THRESHOLD" => "80", "APP_MODE" => "fixtures",
              "RIPR_TEST_RUNS" => '{"workflow_runs":[]}' }
      yield project, env, base
    end
  end

  def run_action(project, env, mode, overrides = {})
    Open3.capture3(env.merge("RIPR_ACTION_REACH_MAP" => mode).merge(overrides), "bash", action_script, chdir: project)
  end

  def matching_run(base)
    { "id" => 42, "head_sha" => base, "head_branch" => "main", "head_repository" => { "full_name" => "example/project" },
      "event" => "push", "status" => "completed", "conclusion" => "success" }
  end

  it "publishes only the map and gives capture and replay the same workload environment" do
    with_checkout do |project, env, base|
      stdout, error, status = run_action(project, env, "record")
      expect(status.success?).to be(true), error
      record = JSON.parse(stdout)
      outputs = File.readlines(env.fetch("GITHUB_OUTPUT"), chomp: true).to_h { |line| line.split("=", 2) }
      expect(outputs.fetch("artifact-name")).to start_with("ripr-reach-map-")
      expect(File.read(outputs.fetch("artifact-path"))).to eq("{}")
      expect(record.fetch("args")).to eq(%w[exec ripr reach-map])

      runs = { "workflow_runs" => [matching_run(base).merge("id" => 41, "event" => "pull_request"), matching_run(base)] }
      replay_env = { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_RUN_ID" => "5678", "RIPR_TEST_RUNS" => JSON.generate(runs) }
      stdout, error, status = run_action(project, env, "use", replay_env)
      expect(status.success?).to be(true), error
      replay = JSON.parse(stdout)
      run_args = %w[exec ripr --reporter text --reporter github --since main --fail-on-survived --threshold 80]
      expect(replay.fetch("args")[0...-2]).to eq(run_args)
      expect(replay.fetch("args")[-2]).to eq("--reach-map")
      expect(File.read(replay.fetch("args").last)).to eq("{}")
      expect(replay.fetch("env")).to eq(record.fetch("env"))
      expect(replay.fetch("env")).to include("APP_MODE" => "fixtures", "GITHUB_WORKSPACE" => project)
      expect(replay.fetch("env").keys).not_to include("GH_TOKEN", "GITHUB_TOKEN", "GITHUB_RUN_ID")
    end
  end

  it "runs ordinary diff selection when no trusted base artifact is available" do
    with_checkout do |project, env, base|
      runs = { "workflow_runs" => [matching_run(base).merge("head_sha" => "foreign")] }
      stdout, error, status = run_action(project, env, "use", "RIPR_TEST_RUNS" => JSON.generate(runs))
      expect(status.success?).to be(true), error
      expect(error).to include("No trusted reach map")
      expect(JSON.parse(stdout).fetch("args")).not_to include("--reach-map")
    end
  end

  it "names maps by the workload environment rather than the Actions run" do
    with_checkout do |project, env|
      overrides = [{}, { "GITHUB_RUN_ID" => "5678", "GITHUB_ENV" => "/runner/step.env" }, { "APP_MODE" => "alternate" }]
      names = overrides.map do |changes|
        _, error, status = run_action(project, env, "record", changes)
        expect(status.success?).to be(true), error
        File.readlines(env.fetch("GITHUB_OUTPUT"), chomp: true).grep(/^artifact-name=/).last
      end

      expect(names.uniq).to eq([names.first, names.last])
    end
  end

  it "rejects recording from untrusted events, non-default refs, or a different checkout" do
    with_checkout do |project, env|
      [{ "GITHUB_EVENT_NAME" => "pull_request_target" }, { "GITHUB_REF" => "refs/heads/topic" },
       { "GITHUB_SHA" => "other-checkout" }].each do |overrides|
        _, error, status = run_action(project, env, "record", overrides)
        expect(status.success?).to be(false)
        expect(error).to include("default-branch checkout")
      end
      expect(File).not_to exist(File.join(project, ".ripr/reach-map.json"))
    end
  end

  it "rejects use in a pull_request_target workflow and forwarding of tokens or command files" do
    with_checkout do |project, env|
      _, error, status = run_action(project, env, "use", "GITHUB_EVENT_NAME" => "pull_request_target")
      expect(status.success?).to be(false)
      expect(error).to include("requires a pull_request workflow")

      %w[GH_TOKEN ACTIONS_RUNTIME_TOKEN GITHUB_OUTPUT].each do |name|
        _, error, status = run_action(project, env, "record", "RIPR_ACTION_REACH_MAP_ENV" => "APP_MODE #{name}")
        expect(status.success?).to be(false)
        expect(error).to include("excludes GitHub tokens and workflow command files")
      end
      expect(File).not_to exist(File.join(project, ".ripr/reach-map.json"))
    end
  end
end
