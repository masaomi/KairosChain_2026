# frozen_string_literal: true

require 'digest'
require 'json'

module KairosMcp
  module StateCommit
    # ManifestBuilder: Generates manifests for L0/L1/L2 layers
    #
    # A manifest contains:
    # - List of skills/knowledge/contexts with their hashes
    # - Combined hash for the entire layer
    # - Metadata about the layer state
    #
    class ManifestBuilder
      DSL_PATH = File.expand_path('../../../../skills/kairos.rb', __dir__)
      MD_PATH = File.expand_path('../../../../skills/kairos.md', __dir__)
      KNOWLEDGE_DIR = File.expand_path('../../../../knowledge', __dir__)
      CONTEXT_DIR = File.expand_path('../../../../context', __dir__)

      def initialize
        @knowledge_provider = nil
        @context_manager = nil
      end

      # Build manifest for L0 (Kairos meta-skills)
      #
      # @return [Hash] L0 manifest
      def build_l0_manifest
        skills = []
        
        # Parse skills from kairos.rb
        if File.exist?(DSL_PATH)
          require_relative '../kairos'
          Kairos.skills.each do |skill|
            skills << {
              id: skill.id.to_s,
              version: skill.version,
              hash: calculate_skill_hash(skill)
            }
          end
        end

        # Calculate file hashes
        dsl_file_hash = file_hash(DSL_PATH)
        md_file_hash = file_hash(MD_PATH)

        # Build manifest
        manifest = {
          dsl_file_hash: dsl_file_hash,
          md_file_hash: md_file_hash,
          skill_count: skills.size,
          skills: skills.sort_by { |s| s[:id] }
        }

        # Calculate combined manifest hash
        manifest[:manifest_hash] = calculate_manifest_hash(manifest)
        manifest
      end

      # Build manifest for L1 (Knowledge layer)
      #
      # @return [Hash] L1 manifest
      def build_l1_manifest
        knowledge_items = []

        if File.directory?(KNOWLEDGE_DIR)
          knowledge_provider.list.each do |item|
            skill = knowledge_provider.get(item[:name])
            next unless skill

            content_hash = file_hash(skill.md_file_path)
            knowledge_items << {
              name: item[:name],
              version: item[:version],
              hash: content_hash,
              tags: item[:tags] || []
            }
          end
        end

        # Also check for archived knowledge
        archived_items = []
        knowledge_provider.list_archived.each do |item|
          archived_items << {
            name: item[:name],
            archived_at: item[:archived_at],
            hash: item[:content_hash]
          }
        end

        manifest = {
          knowledge_count: knowledge_items.size,
          archived_count: archived_items.size,
          knowledge: knowledge_items.sort_by { |k| k[:name] },
          archived: archived_items.sort_by { |a| a[:name] }
        }

        manifest[:manifest_hash] = calculate_manifest_hash(manifest)
        manifest
      end

      # Build manifest for L2 (Context layer)
      #
      # @return [Hash] L2 manifest
      def build_l2_manifest
        sessions = []

        if File.directory?(CONTEXT_DIR)
          context_manager.list_sessions.each do |session|
            contexts = context_manager.list_contexts_in_session(session[:session_id])
            
            # Calculate hash for session contents
            session_content = contexts.map do |ctx|
              {
                name: ctx[:name],
                description: ctx[:description]
              }
            end.sort_by { |c| c[:name] }

            sessions << {
              id: session[:session_id],
              context_count: contexts.size,
              hash: Digest::SHA256.hexdigest(session_content.to_json)
            }
          end
        end

        manifest = {
          session_count: sessions.size,
          sessions: sessions.sort_by { |s| s[:id] }
        }

        manifest[:manifest_hash] = calculate_manifest_hash(manifest)
        manifest
      end

      # Build full manifest for all layers
      #
      # @return [Hash] Full manifest with combined hash
      def build_full_manifest
        l0 = build_l0_manifest
        l1 = build_l1_manifest
        l2 = build_l2_manifest

        manifest = {
          layers: {
            L0: l0,
            L1: l1,
            L2: l2
          },
          generated_at: Time.now.iso8601
        }

        # Calculate combined hash from all layer manifest hashes
        combined_input = [
          l0[:manifest_hash],
          l1[:manifest_hash],
          l2[:manifest_hash]
        ].join(':')

        manifest[:combined_hash] = Digest::SHA256.hexdigest(combined_input)
        manifest
      end

      private

      def knowledge_provider
        @knowledge_provider ||= begin
          require_relative '../knowledge_provider'
          KnowledgeProvider.new(KNOWLEDGE_DIR, vector_search_enabled: false)
        end
      end

      def context_manager
        @context_manager ||= begin
          require_relative '../context_manager'
          ContextManager.new(CONTEXT_DIR)
        end
      end

      def file_hash(path)
        return nil unless File.exist?(path)
        Digest::SHA256.hexdigest(File.read(path))
      end

      def calculate_skill_hash(skill)
        # Create a deterministic hash from skill properties
        content = {
          id: skill.id.to_s,
          version: skill.version,
          title: skill.title,
          content: skill.content,
          guarantees: skill.guarantees,
          evolution_rules: skill.evolution_rules&.to_h
        }
        Digest::SHA256.hexdigest(content.to_json)
      end

      def calculate_manifest_hash(manifest)
        # Create a deterministic hash from manifest
        # Exclude the manifest_hash field itself
        data = manifest.reject { |k, _| k == :manifest_hash }
        Digest::SHA256.hexdigest(data.to_json)
      end
    end
  end
end
