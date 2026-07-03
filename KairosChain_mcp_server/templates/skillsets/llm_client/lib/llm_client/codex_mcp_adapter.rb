# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'adapter'

module KairosMcp
  module SkillSets
    module LlmClient
      # Adapter that drives OpenAI Codex through its MCP server (`codex mcp-server`)
      # rather than `codex exec`. Spawns the server over stdio, performs the MCP
      # handshake, invokes the `codex` tool once (sandbox read-only by default so a
      # reviewer/eval call cannot mutate the workspace), and returns the normalized
      # response. One-shot: the server is started and torn down per call.
      #
      # Companion to CodexAdapter (CLI). Selectable as the codex backend in
      # multi_llm_review / cross-eval to A/B the MCP path against `codex exec`.
      class CodexMcpAdapter < Adapter
        DEFAULT_TIMEOUT = 300
        PROTOCOL_VERSION = '2025-06-18'

        def call(messages:, system: nil, tools: nil, model: nil,
                 max_tokens: nil, temperature: nil, output_schema: nil)
          prompt = build_prompt(messages, system, output_schema)
          sandbox = @config&.dig('sandbox') || 'read-only' # reviewers/evals must not mutate
          timeout = (@config&.dig('timeout_seconds') || DEFAULT_TIMEOUT).to_i

          result = run_codex_tool(prompt: prompt, model: model, sandbox: sandbox, timeout: timeout)

          {
            'content' => result[:text],
            'tool_use' => nil,
            'stop_reason' => 'end_turn',
            'model' => model || 'codex-mcp-default',
            'thread_id' => result[:thread_id],
            'input_tokens' => nil,
            'output_tokens' => nil
          }
        rescue ApiError
          raise
        rescue Errno::ENOENT
          raise ApiError.new('codex CLI not found. Install: https://github.com/openai/codex',
                             provider: 'codex', retryable: false)
        rescue StandardError => e
          raise ApiError.new("codex mcp error: #{e.message}", provider: 'codex')
        end

        private

        def run_codex_tool(prompt:, model:, sandbox:, timeout:)
          args = { 'prompt' => prompt, 'sandbox' => sandbox,
                   'approval-policy' => (@config&.dig('approval_policy') || 'never') }
          args['model'] = model.to_s if model && !model.to_s.empty?

          stdin, stdout, wait = Open3.popen2('codex', 'mcp-server')
          deadline = now + timeout
          begin
            send_msg(stdin, id: 1, method: 'initialize', params: {
                       'protocolVersion' => PROTOCOL_VERSION, 'capabilities' => {},
                       'clientInfo' => { 'name' => 'kairos-chain', 'version' => '0.1' }
                     })
            read_result(stdout, 1, deadline)
            send_msg(stdin, method: 'notifications/initialized')

            send_msg(stdin, id: 2, method: 'tools/call',
                     params: { 'name' => 'codex', 'arguments' => args })
            resp = read_result(stdout, 2, deadline)
            extract(resp)
          ensure
            stdin.close unless stdin.closed?
            unless wait.join(3)
              begin
                Process.kill('TERM', wait.pid)
              rescue StandardError
                nil
              end
            end
            stdout.close unless stdout.closed?
          end
        end

        def send_msg(io, method:, id: nil, params: nil)
          msg = { 'jsonrpc' => '2.0', 'method' => method }
          msg['id'] = id if id
          msg['params'] = params if params
          io.puts(JSON.generate(msg))
          io.flush
        end

        # Read newline-delimited JSON-RPC until a response with the given id arrives,
        # skipping notifications/progress and unrelated lines. Raises on timeout/error.
        def read_result(io, id, deadline)
          loop do
            remaining = deadline - now
            timed_out!(id) if remaining <= 0
            timed_out!(id) unless IO.select([io], nil, nil, remaining)
            line = io.gets
            raise ApiError.new('codex mcp server closed the connection unexpectedly',
                               provider: 'codex', retryable: true) if line.nil?
            line = line.strip
            next if line.empty?
            begin
              msg = JSON.parse(line)
            rescue JSON::ParserError
              next
            end
            next unless msg['id'] == id
            if msg['error']
              raise ApiError.new("codex mcp error: #{msg['error']['message'] || msg['error']}",
                                 provider: 'codex')
            end
            return msg['result']
          end
        end

        def timed_out!(id)
          raise ApiError.new("codex mcp timed out waiting for id=#{id}",
                             provider: 'codex', retryable: true)
        end

        def extract(result)
          text = +''
          thread_id = nil
          if result.is_a?(Hash)
            Array(result['content']).each do |blk|
              text << blk['text'].to_s if blk.is_a?(Hash) && blk['type'] == 'text'
            end
            thread_id = result.dig('structuredContent', 'threadId') ||
                        result.dig('_meta', 'threadId') || result['threadId']
          end
          { text: text, thread_id: thread_id }
        end

        def build_prompt(messages, system, output_schema)
          parts = []
          parts << "[System]: #{system}\n" if system
          if output_schema
            parts << '[Output Format]: Respond with ONLY valid JSON (no markdown fences) matching this schema:'
            parts << JSON.generate(output_schema)
            parts << ''
          end
          messages.each do |m|
            role = m['role'] || m[:role]
            content = m['content'] || m[:content]
            case role
            when 'user' then parts << content.to_s
            when 'assistant' then parts << "[Previous assistant response]: #{content}"
            when 'tool' then parts << "[Tool result]: #{content}"
            end
          end
          parts.join("\n")
        end

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
