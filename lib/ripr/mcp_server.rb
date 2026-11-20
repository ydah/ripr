# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require_relative "version"

module Ripr
  class MCPServer
    PROTOCOL_VERSION = "2026-07-28"
    LEGACY_VERSIONS = %w[2025-11-25 2025-06-18].freeze
    SERVER_INFO = { "name" => "ripr", "version" => VERSION }.freeze
    CAPABILITIES = { "tools" => {} }.freeze
    PROTOCOL_KEY = "io.modelcontextprotocol/protocolVersion"
    CAPABILITIES_KEY = "io.modelcontextprotocol/clientCapabilities"
    TOOLS = [
      { "name" => "ripr_run", "description" => "Run mutation tests in the current project. Omit since to run the full suite.",
        "inputSchema" => { "type" => "object", "additionalProperties" => false,
                           "properties" => { "since" => { "type" => "string", "minLength" => 1, "description" => "Git base revision" },
                                             "scope" => { "enum" => %w[node method] } } } },
      { "name" => "ripr_recheck", "description" => "Recheck one mutation using its short ID from the ripr report.",
        "inputSchema" => { "type" => "object", "additionalProperties" => false, "required" => ["id"],
                           "properties" => { "id" => { "type" => "string", "pattern" => "^[a-f0-9]{10}$" } } } }
    ].freeze

    def initialize(stdin:, stdout:, stderr:)
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @requests = Queue.new
      @pending = {}
      @lock = Mutex.new
    end

    def run
      worker = Thread.new { run_tools }
      @stdin.each_line do |line|
        response = receive(line)
        @lock.synchronize { reply(response) } if response
      end
      0
    ensure
      @requests.close
      worker&.join
    end

    private

    def receive(line)
      request = JSON.parse(line)
      unless request.is_a?(Hash) && request["jsonrpc"] == "2.0" && request["method"].is_a?(String)
        return error(nil, -32_600, "Invalid request")
      end

      method = request.fetch("method")
      params = request.fetch("params", {})
      unless request.key?("id")
        if params.is_a?(Hash)
          @legacy_ready = true if method == "notifications/initialized" && @legacy_version
          @lock.synchronize { @pending.delete(params["requestId"]) } if method == "notifications/cancelled"
        end
        return
      end

      id = request["id"]
      return error(nil, -32_600, "Invalid request ID") unless id.is_a?(String) || id.is_a?(Integer)
      return error(id, -32_602, "Expected an object for params") unless params.is_a?(Hash)

      meta = params["_meta"]
      modern = meta.is_a?(Hash) && meta.key?(PROTOCOL_KEY)
      if modern
        version = meta[PROTOCOL_KEY]
        return error(id, -32_602, "Missing or invalid protocol metadata") unless version.is_a?(String) && meta[CAPABILITIES_KEY].is_a?(Hash)
        if version != PROTOCOL_VERSION
          return error(id, -32_022, "Unsupported protocol version", { "requested" => version, "supported" => [PROTOCOL_VERSION] })
        end
      elsif method == "initialize"
        return initialize_legacy(id, params)
      elsif !@legacy_ready && method != "ping"
        return error(id, -32_602, "Initialize the client or include protocol metadata")
      end

      result = case method
               when "server/discover"
                 return error(id, -32_601, "Unknown method") unless modern

                 { "supportedVersions" => [PROTOCOL_VERSION], "capabilities" => CAPABILITIES }
               when "ping" then {}
               when "tools/list" then { "tools" => TOOLS }
               when "tools/call"
                 arguments = params.fetch("arguments", {})
                 name = params["name"]
                 return error(id, -32_602, "Expected a tool name and argument object") unless name.is_a?(String) && arguments.is_a?(Hash)
                 return error(id, -32_602, "Unknown tool") unless TOOLS.any? { |tool| tool["name"] == name }

                 return enqueue_tool(id, name, arguments, modern)
               else return error(id, -32_601, "Unknown method")
               end
      complete(id, result, modern)
    rescue JSON::ParserError, EncodingError
      error(nil, -32_700, "Parse error")
    end

    def initialize_legacy(id, params)
      return error(id, -32_600, "Already initialized") if @legacy_version

      version = params["protocolVersion"]
      info = params["clientInfo"]
      unless version.is_a?(String) && info.is_a?(Hash) && info["name"].is_a?(String) && info["version"].is_a?(String) &&
             params["capabilities"].is_a?(Hash)
        return error(id, -32_602, "Expected protocolVersion, clientInfo and capabilities")
      end

      @legacy_version = LEGACY_VERSIONS.include?(version) ? version : LEGACY_VERSIONS.first
      { "id" => id, "result" => { "protocolVersion" => @legacy_version, "capabilities" => CAPABILITIES, "serverInfo" => SERVER_INFO } }
    end

    def enqueue_tool(id, name, arguments, modern)
      request = [id, name, arguments, modern]
      @lock.synchronize do
        return error(id, -32_600, "Request ID already in use") if @pending.key?(id)

        @pending[id] = request
      end
      @requests << request
      nil
    end

    def run_tools
      while (request = @requests.pop)
        id, name, arguments, modern = request
        next unless @lock.synchronize { @pending[id].equal?(request) }

        result = call_tool(name, arguments)
        @lock.synchronize do
          next unless @pending[id].equal?(request)

          @pending.delete(id)
          reply(complete(id, result, modern))
        end
      end
    end

    def reply(response)
      @stdout.puts(JSON.generate({ "jsonrpc" => "2.0" }.merge(response)))
      @stdout.flush
    rescue Errno::EPIPE
      nil
    end

    def complete(id, result, modern)
      result = result.merge("resultType" => "complete", "_meta" => { "io.modelcontextprotocol/serverInfo" => SERVER_INFO }) if modern
      { "id" => id, "result" => result }
    end

    def call_tool(name, arguments)
      options = tool_options(name, arguments)
      return tool_error("Invalid arguments for #{name}") unless options

      executable = File.expand_path("../../exe/ripr", __dir__)
      output, diagnostics, status = Open3.capture3(RbConfig.ruby, executable, "--reporter", "agent", *options, binmode: true)
      diagnostics = diagnostics.force_encoding(Encoding::UTF_8).scrub.strip
      @stderr.puts(diagnostics) unless diagnostics.empty?
      unless status.success? || status.exitstatus == 2
        return tool_error(diagnostics.empty? ? "ripr terminated before reporting a result" : diagnostics)
      end

      report = JSON.parse(output)
      return tool_error("ripr did not return an agent report") unless report.is_a?(Hash) && report["schema"] == "ripr.agent/v1"

      { "content" => [{ "type" => "text", "text" => JSON.generate(report) }], "structuredContent" => report }
    rescue SystemCallError, JSON::ParserError, EncodingError => e
      tool_error("Unable to read the ripr report: #{e.message}")
    end

    def tool_options(name, arguments)
      if name == "ripr_recheck"
        id = arguments["id"]
        return ["--only=#{id}"] if arguments.keys == ["id"] && id.is_a?(String) && id.match?(/\A[a-f0-9]{10}\z/)

        return
      end
      return unless (arguments.keys - %w[since scope]).empty?

      scope = arguments["scope"]
      return if arguments.key?("scope") && !%w[node method].include?(scope)

      options = scope ? ["--scope=#{scope}"] : []
      return options << "--full" unless arguments.key?("since")

      since = arguments["since"]
      return unless since.is_a?(String) && since.match?(/\A[^\x00-\x20\x7F]+\z/) && !since.start_with?("-")

      options << "--since=#{since}"
    end

    def tool_error(message)
      { "content" => [{ "type" => "text", "text" => message }], "isError" => true }
    end

    def error(id, code, message, data = nil)
      details = { "code" => code, "message" => message }
      details["data"] = data if data
      { "id" => id, "error" => details }
    end
  end
end
