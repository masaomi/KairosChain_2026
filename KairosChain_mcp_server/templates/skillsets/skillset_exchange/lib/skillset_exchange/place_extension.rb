# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'uri'
require 'base64'
require 'zlib'
require 'rubygems/package'
require 'stringio'
require 'time'
require 'yaml'

module SkillsetExchange
  # PlaceExtension adds SkillSet deposit/browse/content/withdraw endpoints
  # to the Hestia PlaceRouter.
  #
  # Registered via PlaceRouter#register_extension during Place startup or
  # lazily when the first MCP tool invocation detects the extension is missing.
  #
  # All handlers receive an already-authenticated peer_id (no double auth).
  class PlaceExtension
    ROUTES = {
      ['POST', '/place/v1/skillset_deposit']  => :handle_skillset_deposit,
      ['GET',  '/place/v1/skillset_browse']   => :handle_skillset_browse,
      ['GET',  '/place/v1/skillset_content']  => :handle_skillset_content,
      ['POST', '/place/v1/skillset_withdraw'] => :handle_skillset_withdraw,
    }.freeze

    # Executable extensions to check in tar headers (same as Skillset::EXECUTABLE_EXTENSIONS)
    EXECUTABLE_EXTENSIONS = %w[.rb .py .sh .pl .js .ts .lua .exe .so .dylib .dll .class .jar .wasm].freeze

    JSON_HEADERS = {
      'Content-Type' => 'application/json',
      'Cache-Control' => 'no-cache'
    }.freeze

    SAFE_NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/

    def initialize(router)
      @router = router
      @skill_board = router.skill_board
      @session_store = router.session_store
      @registry = router.registry
      @deposited_skillsets = {}  # { "name:depositor_id" => metadata_hash }
      @config = load_config
      @storage_dir = resolve_storage_dir
      FileUtils.mkdir_p(@storage_dir) if @storage_dir
      load_state
    end

    # Rack-compatible dispatch. Returns Rack response or nil (not handled).
    def call(env, peer_id:)
      method = env['REQUEST_METHOD']
      path = env['PATH_INFO']
      handler = ROUTES[[method, path]]
      return nil unless handler

      send(handler, env, peer_id)
    end

    private

    # -----------------------------------------------------------------------
    # POST /place/v1/skillset_deposit
    # -----------------------------------------------------------------------
    def handle_skillset_deposit(env, peer_id)
      # 0. Content-Length pre-check (reject before reading body)
      content_length = env['CONTENT_LENGTH']&.to_i || 0
      max_body = (max_archive_size_bytes * 1.4 + 8192).to_i
      if content_length > max_body
        return json_response(413, {
          error: 'payload_too_large',
          message: "Request body too large (#{content_length} > #{max_body})"
        })
      end

      body = parse_body(env)

      name = body['name'].to_s.strip
      version = body['version'].to_s
      description = body['description'].to_s
      content_hash = body['content_hash'].to_s
      archive_base64 = body['archive_base64']
      signature = body['signature']
      file_list = body['file_list'] || []
      tags = body['tags'] || []
      provides = body['provides'] || []

      # 1. Name sanitization
      unless SAFE_NAME_PATTERN.match?(name)
        return json_response(400, { error: 'invalid_name', message: "Invalid SkillSet name: #{name}" })
      end

      # 2. Archive required
      unless archive_base64 && !archive_base64.empty?
        return json_response(400, { error: 'missing_archive', message: 'archive_base64 is required' })
      end

      # 3. Decode Base64
      begin
        archive_data = Base64.strict_decode64(archive_base64)
      rescue ArgumentError => e
        return json_response(400, { error: 'invalid_base64', message: "Invalid Base64: #{e.message}" })
      end

      # 4. Archive size check
      max_size = max_archive_size_bytes
      if archive_data.bytesize > max_size
        return json_response(422, {
          error: 'archive_too_large',
          message: "Archive size #{archive_data.bytesize} exceeds limit #{max_size}"
        })
      end

      # 5. Gzip validity check
      begin
        io = StringIO.new(archive_data)
        gz = Zlib::GzipReader.new(io)
        gz.close
      rescue Zlib::GzipFile::Error => e
        return json_response(400, { error: 'invalid_gzip', message: "Invalid gzip: #{e.message}" })
      end

      # 6. Tar header scan: reject if any entry matches executable extensions
      begin
        executable_found = tar_header_scan(archive_data)
        if executable_found
          return json_response(422, {
            error: 'executable_content',
            message: "Archive contains executable file: #{executable_found}"
          })
        end
      rescue SecurityError => e
        return json_response(422, {
          error: 'tar_scan_failed',
          message: "Tar header scan failed (archive rejected): #{e.message}"
        })
      end

      # 7. Content hash verification (file-tree hash)
      # Extract to temp dir, create Skillset, compare content_hash
      hash_verified = false
      begin
        Dir.mktmpdir('kairos_ss_deposit') do |tmpdir|
          extract_tar_gz(archive_data, tmpdir)
          extracted_dir = File.join(tmpdir, name)
          if File.directory?(extracted_dir)
            temp_ss = ::KairosMcp::Skillset.new(extracted_dir)
            actual_hash = temp_ss.content_hash
            if actual_hash == content_hash
              hash_verified = true
            else
              return json_response(422, {
                error: 'content_hash_mismatch',
                message: "Declared content_hash does not match file-tree hash (expected: #{content_hash}, actual: #{actual_hash})"
              })
            end
          else
            return json_response(422, {
              error: 'invalid_archive_structure',
              message: "Archive does not contain expected directory '#{name}'"
            })
          end
        end
      rescue StandardError => e
        return json_response(422, {
          error: 'archive_extraction_failed',
          message: "Failed to verify archive: #{e.message}"
        })
      end

      # 8. Signature verification
      require_sig = @config.dig('deposit', 'require_signature') == true
      depositor_signed = false

      if signature
        public_key = @registry.public_key_for(peer_id)
        if public_key
          begin
            crypto = ::MMP::Crypto.new(auto_generate: false)
            depositor_signed = crypto.verify_signature(content_hash, signature, public_key)
          rescue StandardError
            depositor_signed = false
          end
          if require_sig && !depositor_signed
            return json_response(422, {
              error: 'signature_invalid',
              message: 'Signature verification failed and require_signature is enabled'
            })
          end
        else
          # No key in registry — reject if require_signature is enabled
          if require_sig
            return json_response(422, {
              error: 'public_key_unavailable',
              message: 'Signature cannot be verified: depositor public key not in registry (require_signature: true)'
            })
          end
        end
      elsif require_sig
        return json_response(422, {
          error: 'signature_required',
          message: 'Deposit requires a signature (require_signature: true)'
        })
      end

      # 9. Quota checks
      deposit_key = "#{name}:#{peer_id}"
      agent_count = @deposited_skillsets.count { |_k, v| v[:depositor_id] == peer_id && _k != deposit_key }
      if agent_count >= max_per_agent
        return json_response(422, {
          error: 'quota_exceeded',
          message: "Per-agent deposit quota exceeded (max #{max_per_agent})"
        })
      end

      # Total archive size quota
      existing_size = @deposited_skillsets
        .reject { |k, _| k == deposit_key }
        .sum { |_, v| v[:archive_size_bytes] || 0 }
      if existing_size + archive_data.bytesize > max_total_archive_bytes
        return json_response(422, {
          error: 'total_quota_exceeded',
          message: "Total archive storage quota exceeded (max #{max_total_archive_bytes})"
        })
      end

      # 10. Store archive to disk
      deposit_dir = File.join(@storage_dir, "#{name}_#{sanitize_id(peer_id)}")
      FileUtils.mkdir_p(deposit_dir)
      File.binwrite(File.join(deposit_dir, 'archive.tar.gz'), archive_data)

      metadata = {
        name: name,
        version: version,
        description: description,
        content_hash: content_hash,
        signature: signature,
        depositor_id: peer_id,
        depositor_signed: depositor_signed,
        file_list: file_list,
        tags: tags,
        provides: provides,
        archive_size_bytes: archive_data.bytesize,
        file_count: file_list.size,
        deposited_at: Time.now.utc.iso8601
      }
      File.write(File.join(deposit_dir, 'metadata.json'), JSON.pretty_generate(metadata))

      # Replace existing deposit from same agent with same name
      @deposited_skillsets[deposit_key] = metadata
      save_state

      # 11. Record chain event
      record_chain_event(
        event_type: 'skillset_deposit',
        skillset_name: name,
        content_hash: content_hash,
        participants: [peer_id],
        extra: {
          depositor_id: peer_id,
          version: version,
          file_count: file_list.size,
          archive_size_bytes: archive_data.bytesize
        }
      )

      # 12. Return success
      json_response(200, {
        status: 'deposited',
        name: name,
        version: version,
        content_hash: content_hash,
        file_count: file_list.size,
        trust_notice: {
          verified_by_place: false,
          depositor_signed: depositor_signed,
          tar_header_scanned: true,
          content_hash_verified: hash_verified,
          depositor_id: peer_id,
          disclaimer: 'SkillSet deposited by agent. Place verified format safety, tar header scan, and depositor identity. Review content before use.'
        }
      })
    end

    # -----------------------------------------------------------------------
    # GET /place/v1/skillset_browse
    # -----------------------------------------------------------------------
    def handle_skillset_browse(env, _peer_id)
      params = parse_query(env)
      search = params['search']
      limit = [(params['limit'] || '20').to_i, 50].min
      limit = [limit, 1].max

      # Collect all deposited skillsets metadata
      results = @deposited_skillsets.values.dup

      # Filter by search term (match name, description, provides, tags)
      if search && !search.empty?
        search_down = search.downcase
        results = results.select do |meta|
          meta[:name].to_s.downcase.include?(search_down) ||
            meta[:description].to_s.downcase.include?(search_down) ||
            (meta[:provides] || []).any? { |p| p.to_s.downcase.include?(search_down) } ||
            (meta[:tags] || []).any? { |t| t.to_s.downcase.include?(search_down) }
        end
      end

      total = results.size

      # Random sample (DEE compliance)
      sampled = results.size > limit ? results.sample(limit) : results.shuffle

      entries = sampled.map do |meta|
        {
          name: meta[:name],
          version: meta[:version],
          description: meta[:description],
          tags: meta[:tags] || [],
          provides: meta[:provides] || [],
          file_count: meta[:file_count] || 0,
          depositor_id: meta[:depositor_id],
          content_hash: meta[:content_hash],
          archive_size_bytes: meta[:archive_size_bytes],
          deposited_at: meta[:deposited_at]
        }
      end

      json_response(200, {
        entries: entries,
        total_available: total,
        returned: entries.size,
        sampling: total > limit ? 'random_sample' : 'all_shuffled'
      })
    end

    # -----------------------------------------------------------------------
    # GET /place/v1/skillset_content?name=NAME&depositor=DEPOSITOR_ID
    # -----------------------------------------------------------------------
    def handle_skillset_content(env, peer_id)
      params = parse_query(env)
      name = params['name'].to_s.strip
      depositor = params['depositor']&.strip

      # 1. Name required
      if name.empty?
        return json_response(400, {
          error: 'missing_name',
          message: 'Query parameter "name" is required'
        })
      end

      # 2. Find matching deposits
      matches = @deposited_skillsets.select { |_k, v| v[:name] == name }

      # 3. Disambiguation
      if matches.empty?
        return json_response(404, {
          error: 'not_found',
          message: "No SkillSet deposited with name '#{name}'"
        })
      end

      if depositor && !depositor.empty?
        deposit_key = "#{name}:#{depositor}"
        match = @deposited_skillsets[deposit_key]
        unless match
          return json_response(404, {
            error: 'not_found',
            message: "No SkillSet '#{name}' deposited by '#{depositor}'"
          })
        end
        meta = match
      else
        if matches.size > 1
          depositors = matches.values.map { |v| v[:depositor_id] }
          return json_response(409, {
            error: 'ambiguous',
            message: "Multiple depositors for '#{name}'. Specify depositor parameter.",
            depositors: depositors
          })
        end
        meta = matches.values.first
      end

      # 4. Read archive from disk
      deposit_dir = File.join(@storage_dir, "#{meta[:name]}_#{sanitize_id(meta[:depositor_id])}")
      archive_path = File.join(deposit_dir, 'archive.tar.gz')

      unless File.exist?(archive_path)
        return json_response(500, {
          error: 'archive_missing',
          message: 'Archive file missing on server (storage inconsistency)'
        })
      end

      archive_data = File.binread(archive_path)
      archive_base64 = Base64.strict_encode64(archive_data)

      # 5. Get depositor public key from registry (inline, no second round-trip)
      depositor_public_key = @registry.public_key_for(meta[:depositor_id])

      # 6. Record chain event (content served, not acquisition confirmed --
      #    the client may still fail verification or install after this point)
      record_chain_event(
        event_type: 'skillset_content_served',
        skillset_name: meta[:name],
        content_hash: meta[:content_hash],
        participants: [peer_id, meta[:depositor_id]],
        extra: {
          acquirer_id: peer_id,
          depositor_id: meta[:depositor_id],
          version: meta[:version]
        }
      )

      # 7. Return content response
      json_response(200, {
        name: meta[:name],
        version: meta[:version],
        archive_base64: archive_base64,
        content_hash: meta[:content_hash],
        signature: meta[:signature],
        depositor_id: meta[:depositor_id],
        depositor_public_key: depositor_public_key,
        provides: meta[:provides] || [],
        file_list: meta[:file_list] || [],
        trust_notice: {
          verified_by_place: false,
          depositor_signed: meta[:depositor_signed] || false,
          tar_header_scanned: true,
          disclaimer: 'SkillSet deposited by agent. Place verified format safety, tar header scan, and depositor identity. Review content before use.'
        }
      })
    end

    # -----------------------------------------------------------------------
    # POST /place/v1/skillset_withdraw
    # -----------------------------------------------------------------------
    def handle_skillset_withdraw(env, peer_id)
      body = parse_body(env)
      name = body['name'].to_s.strip
      reason = body['reason'].to_s

      # 1. Name required
      if name.empty?
        return json_response(400, {
          error: 'missing_name',
          message: 'Field "name" is required'
        })
      end

      # 2. Find deposit by this peer
      deposit_key = "#{name}:#{peer_id}"
      meta = @deposited_skillsets[deposit_key]

      unless meta
        return json_response(404, {
          error: 'not_found',
          message: "No SkillSet '#{name}' deposited by you (#{peer_id})"
        })
      end

      # 3. Verify caller is original depositor (defense in depth -- key already includes peer_id)
      unless meta[:depositor_id] == peer_id
        return json_response(403, {
          error: 'not_depositor',
          message: 'Only the original depositor can withdraw a SkillSet'
        })
      end

      # 4. Remove from in-memory state
      @deposited_skillsets.delete(deposit_key)

      # 5. Delete disk files (use trusted metadata values, not raw request input)
      deposit_dir = File.join(@storage_dir, "#{meta[:name]}_#{sanitize_id(meta[:depositor_id])}")
      FileUtils.rm_rf(deposit_dir) if File.directory?(deposit_dir)

      # 6. Save state
      save_state

      # 7. Record chain event
      record_chain_event(
        event_type: 'skillset_withdraw',
        skillset_name: meta[:name],
        content_hash: meta[:content_hash],
        participants: [peer_id],
        extra: {
          depositor_id: peer_id,
          version: meta[:version],
          reason: reason.empty? ? nil : reason
        }
      )

      # 8. Return success
      json_response(200, {
        status: 'withdrawn',
        name: meta[:name],
        version: meta[:version],
        depositor_id: peer_id,
        chain_recorded: true,
        note: 'Agents who already acquired this SkillSet keep their copy.'
      })
    end

    # -----------------------------------------------------------------------
    # Tar header scan: iterate tar entry filenames, reject if any match
    # EXECUTABLE_EXTENSIONS. This is a filename-based gate only; the
    # acquirer's install_from_archive is the definitive executable gate.
    #
    # @return [String, nil] First executable filename found, or nil if clean
    # -----------------------------------------------------------------------
    def tar_header_scan(archive_data)
      io = StringIO.new(archive_data)
      Zlib::GzipReader.wrap(io) do |gz|
        Gem::Package::TarReader.new(gz) do |tar|
          tar.each do |entry|
            next if entry.directory?
            filename = entry.full_name
            ext = File.extname(filename).downcase
            return filename if EXECUTABLE_EXTENSIONS.include?(ext)

            # Check for shebang in files under tools/ or lib/
            if filename.match?(%r{(?:^|/)(?:tools|lib)/}) && entry.file?
              begin
                content = entry.read
                return filename if content&.start_with?('#!')
              rescue StandardError
                # Fail-closed: unreadable tools/lib entries are treated as executable
                return filename
              end
            end
          end
        end
      end
      nil
    rescue StandardError => e
      # Fail-closed: scan errors must not pass silently as "clean"
      raise SecurityError, "tar_header_scan failed (#{e.class}: #{e.message})"
    end

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

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

    def parse_body(env)
      body = env['rack.input']&.read
      return {} if body.nil? || body.empty?
      JSON.parse(body, symbolize_names: false)
    rescue JSON::ParserError
      {}
    end

    def parse_query(env)
      query = env['QUERY_STRING'] || ''
      URI.decode_www_form(query).to_h
    rescue StandardError
      {}
    end

    def json_response(status, body)
      [status, JSON_HEADERS, [body.to_json]]
    end

    def sanitize_id(id)
      id.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')
    end

    def record_chain_event(event_type:, skillset_name:, content_hash:, participants:, extra: {})
      # Use PlaceRouter's chain recording pattern if trust_anchor is available
      return unless @router.respond_to?(:record_chain_event, true)

      begin
        @router.send(:record_chain_event,
          event_type: event_type,
          skill_id: skillset_name,
          skill_name: skillset_name,
          content_hash: content_hash,
          participants: participants,
          extra: extra
        )
      rescue StandardError => e
        $stderr.puts "[SkillsetExchange] Chain recording failed (non-fatal): #{e.message}"
      end
    end

    # -----------------------------------------------------------------------
    # Configuration
    # -----------------------------------------------------------------------

    def load_config
      # Try to load from the SkillSet's config directory
      config_candidates = [
        File.join(skillset_path, 'config', 'skillset_exchange.yml'),
        File.join(KairosMcp.skillsets_dir, 'skillset_exchange', 'config', 'skillset_exchange.yml')
      ].compact

      config_candidates.each do |path|
        if File.exist?(path)
          return YAML.safe_load(File.read(path)) || {}
        end
      end
      {}
    rescue StandardError
      {}
    end

    def skillset_path
      if defined?(KairosMcp)
        File.join(KairosMcp.skillsets_dir, 'skillset_exchange')
      else
        ''
      end
    rescue StandardError
      ''
    end

    def resolve_storage_dir
      place_storage = @config.dig('place', 'storage_dir') || 'skillset_deposits'
      if defined?(KairosMcp)
        File.join(KairosMcp.storage_dir, place_storage)
      else
        place_storage
      end
    rescue StandardError
      'skillset_deposits'
    end

    def max_archive_size_bytes
      @config.dig('deposit', 'max_archive_size_bytes') || 5_242_880
    end

    def max_per_agent
      @config.dig('deposit', 'max_per_agent') || 10
    end

    def max_total_archive_bytes
      @config.dig('place', 'max_total_archive_bytes') || 104_857_600
    end

    # -----------------------------------------------------------------------
    # State persistence
    # -----------------------------------------------------------------------

    def state_path
      File.join(@storage_dir, 'exchange_state.json')
    end

    def save_state
      FileUtils.mkdir_p(File.dirname(state_path))
      data = {
        deposited_skillsets: @deposited_skillsets,
        updated_at: Time.now.utc.iso8601
      }
      temp = "#{state_path}.tmp"
      File.write(temp, JSON.pretty_generate(data))
      File.rename(temp, state_path)
    rescue StandardError => e
      $stderr.puts "[SkillsetExchange] Failed to save state: #{e.message}"
    end

    def load_state
      return unless File.exist?(state_path)

      data = JSON.parse(File.read(state_path), symbolize_names: true)
      raw = data[:deposited_skillsets] || {}
      @deposited_skillsets = raw.transform_keys(&:to_s)
    rescue StandardError => e
      $stderr.puts "[SkillsetExchange] Failed to load state: #{e.message}"
    end
  end
end
