# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'canon'
require_relative 'recorder'
require_relative 'certificate'
require_relative 'distiller'
require_relative 'carrier_wiring'

module KairosMcp
  module SkillSets
    module ChainDistillation
      # Distribution of a certified distillate (design slice 2 FROZEN,
      # CD-7..CD-11).
      #
      # Ordering (CD-9, verdict precedes EVERY effect):
      #   1. active guard regime required — decline, never degrade (CD-1
      #      register)
      #   2. admission: certificate-to-distillate commitment binding
      #      (CD-9); where this chain is the certificate's named source
      #      chain, grounding + revocation are checked authoritatively and
      #      a revoked identity declines (revoked-at-judgment); elsewhere
      #      the revocation clause binds vacuously (CD-9, disclosed) and
      #      only certificate-local checks run
      #   3. deposit crossing judged by the guard (:distillation_outward
      #      family; denial aborts before any package, exchange call,
      #      carrier exposure, or listing exists)
      #   4. package materialization (CD-7: SkillSet layout with
      #      certificate.json as a mandatory constituent — BL-S2-6)
      #   5. exchange delegation (BL-S2-1: wrap — the existing exchange
      #      deposit path is consumed unchanged; the delegate is an
      #      injectable seam whose default resolves the shipped
      #      skillset_exchange deposit tool)
      #   6. carrier exposure marker (CD-8: outward reachability begins at
      #      deposit approval; the marker is the minimal persistent form,
      #      the query surface itself is BL-S2-7)
      #
      # The judgment-time revocation gate is necessary, not sufficient: a
      # revocation landing after judgment is caught by the carrier mirror
      # and the CD-11 listing duty, not by this gate.
      module Depositor
        module_function

        # The internal crossing name is deliberately DISTINCT from the
        # cd_deposit tool name: the guard judges the crossing presented by
        # this module (slice-1 pattern — cd_release_* crossings, unenrolled
        # tool names), so a tool-name collision would have the registry
        # judge the raw tool call FIRST and the admission-ordered crossing
        # second — double judgment in the wrong order (impl review R1 (b)).
        DEPOSIT_CROSSING = 'cd_release_package'
        CERTIFICATE_FILENAME = 'certificate.json' # BL-S2-6
        EXPOSURE_FILENAME = 'cd_exposure.json'

        # Injectable seams (design-constraint tests): the exchange deposit
        # delegate (network boundary), the package root, and the exposure
        # store path. The guard registry and regime seams are the
        # Distiller's own.
        @exchange = nil
        @package_root = nil
        @exposure_path = nil

        class << self
          attr_writer :exchange, :package_root, :exposure_path
        end

        def deposit(certificate:, distillate_json:, skillset_name:, safety: nil, description: nil)
          regime = Distiller.guard_regime
          # CD-1 register: distribution only under an active regime.
          unless regime && regime.active? && regime.policy
            raise Distiller::Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-9/guard-regime-inactive',
              remedy: 'activate the confidentiality guard regime before depositing'
            )
          end

          name = validate_skillset_name(skillset_name)
          cert = Canon.stringify(certificate)
          identity = cert.is_a?(Hash) ? cert.dig('claim_core', 'certificate_identity') : nil
          if !identity.is_a?(String) || identity.empty?
            raise Distiller::Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-9/certificate-malformed',
              remedy: 'certificate must carry claim_core.certificate_identity'
            )
          end

          # 2. Admission (CD-9). Locality is keyed to the
          # content-independent certificate identity — does this chain's
          # CD-6 record family know it? — never to the certificate's own
          # mutable chain_identity claim (impl reviews R1/R3: an edited
          # claim must buy neither the revocation-scan bypass nor the
          # vacuous grounding lane). The revocation decline binds exactly
          # where this chain issued the identity; a coincidental local
          # revocation record for a genuinely foreign identity does not
          # veto the vacuous case the design discloses (CD-6 chain
          # scoping; impl review R3).
          # Locality is keyed to the content-independent identity ONLY
          # (does this chain's CD-6 record family know it?). A
          # chain_identity-equality clause was tried and REMOVED (impl
          # review R5 (a)): the stock genesis block is deterministic, so
          # chain_identity is a shared constant across stock instances
          # until head-anchoring individuates it — equality would force
          # grounding on every legitimate third-party deposit and kill
          # the disclosed vacuous lane in production.
          source_local = locally_issued?(identity)
          # Revocation binds by identity AND by commitment: a revoked
          # local distillate relabeled under a fresh identity keeps its
          # distillate commitment, and the commitment-keyed scan catches
          # that (impl review R4 (a)). DISCLOSED RESIDUAL (impl review
          # R5): the commitment is salted, so an operator who re-salts
          # the same content evades this scan — the resulting forged
          # certificate is ungrounded on every chain (no CD-6 record
          # matches its claim core) and fails any grounding verifier;
          # only snapshot-only holders accept it, the parent's disclosed
          # forged-certificate posture. Closing it fully needs a
          # deterministic content key in the CD-6 record (design-backlog
          # candidate), not a deposit-gate patch.
          if (source_local && locally_revoked?(identity)) ||
             locally_revoked_content?(cert.dig('claim_core', 'derivation', 'distillate_commitment'))
            raise Distiller::Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-9/revoked-at-judgment',
              remedy: 'this chain revoked this certificate identity or the distillate content it presents; revoked material does not distribute'
            )
          end
          # CD-8: the mirror form is mandatory for distributing THIS
          # chain's certificates — decline without a reachable carrier.
          # For third-party re-deposits the mirror form is the SOURCE
          # chain's carrier, which this instance neither holds nor may
          # shadow (impl review R6 (b): a locally minted envelope for a
          # foreign certificate would be a shadow carrier that can never
          # mirror the source's revocations); its reachability is BL-S2-7.
          # READ-ONLY here: envelope work happens only after the crossing
          # verdict. The exposure store must likewise be readable.
          CarrierWiring.require_carrier! if source_local
          read_exposure_store!(exposure_path)

          # Source-locality decides how much MORE is authoritative:
          # grounding binds where THIS chain issued the certificate;
          # genuinely foreign certificates get certificate-local checks
          # only (binding, vocabulary, statuses) — the disclosed CD-9
          # residual.
          verification = Certificate.verify(
            cert,
            chain_entries: source_local ? Distiller.chain_entries : nil,
            chain_hashes: source_local ? Distiller.chain_block_hashes : nil,
            distillate_json: distillate_json
          )
          unless verification[:valid]
            raise Distiller::Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-9/binding-or-verification-failure',
              remedy: 'certificate does not verify against the presented distillate; nothing presents as certified without surviving the binding check'
            )
          end

          # 3. Deposit crossing — verdict precedes every effect. The
          # crossing presents every content-bearing constituent the
          # package will carry — distillate, certificate, name, and the
          # caller's description (the generated manifest contains nothing
          # else caller-controlled) — in the single-encoded register
          # (slice-1 R3 P1 discipline: parsed objects, canonicalized
          # exactly once by the guard, so content detection is never
          # defeated by escaped quoting). A certificate field is an
          # outbound surface like any other (impl review R2 (a)); the
          # identity rides as an identifier so the verdict record cites
          # it.
          content_obj = begin
            JSON.parse(distillate_json)
          rescue StandardError
            distillate_json
          end
          presented = { 'content' => content_obj, 'certificate' => cert,
                        'skillset_name' => name, 'certificate_identity' => identity }
          presented['description'] = description.to_s unless description.nil?
          Distiller.registry_class.run_gates(DEPOSIT_CROSSING, presented, safety)

          # 4a. Carrier envelope guarantee (CD-8), now that the certificate
          # verified and the crossing approved — for THIS chain's
          # certificates only: backfill where the certificate predates the
          # wiring; a mismatched pre-existing envelope declines loudly.
          # Third-party certificates get no local envelope (their carrier
          # is the source's; a local shadow would mislead re-checking
          # holders — impl review R6 (b)).
          CarrierWiring.ensure_envelope!(cert, identity) if source_local

          # 4b. Package materialization (CD-7).
          package_path = materialize_package(
            name: name, distillate_json: distillate_json,
            certificate: cert, description: description
          )

          # 5. Exchange delegation (BL-S2-1) — consumed unchanged; a
          # failure is surfaced, never swallowed (fail-visible), and a
          # RAISING delegate is normalized to the same structured failure
          # so both failure surfaces are uniform.
          exchange_result = begin
            exchange_delegate.call(name)
          rescue StandardError => e
            { status: 'exchange_error', error: e.class.name, message: e.message }
          end

          # 6. Exposure marker (CD-8): reachability begins no earlier than
          # the approving verdict, and this slice starts it only once the
          # exchange leg POSITIVELY succeeded — a package that never
          # reached a listing exposes nothing. Fail-closed: only an
          # explicit success shape counts; any other shape (raised, error,
          # string-keyed, non-Hash) is a failure.
          exchange_ok = exchange_result.is_a?(Hash) &&
                        ['listed', 'deposited'].include?(
                          (exchange_result[:status] || exchange_result['status']).to_s
                        )
          record_exposure(identity, name) if exchange_ok

          {
            status: exchange_ok ? 'deposited' : 'deposit_incomplete',
            certificate_identity: identity,
            skillset_name: name,
            package_path: package_path,
            exchange_result: exchange_result,
            listing_duty: listing_duty_notice(identity)
          }
        end

        # CD-11 advisory carried on revocation-adjacent responses: the
        # revoker owes listing maintenance for listings under their own
        # control (withdrawal route — BL-S2-8 resolution this slice).
        def listing_duty_notice(identity)
          "on revocation of #{identity}, withdraw or update every deposit listing under your control (CD-11; withdrawal route)"
        end

        def validate_skillset_name(name)
          n = name.to_s
          unless n.match?(/\A[a-z][a-z0-9_]{1,63}\z/)
            raise Distiller::Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-7/skillset-name-invalid',
              remedy: 'skillset_name must be lowercase snake_case (2..64 chars)'
            )
          end
          n
        end

        # Identity-keyed revocation scan on the local chain, independent
        # of what chain the certificate claims to name (CD-9): the
        # identity is pre-assigned and content-independent (CD-6), so it
        # cannot be edited away without detaching the certificate from
        # its own claim core.
        def locally_revoked?(identity)
          Distiller.chain_entries.values.any? do |e|
            e.is_a?(Hash) && e['type'] == 'cd_revocation' &&
              e['certificate_identity'] == identity
          end
        end

        # Identity-keyed issuance scan: this chain issued the certificate
        # iff its CD-6 distillation record for the identity exists here.
        def locally_issued?(identity)
          Distiller.chain_entries.values.any? do |e|
            e.is_a?(Hash) && e['type'] == 'cd_distillation' &&
              e['certificate_identity'] == identity
          end
        end

        # Commitment-keyed revocation scan (impl review R4 (a)): the set
        # of distillate commitments whose issuing identities this chain
        # revoked. A certificate presenting one of these commitments is
        # the revoked content whatever identity it now wears — the
        # commitment is bound to the distillate the holder must present
        # for the binding check, so relabeling cannot detach it.
        def locally_revoked_content?(distillate_commitment)
          return false unless distillate_commitment.is_a?(String) && !distillate_commitment.empty?
          entries = Distiller.chain_entries.values
          revoked_ids = entries.select { |e| e.is_a?(Hash) && e['type'] == 'cd_revocation' }
                               .map { |e| e['certificate_identity'] }
          return false if revoked_ids.empty?
          entries.any? do |e|
            e.is_a?(Hash) && e['type'] == 'cd_distillation' &&
              revoked_ids.include?(e['certificate_identity']) &&
              e['distillate_commitment'] == distillate_commitment
          end
        end

        # CD-7: SkillSet-layout package; the certificate is a mandatory
        # constituent, not a detachable sidecar. The layout is the one the
        # distribution channel already understands (skillset.json +
        # knowledge/), so the existing deposit/browse/acquire interfaces
        # carry it without transport changes.
        def materialize_package(name:, distillate_json:, certificate:, description: nil)
          root = package_root
          dir = File.join(root, name)
          # Name-collision guard (impl review R3 (a)): the package root is
          # the live skillsets directory — materializing over an existing
          # SkillSet that is NOT this certificate's own prior package
          # would corrupt an installed SkillSet. Re-deposit of the same
          # certificate over its own package is append-honest and allowed.
          if Dir.exist?(dir)
            prior_cert_file = File.join(dir, CERTIFICATE_FILENAME)
            prior_identity = begin
              JSON.parse(File.read(prior_cert_file)).dig('claim_core', 'certificate_identity')
            rescue StandardError
              nil
            end
            this_identity = certificate.dig('claim_core', 'certificate_identity')
            unless prior_identity && prior_identity == this_identity
              raise Distiller::Declined, JSON.generate(
                distiller: 'chain_distillation', verdict: 'decline',
                rule: 'cd-7/package-name-collision',
                remedy: "a SkillSet named #{name} already exists and is not this certificate's package; choose another name"
              )
            end
          end
          FileUtils.mkdir_p(File.join(dir, 'knowledge'))
          manifest = {
            'name' => name,
            'version' => '0.1.0',
            'description' => description || "Certified distillate #{name} (chain_distillation slice 2)",
            'author' => 'chain_distillation',
            'layer' => 'L1',
            'provides' => ['distilled-knowledge'],
            'tool_classes' => [],
            'knowledge_files' => ["knowledge/#{name}.json"]
          }
          File.write(File.join(dir, 'skillset.json'), JSON.pretty_generate(manifest))
          File.write(File.join(dir, 'knowledge', "#{name}.json"), distillate_json)
          File.write(File.join(dir, CERTIFICATE_FILENAME), JSON.pretty_generate(certificate))
          dir
        end

        def package_root
          return @package_root if @package_root
          File.join(data_dir, 'skillsets')
        end

        def exposure_path
          return @exposure_path if @exposure_path
          File.join(data_dir, 'storage', EXPOSURE_FILENAME)
        end

        def data_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir)
            KairosMcp.data_dir
          else
            ENV['KAIROS_DATA_DIR'] || File.join(Dir.pwd, '.kairos')
          end
        end

        # CD-8 exposure marker: appended only after the approving verdict
        # and a positively successful exchange leg — a denied crossing
        # leaves no entry. The store follows decline-not-degrade like
        # everything else in this module: a corrupt store is quarantined
        # and reported, never silently reinitialized (impl review R1 (a) —
        # silent reset dropped every prior exposure record).
        def record_exposure(identity, name)
          path = exposure_path
          FileUtils.mkdir_p(File.dirname(path))
          entries = read_exposure_store!(path)
          entries << {
            'certificate_identity' => identity,
            'skillset_name' => name,
            'exposed_at_chain_height' => Distiller.chain_height
          }
          File.write(path, JSON.pretty_generate(entries))
          path
        end

        # Absent store => empty (first exposure). Corrupt store => the
        # operation fails loudly and the file is left EXACTLY as found —
        # the corrupt store is its own forensic record, every subsequent
        # deposit keeps declining until the operator repairs it, and the
        # read is strictly read-only (verdict precedes every effect; impl
        # reviews R2/R4: neither a silent reset nor a pre-verdict
        # quarantine write is admissible).
        def read_exposure_store!(path)
          return [] unless File.exist?(path)
          entries = begin
            JSON.parse(File.read(path))
          rescue StandardError
            nil
          end
          return entries if entries.is_a?(Array)
          raise Distiller::Declined, JSON.generate(
            distiller: 'chain_distillation', verdict: 'decline',
            rule: 'cd-8/exposure-store-corrupt',
            remedy: 'exposure store is not a JSON array; repair it in place (it is preserved untouched) — deposits keep declining until it parses'
          )
        end

        def exposed?(identity)
          path = exposure_path
          return false unless File.exist?(path)
          entries = begin
            JSON.parse(File.read(path))
          rescue StandardError
            nil
          end
          unless entries.is_a?(Array)
            raise Distiller::Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-8/exposure-store-corrupt',
              remedy: 'exposure store unreadable — corrupt store is not "never exposed"'
            )
          end
          entries.any? { |e| e.is_a?(Hash) && e['certificate_identity'] == identity }
        end

        # BL-S2-1 default delegate: the shipped skillset_exchange deposit
        # tool, invoked by name exactly as any caller would — the exchange
        # is consumed unchanged. Tests inject the seam at this network
        # boundary only; everything before it (admission, crossing,
        # packaging) runs real in the production-wiring regression.
        def exchange_delegate
          return @exchange if @exchange
          lambda do |name|
            begin
              unless defined?(KairosMcp::Tools::BaseTool)
                require_relative '../../../../../lib/kairos_mcp/tools/base_tool'
              end
              require_relative '../../../skillset_exchange/tools/skillset_deposit'
              tool = KairosMcp::SkillSets::SkillsetExchange::Tools::SkillsetDeposit.new
              normalize_exchange_result(tool.call('name' => name), name)
            rescue LoadError, StandardError => e
              # Fail-visible: the deposit crossing was approved and the
              # package exists; the exchange leg's failure is reported,
              # never silently dropped. A retry re-runs the whole deposit
              # including a fresh crossing verdict record — append-honest,
              # not idempotent.
              { status: 'exchange_error', error: e.class.name, message: e.message }
            end
          end
        end

        # The shipped deposit tool answers as MCP text content whose JSON
        # carries "status": "deposited" on success and "error" otherwise.
        # Introspection is fail-closed: only a positively parsed success
        # counts; unparseable or ambiguous answers are exchange failures,
        # so exposure (CD-8) never begins on an unlisted package.
        def normalize_exchange_result(raw, requested_name = nil)
          payload = raw
          if raw.is_a?(Array)
            item = raw.find { |i| i.is_a?(Hash) && (i[:text] || i['text']) }
            payload = begin
              JSON.parse((item && (item[:text] || item['text'])).to_s)
            rescue StandardError
              nil
            end
          end
          status = payload.is_a?(Hash) ? (payload['status'] || payload[:status]) : nil
          answered_name = payload.is_a?(Hash) ? (payload['name'] || payload[:name]) : nil
          name_ok = answered_name.nil? || requested_name.nil? ||
                    answered_name.to_s == requested_name.to_s
          if status == 'deposited' && name_ok
            { status: 'listed', detail: payload }
          else
            { status: 'exchange_error', detail: payload || raw }
          end
        end
      end
    end
  end
end
