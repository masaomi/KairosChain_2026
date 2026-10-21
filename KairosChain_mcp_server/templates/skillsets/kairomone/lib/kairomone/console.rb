# frozen_string_literal: true

require 'json'
require 'time'
require 'rbconfig'
require 'securerandom'
require 'openssl'
require 'digest'
require 'base64'
require 'fileutils'
require 'monitor'
require_relative '../kairomone'
require 'kairos_mcp/skillset'
require 'kairos_mcp/kairos_chain/chain'

module Kairomone
  # The owner's console: a loopback page that relays one supervised Claude
  # Code child. Loaded only by scripts/kairomone_console.rb and its tests; the
  # MCP tools never load it, so nothing here runs inside the dot's server.
  module Console
    # Every refusal to start. The message is one line for the owner.
    class Refusal < Kairomone::Error; end
  end
end

require_relative 'console/project'
require_relative 'console/gate'
require_relative 'console/child'
require_relative 'console/session'
require_relative 'console/server'
