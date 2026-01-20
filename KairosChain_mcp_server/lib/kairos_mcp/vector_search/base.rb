# frozen_string_literal: true

module KairosMcp
  module VectorSearch
    # Abstract base class for vector search implementations
    #
    # Provides a common interface for both semantic search (with RAG)
    # and fallback search (regex-based).
    #
    class Base
      # Add a document to the index
      #
      # @param id [String, Symbol] Document identifier
      # @param text [String] Document text content
      # @param metadata [Hash] Optional metadata
      # @return [Boolean] Success status
      def add(id, text, metadata: {})
        raise NotImplementedError, "#{self.class} must implement #add"
      end

      # Remove a document from the index
      #
      # @param id [String, Symbol] Document identifier
      # @return [Boolean] Success status
      def remove(id)
        raise NotImplementedError, "#{self.class} must implement #remove"
      end

      # Search for similar documents
      #
      # @param query [String] Search query
      # @param k [Integer] Number of results to return
      # @return [Array<Hash>] Array of {id:, score:, metadata:}
      def search(query, k: 5)
        raise NotImplementedError, "#{self.class} must implement #search"
      end

      # Rebuild the entire index from documents
      #
      # @param documents [Array<Hash>] Array of {id:, text:, metadata:}
      # @return [Boolean] Success status
      def rebuild(documents)
        raise NotImplementedError, "#{self.class} must implement #rebuild"
      end

      # Save the index to persistent storage
      #
      # @return [Boolean] Success status
      def save
        raise NotImplementedError, "#{self.class} must implement #save"
      end

      # Load the index from persistent storage
      #
      # @return [Boolean] Success status
      def load
        raise NotImplementedError, "#{self.class} must implement #load"
      end

      # Check if the index exists and is loaded
      #
      # @return [Boolean]
      def ready?
        raise NotImplementedError, "#{self.class} must implement #ready?"
      end

      # Get the number of documents in the index
      #
      # @return [Integer]
      def count
        raise NotImplementedError, "#{self.class} must implement #count"
      end

      # Check if this implementation supports semantic search
      #
      # @return [Boolean]
      def semantic?
        false
      end
    end
  end
end
