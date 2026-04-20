# frozen_string_literal: true

require 'json'
require_relative 'workspace_confinement'

module KairosMcp
  module SkillSets
    module ExternalTools
      # ToolSupport — shared helpers for external_tools tools.
      #
      # - resolve_workspace(arguments): extract workspace_root from arg or @safety
      # - confine(path, ws): wrapper around WorkspaceConfinement.resolve_path
      # - json_ok(payload): success text_content
      # - json_err(message, **extra): error text_content
      module ToolSupport
        WC = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement

        def resolve_workspace(arguments)
          explicit = arguments['workspace_root'] || arguments[:workspace_root]
          root = explicit
          root ||= @safety&.workspace_root if @safety.respond_to?(:workspace_root)
          root ||= @safety&.safe_root if @safety.respond_to?(:safe_root)
          root ||= ENV['KAIROS_WORKSPACE']
          root ||= Dir.pwd
          File.realpath(root)
        end

        def confine(path, workspace_root)
          WC.resolve_path(path, workspace_root)
        end

        def json_ok(payload)
          text_content(JSON.pretty_generate(payload.merge(ok: true)))
        end

        def json_err(message, **extra)
          text_content(JSON.pretty_generate({ ok: false, error: message }.merge(extra)))
        end
      end
    end
  end
end
