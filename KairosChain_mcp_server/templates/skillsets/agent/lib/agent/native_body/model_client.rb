# frozen_string_literal: true

require 'json'
require_relative 'spend_meter'

module KairosMcp
  module SkillSets
    module Agent
      module NativeBody
        # ModelClient — NB-4 model transport inside the native body
        # (native body design v0.6 FROZEN).
        #
        # The model is reached by running the instance's STAGED adapter code
        # (part of the pinned closure, NB-2) over direct HTTP — never a
        # subprocess to another product, never a channel back into the
        # instance. The eligible set below is the in-closure half of the
        # structural exclusion: the subprocess-CLI adapters, bedrock, and
        # the dispatching call_router (with its AuthError→claude_code
        # fallback) are NOT staged, so a require of them raises LoadError
        # and the act halts — there is deliberately no fallback logic here:
        # one curated provider, fixed boundary-side, or failure.
        #
        # Credential (NB-4): delivered by the driver into the body's intake
        # (stdin), held locally, and placed into the process environment
        # ONLY for the adapter-call window, then removed. The loop is
        # single-threaded and no granted tool runs during the adapter call
        # (R5-observed), so the tool surface never sees an environment that
        # contains the key.
        class ModelClient
          class TransportRefusal < StandardError; end

          ELIGIBLE = {
            'anthropic'  => { 'require' => 'llm_client/anthropic_adapter', 'class' => 'AnthropicAdapter' },
            'openai'     => { 'require' => 'llm_client/openai_adapter',    'class' => 'OpenaiAdapter' },
            'openrouter' => { 'require' => 'llm_client/openai_adapter',    'class' => 'OpenaiAdapter' },
            'local'      => { 'require' => 'llm_client/openai_adapter',    'class' => 'OpenaiAdapter' }
          }.freeze

          OPENROUTER_URL = 'https://openrouter.ai'

          def initialize(model_config, credential, meter)
            @provider = model_config['provider'].to_s
            entry = ELIGIBLE[@provider]
            unless entry
              raise TransportRefusal,
                    "provider #{@provider.inspect} is not an eligible native-body transport (NB-4)"
            end

            # In-closure load: resolves only inside the pinned region
            # (--disable-gems + restricted load path). An excluded adapter
            # name would raise LoadError here — structural rejection.
            require entry['require']
            adapter_class = KairosMcp::SkillSets::LlmClient.const_get(entry['class'])

            @env_var = model_config['api_key_env'].to_s
            raise TransportRefusal, 'api_key_env is required (credential is env-windowed by name)' if @env_var.empty?

            @credential = credential.to_s
            @max_tokens = Integer(model_config['max_tokens'] || 4096)
            @meter = meter

            config = {
              'model' => model_config['model'],
              'api_key_env' => @env_var,
              'default_max_tokens' => @max_tokens,
              'timeout_seconds' => model_config['timeout_seconds'] || 120
            }
            config['base_url'] = model_config['base_url'] if model_config['base_url']
            config['base_url'] ||= OPENROUTER_URL if @provider == 'openrouter'
            # NB-4: the boundary-side mediator is the sole egress path — it
            # enters the adapter as an EXPLICIT proxy from the curated
            # configuration, not via ambient env resolution (which Ruby
            # silently skips for loopback destinations).
            config['proxy'] = model_config['proxy'] if model_config['proxy']
            @adapter = adapter_class.new(config)
          end

          # One model call under the NB-5 per-call spend bound. Returns the
          # adapter's normalized response with usage ALREADY recorded on the
          # meter (fail-closed on missing usage — the raw top-level
          # input_tokens/output_tokens are consumed here, never coerced).
          def call(messages:, system: nil, tools: nil)
            # NB-5 per-call input bound (R2 G1/G3): estimate from the BYTE
            # length (byte-level BPE upper bound) of the SAME payload shape
            # actually sent — including the provider-specific tool-schema
            # envelope, which is larger than the raw schemas — so the pre-send
            # estimate never under-counts the real input axis.
            sent_tools = tools && !tools.empty? ? provider_tool_schemas(tools) : nil
            prompt_bytes = JSON.generate({ 's' => system, 'm' => messages, 't' => sent_tools }).bytesize
            @meter.assert_call!(prompt_bytes: prompt_bytes, max_output_tokens: @max_tokens)

            response = with_credential_window do
              @adapter.call(
                messages: messages, system: system,
                tools: sent_tools,
                max_tokens: @max_tokens
              )
            end

            @meter.record_usage!(response['input_tokens'], response['output_tokens'])
            response
          end

          private

          # NB-4 credential channel: env var set only for the adapter-call
          # window, then removed — absent from the environment whenever a
          # granted tool runs. resolve_api_key reads ENV[@env_var], so this
          # works without forking the adapter (verified code fact).
          def with_credential_window
            ENV[@env_var] = @credential
            yield
          ensure
            ENV.delete(@env_var)
          end

          # The staged adapters pass tool schemas through to the provider
          # verbatim; shape them per transport family.
          def provider_tool_schemas(tools)
            if @provider == 'anthropic'
              tools
            else
              tools.map do |t|
                { 'type' => 'function',
                  'function' => { 'name' => t['name'],
                                  'description' => t['description'],
                                  'parameters' => t['input_schema'] } }
              end
            end
          end
        end
      end
    end
  end
end
