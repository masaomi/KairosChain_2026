# frozen_string_literal: true

require 'shellwords'

module Hestia
  # Generates shell-safe import commands for various LLM tools.
  # All interpolated values are escaped via Shellwords.shellescape.
  class ImportCommandGenerator
    def initialize(place_url:)
      @place_url = place_url
    end

    def commands_for(skill, deposit_id:)
      safe_url = Shellwords.shellescape(@place_url)
      safe_skill_id = Shellwords.shellescape(skill[:skill_id] || deposit_id.split('__', 2).last)

      {
        claude_code: claude_code_command(safe_skill_id, safe_url),
        codex: codex_command(safe_skill_id, safe_url),
        kairos_cli: kairos_cli_command(safe_skill_id, safe_url),
        curl_preview: curl_preview_command(Shellwords.shellescape(deposit_id), safe_url)
      }
    end

    private

    def claude_code_command(skill_id, place_url)
      "claude -p \"Use meeting_acquire_skill to acquire #{skill_id} from place #{place_url}\""
    end

    def codex_command(skill_id, place_url)
      "echo \"Use meeting_acquire_skill to acquire #{skill_id} from place #{place_url}\" | codex exec -"
    end

    def kairos_cli_command(skill_id, place_url)
      "kairos-chain acquire --place #{place_url} --skill #{skill_id}"
    end

    def curl_preview_command(deposit_id, place_url)
      "curl -s #{place_url}/place/api/v1/skill/#{deposit_id}"
    end
  end
end
