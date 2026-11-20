# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

RSpec.describe "ripr MCP stdio" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }
  let(:fixture) { File.expand_path("../test/fixtures/projects/minitest_basic", __dir__) }
  let(:modern_meta) do
    { "io.modelcontextprotocol/protocolVersion" => "2026-07-28", "io.modelcontextprotocol/clientCapabilities" => {} }
  end

  def exchange(directory, *messages)
    input = messages.map { |message| message.is_a?(String) ? message : JSON.generate(message) }
    input = "#{input.join("\n")}\n"
    output, error, status = Open3.capture3(RbConfig.ruby, executable, "mcp", chdir: directory, stdin_data: input)
    expect(status).to be_success, error
    output.lines.map { |line| JSON.parse(line) }
  end

  def request(id, method, params = {})
    { jsonrpc: "2.0", id: id, method: method, params: params }
  end

  def modern_request(id, method, **params)
    request(id, method, params.merge(_meta: modern_meta))
  end

  def legacy_initialize(version = "2025-11-25")
    request(1, "initialize", protocolVersion: version, capabilities: {}, clientInfo: { name: "rspec", version: "1" })
  end

  it "serves current discovery, pings and tool metadata without a legacy handshake" do
    discover, ping, list = exchange(fixture, modern_request("discover", "server/discover"), modern_request(2, "ping"),
                                    modern_request(3, "tools/list"))

    expect(discover).to include("jsonrpc" => "2.0", "id" => "discover")
    expect(discover.fetch("result")).to include("supportedVersions" => ["2026-07-28"], "capabilities" => { "tools" => {} })
    expect(discover.dig("result", "_meta", "io.modelcontextprotocol/serverInfo", "name")).to eq("ripr")
    expect(ping.fetch("result")).to include("resultType" => "complete")
    expect(list.dig("result", "tools").map { |tool| tool.fetch("name") }).to contain_exactly("ripr_run", "ripr_recheck")
    expect(list.dig("result", "tools")).to all(include("inputSchema" => include("type" => "object")))
  end

  it "negotiates a legacy protocol and does not answer notifications" do
    initialize, list = exchange(fixture, legacy_initialize("2025-06-18"), { jsonrpc: "2.0", method: "notifications/initialized" },
                                request(2, "tools/list"))

    expect(initialize.fetch("result")).to include("protocolVersion" => "2025-06-18", "serverInfo" => include("name" => "ripr"))
    expect(list).to include("id" => 2)
    expect(list.fetch("result")).to have_key("tools")
    expect(list.fetch("result")).not_to have_key("resultType")
  end

  it "reports malformed messages and unsupported requests without stopping the server" do
    bad_version = { "_meta" => modern_meta.merge("io.modelcontextprotocol/protocolVersion" => "1900-01-01") }
    messages = exchange(fixture, "{", "[]", request(nil, "ping"), request(1, "server/discover", bad_version),
                        modern_request(2, "tools/call", name: "missing"), modern_request(3, "missing"), modern_request(4, "ping"))

    expect(messages.first(6).map { |response| response.dig("error", "code") }).to eq([-32_700, -32_600, -32_600, -32_022, -32_602, -32_601])
    expect(messages[3].dig("error", "data", "supported")).to include("2026-07-28")
    expect(messages.last).to include("id" => 4, "result" => include("resultType" => "complete"))
  end

  it "rejects tool arguments that could select another workspace or supply CLI options" do
    path_error, option_error = exchange(fixture, modern_request(1, "tools/call", name: "ripr_run", arguments: { path: "../" }),
                                        modern_request(2, "tools/call", name: "ripr_run", arguments: { since: "--full" }))

    expect(path_error.dig("result", "isError")).to be(true)
    expect(option_error.dig("result", "isError")).to be(true)
  end

  it "serves an agent report and rechecks one real mutation" do
    Dir.mktmpdir("ripr-mcp") do |directory|
      %w[lib test].each { |path| FileUtils.cp_r(File.join(fixture, path), directory) }
      run, = exchange(directory, modern_request(1, "tools/call", name: "ripr_run"))
      report = run.dig("result", "structuredContent")
      boundary = report.fetch("gaps").find { |gap| gap.fetch("kind") == "not_infected" }

      expect(report.fetch("schema")).to eq("ripr.agent/v1")
      expect(boundary.fetch("observed")).to eq([[20, 18], [10, 18]])
      expect(JSON.parse(run.dig("result", "content", 0, "text"))).to eq(report)

      recheck, = exchange(directory, modern_request(2, "tools/call", name: "ripr_recheck", arguments: { id: boundary.fetch("id") }))
      expect(recheck.dig("result", "structuredContent", "gaps").map { |gap| gap.fetch("id") }).to eq([boundary.fetch("id")])
    end
  end

  it "uses the project's scope for diff runs and surfaces CLI failures as tool errors" do
    Dir.mktmpdir("ripr-mcp-diff") do |directory|
      %w[lib test].each { |path| FileUtils.cp_r(File.join(fixture, path), directory) }
      File.write(File.join(directory, ".ripr.yml"), "scope: method\n")
      commit = ["-c", "user.name=Ripr Test", "-c", "user.email=ripr@example.test", "commit", "-qm", "Fixture"]
      [%w[init -q], %w[add lib test], commit].each do |args|
        _, stderr, status = Open3.capture3("git", *args, chdir: directory)
        expect(status).to be_success, stderr
      end
      source = File.join(directory, "lib/sample.rb")
      File.write(source, File.read(source).sub("age >= 18", "age >= 18 # changed"))

      run, failed = exchange(directory, modern_request(1, "tools/call", name: "ripr_run", arguments: { since: "HEAD" }),
                             modern_request(2, "tools/call", name: "ripr_run", arguments: { since: "nonexistent-ref" }))
      report = run.dig("result", "structuredContent")
      expect(report.fetch("run")).to include("since" => "HEAD", "scope" => "method")
      expect(report.fetch("gaps").map { |gap| gap.fetch("subject") }.uniq).to eq(["Sample.adult?"])
      expect(failed.dig("result", "isError")).to be(true)
      expect(failed.dig("result", "content", 0, "text")).to include("nonexistent-ref")
    end
  end

  it "handles cancellation while a test run is active and drains the subprocess" do
    Dir.mktmpdir("ripr-mcp-cancel") do |directory|
      %w[lib test].each { |path| FileUtils.cp_r(File.join(fixture, path), directory) }
      started = File.join(directory, "started")
      release = File.join(directory, "release")
      File.write(File.join(directory, "test/slow_test.rb"), <<~RUBY)
        File.write(#{started.inspect}, "started")
        sleep(0.01) until File.exist?(#{release.inspect})
      RUBY

      Open3.popen3(RbConfig.ruby, executable, "mcp", chdir: directory) do |input, output, error, waiter|
        Timeout.timeout(10) do
          input.puts(JSON.generate(modern_request(1, "tools/call", name: "ripr_run")))
          sleep(0.01) until File.exist?(started)
          input.puts(JSON.generate(jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 1 }))
          input.puts(JSON.generate(modern_request(2, "ping")))
          expect(JSON.parse(output.gets)).to include("id" => 2, "result" => include("resultType" => "complete"))
          File.write(release, "release")
          input.close
          expect(output.read).to be_empty
          expect(waiter.value).to be_success, error.read
        end
      ensure
        File.write(release, "release")
      end
    end
  end
end
