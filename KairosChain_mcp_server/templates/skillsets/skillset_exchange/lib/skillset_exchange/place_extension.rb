# frozen_string_literal: true

require 'cgi'
require 'digest'
require 'securerandom'
require 'fileutils'
require 'json'
require 'uri'
require 'base64'
require 'zlib'
require 'rubygems/package'
require 'stringio'
require 'time'
require 'yaml'
require 'tmpdir'

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

    # Anonymous, read-only web catalog (skillset web catalog design WC-1..WC-5).
    # The router sources these prefixes from #public_route_prefixes at every
    # registration path (the capability travels with the extension, WC-2); the
    # router contributes method restriction, rate limiting, and transport
    # security headers, while this extension owns rendering, context-correct
    # escaping, and the disclosure bound.
    PUBLIC_PREFIX = '/place/web/skillsets'

    # CD-2 checkability vocabulary. The anonymous summary projects the
    # certificate's statuses onto exactly these claim keys, and only when the
    # value is one of the CD-2 status words — so a malformed or quality-shaped
    # certificate cannot inject non-vocabulary content into the machinery-owned
    # provenance register (WC-3/WC-4). Everything else is dropped.
    CD2_STATUS_VALUES = %w[checkable anchor-pending trusted].freeze
    CD2_STATUS_KEYS = %w[
      identity.binding identity.continuity identity.uniqueness
      derivation recording reissuance_citation_observance
      drawn_from revocation_status
    ].freeze
    MAX_SUMMARY_IDENTITY_LEN = 128
    MAX_SUMMARY_CHANNEL_LEN = 128

    # Public route prefixes this extension serves unauthenticated (WC-2). Read
    # by PlaceRouter#register_extension at every registration path.
    def self.public_route_prefixes
      [PUBLIC_PREFIX]
    end

    def public_route_prefixes
      self.class.public_route_prefixes
    end

    # In-package provenance certificate file (chain_distillation CD-7/BL-S2-6).
    CERTIFICATE_FILENAME = 'certificate.json'

    HTML_HEADERS = {
      'Content-Type' => 'text/html; charset=utf-8',
      # WC-5 cache-lifecycle bound: no cache this design controls may serve a
      # listing beyond the deposit it describes. BL-WC-4 default: no-store,
      # which also instructs caches the design does not control.
      'Cache-Control' => 'no-store',
      'X-Content-Type-Options' => 'nosniff'
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
      # Guards @deposited_skillsets across authenticated writer threads
      # (deposit/withdraw) and anonymous reader threads (catalog/detail render).
      @state_mutex = Mutex.new
      @config = load_config
      @storage_dir = resolve_storage_dir
      FileUtils.mkdir_p(@storage_dir) if @storage_dir
      load_state
      # BL-WC-5 launch backfill: pre-existing deposits get their certificate
      # state and listing address here, at construction — never on the
      # anonymous request path. Scoped rescue so only backfill failures are
      # non-fatal; storage/config init failures still propagate to the
      # registration error handler.
      begin
        backfill_listing_state!
      rescue StandardError => e
        $stderr.puts "[SkillsetExchange] Listing-state backfill failed (non-fatal): #{e.message}"
      end
    end

    # Rack-compatible dispatch. Returns Rack response or nil (not handled).
    def call(env, peer_id:)
      method = env['REQUEST_METHOD']
      path = env['PATH_INFO']
      handler = ROUTES[[method, path]]
      return nil unless handler

      send(handler, env, peer_id)
    end

    # Anonymous public dispatch (WC-1): invoked by the PlaceRouter for declared
    # public routes. Receives no peer identity and no session capability — the
    # anonymous invocation path is read-only at the capability level. Returns a
    # Rack response or nil (router 404s).
    def public_call(env)
      return nil unless %w[GET HEAD].include?(env['REQUEST_METHOD'])

      path = env['PATH_INFO']
      case path
      when PUBLIC_PREFIX, "#{PUBLIC_PREFIX}/"
        render_public_catalog(env)
      when %r{\A#{Regexp.escape(PUBLIC_PREFIX)}/([a-f0-9]{16})/?\z}
        render_public_detail(Regexp.last_match(1))
      end
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
      canonical_metadata = {}
      certificate_state = nil
      begin
        Dir.mktmpdir('kairos_ss_deposit') do |tmpdir|
          extract_tar_gz(archive_data, tmpdir)
          extracted_dir = File.join(tmpdir, name)
          if File.directory?(extracted_dir)
            temp_ss = ::KairosMcp::Skillset.new(extracted_dir)
            actual_hash = temp_ss.content_hash
            # Canonicalize immutable metadata from verified archive
            canonical_metadata = {
              version: temp_ss.version,
              file_list: temp_ss.file_list,
              provides: temp_ss.provides,
              file_count: temp_ss.file_list.size
            }
            # BL-WC-5 (deposit-time extraction point): the certificate summary
            # is derived here, at the deposit crossing, from the verified
            # archive — never on the anonymous request path.
            certificate_state = extract_certificate_state(extracted_dir)
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
      rescue SecurityError => e
        return json_response(422, {
          error: 'path_traversal_detected',
          message: "Archive rejected: #{e.message}"
        })
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
        version: canonical_metadata[:version] || version,
        description: description,
        content_hash: content_hash,
        signature: signature,
        depositor_id: peer_id,
        depositor_signed: depositor_signed,
        file_list: canonical_metadata[:file_list] || file_list,
        tags: tags,
        provides: canonical_metadata[:provides] || provides,
        archive_size_bytes: archive_data.bytesize,
        file_count: file_list.size,
        # Microsecond precision: the listing address derives from this value,
        # and WC-5's identity severance must hold even for same-second
        # replacements.
        deposited_at: Time.now.utc.iso8601(6),
        certificate: certificate_state
      }
      # WC-5 listing identity: a per-deposit-instance address. A fresh random
      # nonce per deposit makes severance unconditional — even two replacements
      # of the same (name, depositor) within the same microsecond get distinct
      # addresses, so a new deposit never wears a predecessor's address.
      metadata[:deposit_nonce] = SecureRandom.hex(16)
      metadata[:listing_address] = listing_address_for(metadata)
      File.write(File.join(deposit_dir, 'metadata.json'), JSON.pretty_generate(metadata))

      # Replace existing deposit from same agent with same name.
      # Guarded so an anonymous reader's snapshot never sees a torn write.
      @state_mutex.synchronize { @deposited_skillsets[deposit_key] = metadata }
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

      begin
        archive_data = File.binread(archive_path)
        archive_base64 = Base64.strict_encode64(archive_data)
      rescue StandardError => e
        return json_response(500, {
          error: 'archive_read_failed',
          message: "Failed to read archive: #{e.message}"
        })
      end

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

      # 4. Remove from in-memory state (guarded against anonymous readers)
      @state_mutex.synchronize { @deposited_skillsets.delete(deposit_key) }

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
    # Certificate summary (skillset web catalog design WC-3/WC-4, BL-WC-2/5)
    # -----------------------------------------------------------------------

    # Derive the deposit-judgment certificate state from a verified extracted
    # package directory. Three truthful states (WC-4):
    #   { present: false }                       — no certificate in the package
    #   { present: true, summary: {...} }        — certificate, summary derived
    #   { present: true, summary: nil }          — certificate, summary unavailable
    # The summary is a CD-5-bounded projection of the certificate's own claims:
    # identity, checkability statuses (CD-2 vocabulary), and the revocation
    # channel. Never payload-derived content, never openings/salts, never
    # diagnostics.
    def extract_certificate_state(extracted_dir)
      cert_path = File.join(extracted_dir, CERTIFICATE_FILENAME)
      return { present: false } unless File.exist?(cert_path)

      cert = JSON.parse(File.read(cert_path))
      core = cert['claim_core']
      return { present: true, summary: nil } unless core.is_a?(Hash)

      identity = core['certificate_identity']
      unless identity.is_a?(String) && !identity.empty? && identity.length <= MAX_SUMMARY_IDENTITY_LEN
        return { present: true, summary: nil }
      end

      channel = core.dig('recording', 'revocation_channel')
      channel = nil unless channel.is_a?(String) && channel.length <= MAX_SUMMARY_CHANNEL_LEN

      {
        present: true,
        summary: {
          certificate_identity: identity,
          statuses: project_cd2_statuses(core['statuses']),
          revocation_channel: channel
        }
      }
    rescue StandardError
      # Extraction failure yields absence of a summary, never diagnostics.
      { present: true, summary: nil }
    end

    # WC-3/WC-4: project depositor-supplied statuses onto the CD-2 vocabulary.
    # Only known claim keys with recognized CD-2 status values survive; any
    # other key, non-scalar value, or non-vocabulary word is dropped. This
    # makes "the summary is CD-2 checkability statuses" structural rather than
    # a trust in the depositor's certificate shape, and bounds the rendered
    # table to at most CD2_STATUS_KEYS entries.
    def project_cd2_statuses(raw)
      return {} unless raw.is_a?(Hash)

      projected = {}
      CD2_STATUS_KEYS.each do |key|
        value = raw[key]
        projected[key] = value if value.is_a?(String) && CD2_STATUS_VALUES.include?(value)
      end
      projected
    end

    # WC-5 listing identity: per-deposit-instance, transport-safe address.
    # The deposit_nonce (assigned at deposit time) guarantees uniqueness; the
    # other components keep the address stable across a backfill re-derivation.
    def listing_address_for(meta)
      basis = "#{meta[:name]}|#{meta[:depositor_id]}|#{meta[:deposited_at]}|#{meta[:deposit_nonce]}"
      Digest::SHA256.hexdigest(basis)[0, 16]
    end

    # Launch-time backfill (BL-WC-5): give pre-existing deposits their
    # certificate state and listing address. Runs at extension construction —
    # off the anonymous request path — and persists once. This is a writer
    # under the guard-enrollment discipline at this instance's boundary.
    def backfill_listing_state!
      changed = false
      @deposited_skillsets.each_value do |meta|
        unless meta[:listing_address]
          # Legacy deposits predate the nonce; assign one now so the address is
          # per-deposit-unique, then persist it (deterministic thereafter).
          meta[:deposit_nonce] ||= SecureRandom.hex(16)
          meta[:listing_address] = listing_address_for(meta)
          changed = true
        end
        next if meta.key?(:certificate)

        meta[:certificate] = backfill_certificate_state(meta)
        changed = true
      end
      save_state if changed
    end

    def backfill_certificate_state(meta)
      deposit_dir = File.join(@storage_dir, "#{meta[:name]}_#{sanitize_id(meta[:depositor_id])}")
      archive_path = File.join(deposit_dir, 'archive.tar.gz')
      # Presence unknown when the archive cannot be inspected: rendered as the
      # neutral unavailability marker, never as "no provenance claim".
      return { present: nil } unless File.exist?(archive_path)

      state = nil
      Dir.mktmpdir('kairos_ss_backfill') do |tmpdir|
        extract_tar_gz(File.binread(archive_path), tmpdir)
        extracted_dir = File.join(tmpdir, meta[:name].to_s)
        state = if File.directory?(extracted_dir)
                  extract_certificate_state(extracted_dir)
                else
                  { present: nil }
                end
      end
      state
    rescue StandardError
      { present: nil }
    end

    # -----------------------------------------------------------------------
    # Anonymous web catalog rendering (WC-1/WC-3/WC-4/WC-5)
    # -----------------------------------------------------------------------

    def render_public_catalog(env)
      params = parse_query(env)
      search = params['search'].to_s
      limit = [[(params['limit'] || '50').to_i, 1].max, 100].min

      results = @state_mutex.synchronize { @deposited_skillsets.values.dup }

      # WC-4: search matches depositor-authored metadata only — never
      # certificate-derived fields, which are excluded from any matching.
      unless search.empty?
        q = search.downcase
        results = results.select do |meta|
          meta[:name].to_s.downcase.include?(q) ||
            meta[:description].to_s.downcase.include?(q) ||
            (meta[:tags] || []).any? { |t| t.to_s.downcase.include?(q) } ||
            (meta[:provides] || []).any? { |p| p.to_s.downcase.include?(q) }
        end
      end

      total = results.size
      # DEE: unordered random sample, identical for certified and uncertified.
      sampled = results.size > limit ? results.sample(limit) : results.shuffle

      cards = sampled.map { |meta| listing_card_html(meta) }.join("\n")
      body = <<~HTML
        #{public_page_header('SkillSet Catalog')}
        <p>#{total} SkillSet deposit#{total == 1 ? '' : 's'} on this Place. Unordered random sample — no ranking, no recommendation.</p>
        <form method="get" action="#{h(PUBLIC_PREFIX)}">
          <input type="text" name="search" value="#{h(search)}" placeholder="Search name, description, tags" />
          <button type="submit">Search</button>
        </form>
        #{total.zero? ? '<p>No SkillSet deposits are currently listed.</p>' : cards}
        #{public_page_footer}
      HTML
      html_response(200, body)
    end

    def render_public_detail(address)
      meta = @state_mutex.synchronize { @deposited_skillsets.values.find { |m| m[:listing_address] == address } }
      unless meta
        return html_response(404, <<~HTML)
          #{public_page_header('Listing not found')}
          <p>No listing exists at this address. Listings are per-deposit: a withdrawn or replaced deposit's address ceases to resolve.</p>
          #{public_page_footer}
        HTML
      end

      body = <<~HTML
        #{public_page_header(meta[:name].to_s)}
        #{listing_card_html(meta, detail: true)}
        <h2>Acquisition</h2>
        <p>This catalog is read-only. Acquisition happens exclusively on the authenticated agent path:
        connect a KairosChain instance to this Place and use the <code>skillset_acquire</code> tool
        (name: <code>#{h(meta[:name])}</code>, depositor: <code>#{h(meta[:depositor_id])}</code>).
        The Place verified format safety, a tar header scan, and depositor identity — review content before use.</p>
        #{public_page_footer}
      HTML
      html_response(200, body)
    end

    # One listing, uniform structure (WC-4): every listing carries the same
    # provenance register, populated exclusively from certificate-derived
    # state; depositor-authored text stays in its own register.
    def listing_card_html(meta, detail: false)
      addr = h(meta[:listing_address].to_s)
      title = detail ? h(meta[:name].to_s) : %(<a href="#{h(PUBLIC_PREFIX)}/#{addr}">#{h(meta[:name].to_s)}</a>)
      tags = (meta[:tags] || []).map { |t| h(t.to_s) }.join(', ')
      provides = (meta[:provides] || []).map { |p| h(p.to_s) }.join(', ')
      <<~HTML
        <article class="listing">
          <h3>#{title} <small>v#{h(meta[:version].to_s)}</small></h3>
          <p class="depositor-text">#{h(meta[:description].to_s)}</p>
          <dl>
            <dt>Depositor</dt><dd>#{h(meta[:depositor_id].to_s)}</dd>
            <dt>Deposited at</dt><dd>#{h(meta[:deposited_at].to_s)}</dd>
            #{tags.empty? ? '' : "<dt>Tags</dt><dd>#{tags}</dd>"}
            #{provides.empty? ? '' : "<dt>Provides</dt><dd>#{provides}</dd>"}
            <dt>Content hash</dt><dd><code>#{h(meta[:content_hash].to_s)}</code></dd>
            <dt>Files</dt><dd>#{h(meta[:file_count].to_s)} (#{h(meta[:archive_size_bytes].to_s)} bytes)</dd>
          </dl>
          #{provenance_field_html(meta, detail: detail)}
        </article>
      HTML
    end

    # The provenance register (WC-4 three truthful states, WC-5 honesty).
    def provenance_field_html(meta, detail: false)
      cert = meta[:certificate]
      state_html =
        if cert.nil? || cert[:present].nil?
          '<p>Provenance state unavailable.</p>'
        elsif cert[:present] && cert[:summary]
          summary_html(cert[:summary], detail: detail)
        elsif cert[:present]
          '<p>Provenance claim present — summary unavailable.</p>'
        else
          '<p>No provenance claim.</p>'
        end
      <<~HTML
        <section class="provenance" aria-label="Provenance (certificate-derived)">
          <h4>Provenance</h4>
          #{state_html}
        </section>
      HTML
    end

    def summary_html(summary, detail: false)
      identity = h(summary[:certificate_identity].to_s)
      unless detail
        return "<p>Provenance certificate <code>#{identity}</code> (deposit-time claims; see detail view).</p>"
      end

      statuses = summary[:statuses] || {}
      rows = statuses.map do |claim, status|
        "<tr><td>#{h(claim.to_s)}</td><td>#{h(status.to_s)}</td></tr>"
      end.join
      channel = summary[:revocation_channel]
      <<~HTML
        <p>Provenance certificate <code>#{identity}</code>.</p>
        #{rows.empty? ? '' : "<table><thead><tr><th>Claim</th><th>Checkability</th></tr></thead><tbody>#{rows}</tbody></table>"}
        #{channel ? "<p>Revocation channel: <code>#{h(channel.to_s)}</code></p>" : ''}
        <p class="limits">Everything in this summary, including checkability status, reflects deposit-judgment
        state and is silent about everything after. Revocation checking is carrier-side and out of this
        catalog's scope. Provenance describes origin, not quality.</p>
      HTML
    end

    def public_page_header(title)
      <<~HTML
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{h(title)} — Meeting Place</title>
        <style>
          body { font-family: system-ui, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; }
          article.listing { border: 1px solid #ccc; border-radius: 6px; padding: 0.8rem 1rem; margin: 1rem 0; }
          section.provenance { border-top: 1px dashed #999; margin-top: 0.6rem; padding-top: 0.4rem; }
          section.provenance h4 { margin: 0 0 0.3rem; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.05em; }
          p.limits { font-size: 0.85rem; color: #555; }
          dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.1rem 0.8rem; }
          dt { font-weight: 600; } dd { margin: 0; overflow-wrap: anywhere; }
          table { border-collapse: collapse; } td, th { border: 1px solid #ccc; padding: 0.2rem 0.5rem; }
        </style></head><body>
        <h1>#{h(title)}</h1>
      HTML
    end

    def public_page_footer
      <<~HTML
        <hr><p class="limits">Anonymous read-only view of SkillSet deposits. Listings are shown without
        ranking (DEE). Certificate presence is an origin claim, not a quality signal.</p>
        </body></html>
      HTML
    end

    def html_response(status, body)
      [status, HTML_HEADERS.dup, [body]]
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
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
      # Snapshot the hash under the lock, then serialize the snapshot outside
      # it, so a concurrent writer's guarded mutation cannot land mid-iteration
      # of JSON serialization (avoids "modified during iteration" and torn
      # on-disk state under multi-thread deposit/withdraw).
      snapshot = @state_mutex.synchronize { @deposited_skillsets.dup }
      data = {
        deposited_skillsets: snapshot,
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
