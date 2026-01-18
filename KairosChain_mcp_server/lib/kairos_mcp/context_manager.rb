# frozen_string_literal: true

require 'fileutils'
require_relative 'anthropic_skill_parser'

module KairosMcp
  # ContextManager: Manages L2 (context layer) skills in Anthropic format
  #
  # L2 characteristics:
  # - Temporary context and hypotheses
  # - No blockchain recording (free modification)
  # - Session-based organization
  #
  class ContextManager
    CONTEXT_DIR = File.expand_path('../../context', __dir__)

    def initialize(context_dir = CONTEXT_DIR)
      @context_dir = context_dir
      FileUtils.mkdir_p(@context_dir)
    end

    # List all active sessions
    #
    # @return [Array<Hash>] List of session info
    def list_sessions
      session_dirs.map do |dir|
        session_id = File.basename(dir)
        contexts = list_contexts_in_session(session_id)
        {
          session_id: session_id,
          context_count: contexts.size,
          created_at: File.ctime(dir),
          modified_at: File.mtime(dir)
        }
      end.sort_by { |s| s[:modified_at] }.reverse
    end

    # List all contexts in a session
    #
    # @param session_id [String] Session ID
    # @return [Array<Hash>] List of context summaries
    def list_contexts_in_session(session_id)
      session_dir = File.join(@context_dir, session_id)
      return [] unless File.directory?(session_dir)

      context_dirs(session_dir).map do |dir|
        skill = AnthropicSkillParser.parse(dir)
        next unless skill

        {
          name: skill.name,
          description: skill.description,
          has_scripts: skill.has_scripts?,
          has_assets: skill.has_assets?,
          has_references: skill.has_references?
        }
      end.compact
    end

    # Get a specific context
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @return [AnthropicSkillParser::SkillEntry, nil] The context entry or nil
    def get_context(session_id, name)
      context_dir = File.join(@context_dir, session_id, name)
      return nil unless File.directory?(context_dir)

      AnthropicSkillParser.parse(context_dir)
    end

    # Save a context (create or update)
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @param content [String] Full content including YAML frontmatter
    # @param create_subdirs [Boolean] Whether to create scripts/assets/references
    # @return [Hash] Result with success status
    def save_context(session_id, name, content, create_subdirs: false)
      session_dir = File.join(@context_dir, session_id)
      FileUtils.mkdir_p(session_dir)

      context_dir = File.join(session_dir, name)
      
      if File.directory?(context_dir)
        # Update existing
        skill = AnthropicSkillParser.update(context_dir, content)
        { success: true, action: 'updated', context: skill.to_h }
      else
        # Create new
        skill = AnthropicSkillParser.create(session_dir, name, content, create_subdirs: create_subdirs)
        { success: true, action: 'created', context: skill.to_h }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end

    # Delete a context
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @return [Hash] Result with success status
    def delete_context(session_id, name)
      context_dir = File.join(@context_dir, session_id, name)
      
      unless File.directory?(context_dir)
        return { success: false, error: "Context '#{name}' not found in session '#{session_id}'" }
      end

      FileUtils.rm_rf(context_dir)
      { success: true, deleted: name }
    end

    # Delete an entire session
    #
    # @param session_id [String] Session ID
    # @return [Hash] Result with success status
    def delete_session(session_id)
      session_dir = File.join(@context_dir, session_id)
      
      unless File.directory?(session_dir)
        return { success: false, error: "Session '#{session_id}' not found" }
      end

      contexts_count = context_dirs(session_dir).size
      FileUtils.rm_rf(session_dir)
      { success: true, deleted: session_id, contexts_deleted: contexts_count }
    end

    # Create a subdirectory (scripts, assets, or references)
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @param subdir [String] Subdirectory name ('scripts', 'assets', or 'references')
    # @return [Hash] Result with success status and path
    def create_subdir(session_id, name, subdir)
      valid_subdirs = %w[scripts assets references]
      unless valid_subdirs.include?(subdir)
        return { success: false, error: "Invalid subdir. Must be one of: #{valid_subdirs.join(', ')}" }
      end

      context_dir = File.join(@context_dir, session_id, name)
      unless File.directory?(context_dir)
        return { success: false, error: "Context '#{name}' not found in session '#{session_id}'" }
      end

      subdir_path = File.join(context_dir, subdir)
      FileUtils.mkdir_p(subdir_path)
      { success: true, path: subdir_path }
    end

    # Generate a unique session ID
    #
    # @param prefix [String] Optional prefix for the session ID
    # @return [String] Generated session ID
    def generate_session_id(prefix: 'session')
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      random = SecureRandom.hex(4)
      "#{prefix}_#{timestamp}_#{random}"
    end

    # List scripts in a context
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @return [Array<Hash>] List of script info
    def list_scripts(session_id, name)
      context = get_context(session_id, name)
      return [] unless context

      AnthropicSkillParser.list_scripts(context)
    end

    # List assets in a context
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @return [Array<Hash>] List of asset info
    def list_assets(session_id, name)
      context = get_context(session_id, name)
      return [] unless context

      AnthropicSkillParser.list_assets(context)
    end

    private

    def session_dirs
      Dir[File.join(@context_dir, '*')].select { |f| File.directory?(f) }
    end

    def context_dirs(session_dir)
      Dir[File.join(session_dir, '*')].select { |f| File.directory?(f) }
    end
  end
end
