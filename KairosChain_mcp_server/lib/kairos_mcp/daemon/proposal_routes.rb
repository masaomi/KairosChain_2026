# frozen_string_literal: true

require 'json'

module KairosMcp
  class Daemon
    # ProposalRoutes — HTTP routes for proposal approval via AttachServer.
    #
    # Design (P3.2 v0.2 §4.4):
    #   All mutating operations go through daemon.mailbox (CommandMailbox pattern).
    #   Read-only endpoints (GET) snapshot approval_gate state directly.
    #
    # Usage:
    #   ProposalRoutes.mount!(server, approval_gate:, mailbox:, auth: ->(req,res){ ... })
    module ProposalRoutes
      # Mount proposal routes onto a WEBrick server.
      #
      # @param server [WEBrick::HTTPServer]
      # @param approval_gate [ApprovalGate]
      # @param mailbox [CommandMailbox, #enqueue]
      # @param auth [#call] callable: (req, res) → Boolean (writes 401 if false)
      def self.mount!(server, approval_gate:, mailbox:, auth:)
        handler = Handler.new(approval_gate: approval_gate, mailbox: mailbox, auth: auth)

        server.mount_proc('/v1/proposals') do |req, res|
          handler.dispatch(req, res)
        end
      end

      class Handler
        def initialize(approval_gate:, mailbox:, auth:)
          @gate    = approval_gate
          @mailbox = mailbox
          @auth    = auth
        end

        def dispatch(req, res)
          return unless @auth.call(req, res)

          path = req.path
          case req.request_method
          when 'GET'
            if path == '/v1/proposals' || path == '/v1/proposals/'
              handle_list(res)
            elsif (m = path.match(%r{\A/v1/proposals/([^/]+)/?\z}))
              handle_show(m[1], res)
            else
              json_error(res, 404, 'not_found', "unknown path: #{path}")
            end
          when 'POST'
            if (m = path.match(%r{\A/v1/proposals/([^/]+)/approve/?\z}))
              handle_approve(req, m[1], res)
            elsif (m = path.match(%r{\A/v1/proposals/([^/]+)/reject/?\z}))
              handle_reject(req, m[1], res)
            else
              json_error(res, 404, 'not_found', "unknown path: #{path}")
            end
          else
            json_error(res, 405, 'method_not_allowed', 'GET or POST only')
          end
        end

        private

        def handle_list(res)
          pending = @gate.pending_proposals
          json_ok(res, { proposals: pending, count: pending.size })
        end

        def handle_show(proposal_id, res)
          p = @gate.read_proposal(proposal_id)
          unless p
            return json_error(res, 404, 'not_found', "proposal #{proposal_id} not found")
          end
          status = @gate.status_of(proposal_id)
          json_ok(res, p.merge('current_status' => status.to_s))
        end

        def handle_approve(req, proposal_id, res)
          body = parse_json_body(req)
          reviewer = body['reviewer'] || 'attach_user'
          reason   = body['reason']

          cmd_id = @mailbox.enqueue(:approve_proposal,
                                    proposal_id: proposal_id,
                                    reviewer: reviewer,
                                    reason: reason)
          if cmd_id.nil?
            json_error(res, 503, 'mailbox_full', 'daemon mailbox is full')
          else
            json_ok(res, { enqueued: true, command_id: cmd_id,
                           proposal_id: proposal_id, decision: 'approve' })
          end
        end

        def handle_reject(req, proposal_id, res)
          body = parse_json_body(req)
          reviewer = body['reviewer'] || 'attach_user'
          reason   = body['reason']

          cmd_id = @mailbox.enqueue(:reject_proposal,
                                    proposal_id: proposal_id,
                                    reviewer: reviewer,
                                    reason: reason)
          if cmd_id.nil?
            json_error(res, 503, 'mailbox_full', 'daemon mailbox is full')
          else
            json_ok(res, { enqueued: true, command_id: cmd_id,
                           proposal_id: proposal_id, decision: 'reject' })
          end
        end

        def json_ok(res, body)
          res.status = 200
          res['Content-Type'] = 'application/json'
          res.body = JSON.generate(body)
        end

        def json_error(res, status, code, message)
          res.status = status
          res['Content-Type'] = 'application/json'
          res.body = JSON.generate(error: code, message: message)
        end

        def parse_json_body(req)
          body = req.body.to_s
          return {} if body.empty?
          JSON.parse(body)
        rescue JSON::ParserError
          {}
        end
      end
    end
  end
end
