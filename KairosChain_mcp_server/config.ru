# frozen_string_literal: true

# Rack configuration for KairosChain Meeting Protocol Server
#
# Usage:
#   bundle exec rackup -p 8080
#   # or
#   bundle exec puma -p 8080

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'kairos_mcp/transport/http_server'

workspace_root = ENV['KAIROS_WORKSPACE'] || File.expand_path(__dir__)

app = KairosMcp::Transport::MeetingApp.new(workspace_root: workspace_root)

run app
