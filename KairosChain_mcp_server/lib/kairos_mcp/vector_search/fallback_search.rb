# frozen_string_literal: true

require_relative 'base'

module KairosMcp
  module VectorSearch
    # Fallback search implementation using regex matching
    #
    # Used when hnswlib/informers gems are not installed.
    # Provides basic keyword matching without semantic understanding.
    #
    class FallbackSearch < Base
      def initialize
        @documents = {}
        @ready = true
      end

      def add(id, text, metadata: {})
        @documents[id.to_s] = {
          text: text.to_s.downcase,
          original_text: text.to_s,
          metadata: metadata
        }
        true
      end

      def remove(id)
        @documents.delete(id.to_s)
        true
      end

      def search(query, k: 5)
        return [] if @documents.empty?

        query_terms = tokenize(query.to_s.downcase)
        return [] if query_terms.empty?

        scored = @documents.map do |id, doc|
          score = calculate_score(query_terms, doc[:text])
          { id: id, score: score, metadata: doc[:metadata] }
        end

        scored
          .select { |r| r[:score] > 0 }
          .sort_by { |r| -r[:score] }
          .first(k)
      end

      def rebuild(documents)
        @documents.clear
        documents.each do |doc|
          add(doc[:id], doc[:text], metadata: doc[:metadata] || {})
        end
        true
      end

      def save
        # Fallback search doesn't persist - documents are rebuilt on startup
        true
      end

      def load
        # Fallback search doesn't persist
        true
      end

      def ready?
        @ready
      end

      def count
        @documents.size
      end

      def semantic?
        false
      end

      private

      def tokenize(text)
        # Simple tokenization: split on non-word characters, filter short tokens
        text
          .split(/[^\p{L}\p{N}]+/)
          .map(&:strip)
          .reject { |t| t.length < 2 }
      end

      def calculate_score(query_terms, doc_text)
        # Simple TF-based scoring
        doc_tokens = tokenize(doc_text)
        return 0.0 if doc_tokens.empty?

        matches = query_terms.count { |term| doc_tokens.include?(term) }
        
        # Also check for partial matches (substring)
        partial_matches = query_terms.count do |term|
          doc_tokens.any? { |doc_term| doc_term.include?(term) || term.include?(doc_term) }
        end

        # Combine exact and partial matches
        exact_score = matches.to_f / query_terms.size
        partial_score = (partial_matches - matches).to_f / query_terms.size * 0.5

        exact_score + partial_score
      end
    end
  end
end
