# frozen_string_literal: true

require 'json'
require 'yaml'
require 'base64'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require 'rubygems/package'
require 'stringio'

module KairosMcp
  module SkillSets
    module SkillsetExchange
      module Tools
        class SkillsetAcquire < KairosMcp::Tools::BaseTool
          def name
            'skillset_acquire'
          end

          def description
            'Acquire a SkillSet from a connected Meeting Place. Downloads, verifies signature and content hash, checks dependencies, and installs locally.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting acquire skillset exchange install]
          end

          def related_tools
            %w[skillset_browse skillset_deposit meeting_connect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                name: { type: 'string', description: 'SkillSet name to acquire' },
                depositor_id: { type: 'string', description: 'Optional depositor ID for disambiguation' },
                force: { type: 'boolean', description: 'Force re-install over existing (default: false)' }
              },
              required: ['name']
            }
          end

          def call(arguments)
            ss_name = arguments['name'].to_s.strip
            depositor_id = arguments['depositor_id']
            depositor_id = nil if depositor_id.to_s.strip.empty?
            force = arguments['force'] == true

            # 1. Build PlaceClient (fail early)
            client = build_place_client
            return client if client.is_a?(Array) # text_content error

            begin
              # 2. Ensure extension is registered (connection may target local Place)
              ensure_extension_registered!

              # 3. GET /place/v1/skillset_content via PlaceClient
              content_result = client.skillset_content(name: ss_name, depositor: depositor_id)

              if content_result[:error]
                return text_content(JSON.pretty_generate({
                  error: 'Failed to retrieve SkillSet',
                  details: content_result[:error],
                  depositors: content_result[:depositors]
                }.compact))
              end

              # 4. Verify signature against depositor_public_key (inline in response)
              config = load_skillset_config
              sig_verified = false
              if config.dig('acquire', 'verify_signature') != false
                sig = content_result[:signature]
                # Normalize blank string to nil
                sig = nil if sig.is_a?(String) && sig.strip.empty?
                pubkey = content_result[:depositor_public_key]

                if sig && pubkey
                  begin
                    crypto = ::MMP::Crypto.new(auto_generate: false)
                    sig_verified = crypto.verify_signature(
                      content_result[:content_hash],
                      sig,
                      pubkey
                    )
                    # Fail-CLOSED when key + signature are both present but verification fails
                    unless sig_verified
                      return text_content(JSON.pretty_generate({
                        error: 'Signature verification failed',
                        message: 'The depositor signature does not match the content hash. Archive may be tampered.',
                        hint: 'If you trust this source, you can disable verify_signature in config.'
                      }))
                    end
                  rescue StandardError => e
                    return text_content(JSON.pretty_generate({
                      error: 'Signature verification error',
                      message: e.message
                    }))
                  end
                elsif sig
                  # Fail-OPEN: Signature present but no public key (depositor may have disconnected)
                  sig_verified = false
                end
                # Fail-OPEN: No signature at all -- sig_verified stays false, proceed with output flag
              end

              # 5+6. Verify content_hash AND preflight dependency check (single extraction)
              archive_data = Base64.strict_decode64(content_result[:archive_base64])
              hash_verified = false
              dep_warnings = nil
              manager = ::KairosMcp::SkillSetManager.new

              # Use server-confirmed name for extraction (not raw user input)
              confirmed_name = content_result[:name] || ss_name
              Dir.mktmpdir('kairos_ss_acquire') do |tmpdir|
                extract_tar_gz(archive_data, tmpdir)
                extracted_dir = File.join(tmpdir, confirmed_name)

                unless File.directory?(extracted_dir)
                  return text_content(JSON.pretty_generate({
                    error: 'Invalid archive structure',
                    message: "Archive does not contain expected directory '#{confirmed_name}'"
                  }))
                end

                temp_ss = ::KairosMcp::Skillset.new(extracted_dir)

                # 5. Content hash verification (fail-closed)
                actual_hash = temp_ss.content_hash
                if actual_hash == content_result[:content_hash]
                  hash_verified = true
                else
                  return text_content(JSON.pretty_generate({
                    error: 'Content hash mismatch',
                    expected: content_result[:content_hash],
                    actual: actual_hash,
                    message: 'Archive content does not match declared hash. Possible tampering.'
                  }))
                end

                # 6. Preflight dependency check (reuse same extracted Skillset)
                if config.dig('acquire', 'check_dependencies') != false
                  dep_check = manager.check_installable_dependencies(temp_ss)
                  # Surface warnings for ANY non-empty issue (missing, version_mismatch, OR disabled)
                  has_issues = !dep_check[:missing].empty? ||
                               !dep_check[:version_mismatch].empty? ||
                               !dep_check[:disabled].empty?
                  if has_issues
                    dep_warnings = {
                      satisfiable: dep_check[:satisfiable],
                      missing: dep_check[:missing],
                      version_mismatch: dep_check[:version_mismatch],
                      disabled: dep_check[:disabled]
                    }.reject { |k, v| k != :satisfiable && v.is_a?(Array) && v.empty? }
                  end
                end
              end

              # 7. Install via SkillSetManager#install_from_archive
              archive_payload = {
                name: confirmed_name,
                archive_base64: content_result[:archive_base64],
                content_hash: content_result[:content_hash]
              }

              begin
                install_result = manager.install_from_archive(archive_payload, force: force)
              rescue ArgumentError => e
                if e.message.include?('already installed')
                  return text_content(JSON.pretty_generate({
                    status: 'already_installed',
                    installed_version: detect_installed_version(ss_name),
                    available_version: content_result[:version],
                    hint: 'Re-run with force: true to replace, or use skills_evolve for managed upgrade'
                  }))
                end
                raise
              rescue SecurityError => e
                return text_content(JSON.pretty_generate({
                  error: 'Security check failed',
                  message: e.message
                }))
              end

              # 8. Return structured result
              result = {
                status: 'acquired',
                name: ss_name,
                version: content_result[:version],
                installed_path: install_result[:path],
                content_hash: content_result[:content_hash],
                signature_verified: sig_verified,
                content_hash_verified: hash_verified,
                dependency_warnings: dep_warnings,
                trust_notice: content_result[:trust_notice]
              }.compact

              text_content(JSON.pretty_generate(result))

            rescue StandardError => e
              text_content(JSON.pretty_generate({
                error: 'Acquire failed',
                message: e.message
              }))
            end
          end

          private

          def build_place_client(timeout: 30)
            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({ error: 'Not connected', hint: 'Use meeting_connect first' }))
            end
            config = ::MMP.load_config
            unless config['enabled']
              return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled' }))
            end
            url = connection['url'] || connection[:url]
            token = connection['session_token'] || connection[:session_token]
            agent_id = connection['agent_id'] || connection[:agent_id]
            identity = ::MMP::Identity.new(config: config)
            ::MMP::PlaceClient.reconnect(
              place_url: url, identity: identity,
              session_token: token, agent_id: agent_id, timeout: timeout
            )
          end

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError
            nil
          end

          def load_skillset_config
            config_path = File.join(KairosMcp.skillsets_dir, 'skillset_exchange', 'config', 'skillset_exchange.yml')
            File.exist?(config_path) ? (YAML.safe_load(File.read(config_path)) || {}) : {}
          rescue StandardError
            {}
          end

          # Extract tar.gz into target directory
          def extract_tar_gz(tar_gz_data, target_dir)
            target_dir = File.expand_path(target_dir)
            io = StringIO.new(tar_gz_data)
            Zlib::GzipReader.wrap(io) do |gz|
              Gem::Package::TarReader.new(gz) do |tar|
                tar.each do |entry|
                  next if entry.header.typeflag == '2' # symlink
                  next if entry.header.typeflag == '1' # hard link
                  dest = File.expand_path(File.join(target_dir, entry.full_name))
                  unless dest.start_with?(target_dir + '/') || dest == target_dir
                    raise SecurityError, "Path traversal detected: #{entry.full_name}"
                  end
                  if entry.directory?
                    FileUtils.mkdir_p(dest)
                  elsif entry.file?
                    FileUtils.mkdir_p(File.dirname(dest))
                    File.binwrite(dest, entry.read)
                  end
                end
              end
            end
          end

          # Detect installed version for already_installed error
          def detect_installed_version(name)
            manager = ::KairosMcp::SkillSetManager.new
            ss = manager.find_skillset(name)
            ss&.version
          rescue StandardError
            nil
          end

          # Lazy extension registration (same pattern as skillset_deposit.rb)
          def ensure_extension_registered!
            return unless defined?(KairosMcp) && KairosMcp.respond_to?(:http_server)
            router = KairosMcp.http_server&.place_router
            return unless router
            return if router.extensions.any? { |e| e.is_a?(::SkillsetExchange::PlaceExtension) }
            require_relative '../lib/skillset_exchange/place_extension'
            ext = ::SkillsetExchange::PlaceExtension.new(router)
            route_actions = {
              'skillset_deposit' => 'deposit_skill',
              'skillset_browse' => 'browse',
              'skillset_content' => 'browse',
              'skillset_withdraw' => 'deposit_skill'
            }
            router.register_extension(ext, route_action_map: route_actions)
          rescue StandardError => e
            $stderr.puts "[SkillsetExchange] Late registration failed (non-fatal): #{e.message}"
          end
        end
      end
    end
  end
end
