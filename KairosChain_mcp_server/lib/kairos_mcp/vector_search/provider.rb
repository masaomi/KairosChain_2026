# frozen_string_literal: true

require 'json'

module KairosMcp
  module VectorSearch
    # Factory for creating vector search instances
    #
    # Automatically detects available gems and creates the appropriate
    # search implementation:
    #   - SemanticSearch when hnswlib + informers are available
    #   - FallbackSearch when gems are not installed
    #
    # Usage:
    #   search = KairosMcp::VectorSearch.create(index_path: 'storage/embeddings/skills')
    #   search.add('skill_1', 'Content about authentication and login')
    #   results = search.search('user login', k: 5)
    #
    class << self
      # Check if semantic search gems are available
      #
      # @return [Boolean] true if hnswlib and informers are installed
      def available?
        return @available if defined?(@available)

        @available = check_gems_available
      end

      # Check gems without caching (useful for testing)
      #
      # @return [Boolean]
      def check_gems_available
        require 'hnswlib'
        require 'informers'
        true
      rescue LoadError
        false
      end

      # Reset the availability cache (for testing)
      def reset_availability!
        remove_instance_variable(:@available) if defined?(@available)
      end

      # Create a vector search instance
      #
      # @param index_path [String] Path to store/load index files
      # @param dimension [Integer] Embedding dimension (default: 384 for MiniLM)
      # @param model [String] Sentence transformer model name
      # @param force_fallback [Boolean] Force fallback search even if gems available
      # @return [Base] A vector search instance
      def create(index_path: nil, dimension: 384, model: nil, force_fallback: false)
        if !force_fallback && available?
          require_relative 'semantic_search'
          SemanticSearch.new(
            index_path: index_path || default_index_path,
            dimension: dimension,
            model: model || SemanticSearch::DEFAULT_MODEL
          )
        else
          require_relative 'fallback_search'
          FallbackSearch.new
        end
      end

      # Get status information about vector search
      #
      # @return [Hash] Status including availability and configuration
      def status
        {
          semantic_available: available?,
          gems: {
            hnswlib: gem_version('hnswlib'),
            informers: gem_version('informers')
          },
          default_model: available? ? 'sentence-transformers/all-MiniLM-L6-v2' : nil,
          default_dimension: 384
        }
      end

      private

      def default_index_path
        File.expand_path('../../../storage/embeddings', __dir__)
      end

      def gem_version(gem_name)
        require gem_name
        Gem.loaded_specs[gem_name]&.version&.to_s || 'loaded'
      rescue LoadError
        nil
      end
    end
  end
end

# Auto-require the fallback implementation (always available)
require_relative 'fallback_search'
