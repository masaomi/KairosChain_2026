# frozen_string_literal: true

# project_manager SkillSet — generic project/work-item vessel (design v0.5 FROZEN).
#
# Invariant wiring (see docs/drafts/secretary_project_manager_design_v0.5_FROZEN.md):
# - INV-PM-1: no domain vocabulary in structure; domain enters as content only.
# - INV-PM-5: tools write only the instance-local pm store and attestations.
# - INV-PM-6: single authoritative store; migration carries markers (never restamps).
# - INV-PM-7: minimal item schema; dormancy derived from last-meaningful-touch.

require 'project_manager/store'
require 'project_manager/digest'
require 'project_manager/tool_helpers'

module ProjectManager
  VERSION = '0.1.0'
end
