# frozen_string_literal: true

require 'json'
require 'time'
require 'date'
require 'digest'
require 'securerandom'
require 'fileutils'
require 'base64'
require 'kairos_mcp'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/context_manager'
require 'kairos_mcp/storage/file_backend'
require 'kairos_mcp/skills_config'

module Kairomone
  class Error < StandardError; end
  VERSION = '0.8.0.pre1'
  PACKAGE_ROOT = File.expand_path('..', __dir__)
end

require_relative 'kairomone/paths'
require_relative 'kairomone/ledger'
require_relative 'kairomone/host'
require_relative 'kairomone/instance'
require_relative 'kairomone/vocabulary'
require_relative 'kairomone/profile'
require_relative 'kairomone/profession'
require_relative 'kairomone/art'
require_relative 'kairomone/transplant'
require_relative 'kairomone/policy'
require_relative 'kairomone/backup'
require_relative 'kairomone/baseline'
require_relative 'kairomone/progression'
require_relative 'kairomone/autonomy'
require_relative 'kairomone/companion'

