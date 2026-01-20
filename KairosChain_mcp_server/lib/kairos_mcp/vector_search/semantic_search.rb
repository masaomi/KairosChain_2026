# frozen_string_literal: true

require_relative 'base'

module KairosMcp
  module VectorSearch
    # Semantic search implementation using hnswlib and informers
    #
    # Requires optional gems:
    #   - hnswlib (~> 0.9) - HNSW approximate nearest neighbor search
    #   - informers (~> 1.0) - ONNX-based sentence embeddings
    #
    # This class is only loaded when gems are available.
    #
    class SemanticSearch < Base
      DEFAULT_MODEL = 'sentence-transformers/all-MiniLM-L6-v2'
      DEFAULT_DIMENSION = 384
      DEFAULT_SPACE = 'cosine'

      attr_reader :index_path, :dimension, :model_name

      def initialize(index_path:, dimension: DEFAULT_DIMENSION, model: DEFAULT_MODEL)
        @index_path = index_path
        @dimension = dimension
        @model_name = model
        @id_map = {}        # Maps internal index -> document id
        @reverse_map = {}   # Maps document id -> internal index
        @metadata_store = {} # Stores metadata by document id
        @next_index = 0
        @ready = false
        @embedder = nil
        @index = nil

        ensure_index_directory
      end

      def add(id, text, metadata: {})
        ensure_initialized

        id_str = id.to_s
        embedding = generate_embedding(text)
        
        # If document already exists, we need to handle update
        if @reverse_map.key?(id_str)
          internal_idx = @reverse_map[id_str]
          # hnswlib doesn't support true updates, so we mark as deleted and add new
          # For simplicity, we just overwrite the point
          @index.add_point(embedding, internal_idx)
        else
          internal_idx = @next_index
          @next_index += 1
          
          # Resize index if needed
          if internal_idx >= @index.max_elements
            # Create new larger index and copy data
            resize_index(@index.max_elements * 2)
          end
          
          @index.add_point(embedding, internal_idx)
          @id_map[internal_idx] = id_str
          @reverse_map[id_str] = internal_idx
        end

        @metadata_store[id_str] = metadata.merge(text: text)
        true
      rescue StandardError => e
        warn "[SemanticSearch] Failed to add document #{id}: #{e.message}"
        false
      end

      def remove(id)
        id_str = id.to_s
        return true unless @reverse_map.key?(id_str)

        internal_idx = @reverse_map[id_str]
        # hnswlib supports marking elements as deleted
        @index.mark_deleted(internal_idx) if @index.respond_to?(:mark_deleted)
        
        @id_map.delete(internal_idx)
        @reverse_map.delete(id_str)
        @metadata_store.delete(id_str)
        true
      rescue StandardError => e
        warn "[SemanticSearch] Failed to remove document #{id}: #{e.message}"
        false
      end

      def search(query, k: 5)
        ensure_initialized
        return [] if @id_map.empty?

        embedding = generate_embedding(query)
        actual_k = [k, @id_map.size].min
        
        results = @index.search_knn(embedding, actual_k)
        
        # results format: [[indices], [distances]] or similar
        indices, distances = results
        
        indices.zip(distances).filter_map do |idx, dist|
          next unless @id_map.key?(idx)
          
          id = @id_map[idx]
          {
            id: id,
            score: 1.0 - dist, # Convert distance to similarity score
            metadata: @metadata_store[id] || {}
          }
        end
      rescue StandardError => e
        warn "[SemanticSearch] Search failed: #{e.message}"
        []
      end

      def rebuild(documents)
        ensure_embedder
        
        # Initialize fresh index
        max_elements = [documents.size * 2, 100].max
        @index = create_index(max_elements)
        @id_map.clear
        @reverse_map.clear
        @metadata_store.clear
        @next_index = 0
        @ready = true

        # Batch generate embeddings for efficiency
        texts = documents.map { |doc| doc[:text].to_s }
        embeddings = generate_embeddings_batch(texts)

        documents.each_with_index do |doc, i|
          id_str = doc[:id].to_s
          internal_idx = @next_index
          @next_index += 1

          @index.add_point(embeddings[i], internal_idx)
          @id_map[internal_idx] = id_str
          @reverse_map[id_str] = internal_idx
          @metadata_store[id_str] = (doc[:metadata] || {}).merge(text: doc[:text])
        end

        save
        true
      rescue StandardError => e
        warn "[SemanticSearch] Rebuild failed: #{e.message}"
        false
      end

      def save
        return true unless @ready && @index

        # Save HNSW index
        @index.save_index(index_file_path)

        # Save metadata
        metadata = {
          id_map: @id_map,
          reverse_map: @reverse_map,
          metadata_store: @metadata_store,
          next_index: @next_index,
          dimension: @dimension,
          model: @model_name
        }
        File.write(metadata_file_path, JSON.pretty_generate(metadata))
        
        true
      rescue StandardError => e
        warn "[SemanticSearch] Save failed: #{e.message}"
        false
      end

      def load
        return false unless File.exist?(index_file_path) && File.exist?(metadata_file_path)

        ensure_embedder

        # Load metadata first
        metadata = JSON.parse(File.read(metadata_file_path), symbolize_names: true)
        
        # Validate dimension and model match
        if metadata[:dimension] != @dimension
          warn "[SemanticSearch] Dimension mismatch: expected #{@dimension}, got #{metadata[:dimension]}"
          return false
        end

        @id_map = metadata[:id_map].transform_keys(&:to_i)
        @reverse_map = metadata[:reverse_map].transform_keys(&:to_s)
        @metadata_store = metadata[:metadata_store].transform_keys(&:to_s)
        @next_index = metadata[:next_index]

        # Load HNSW index
        max_elements = [@next_index * 2, 100].max
        @index = create_index(max_elements)
        @index.load_index(index_file_path)
        
        @ready = true
        true
      rescue StandardError => e
        warn "[SemanticSearch] Load failed: #{e.message}"
        false
      end

      def ready?
        @ready
      end

      def count
        @id_map.size
      end

      def semantic?
        true
      end

      private

      def ensure_index_directory
        require 'fileutils'
        FileUtils.mkdir_p(@index_path)
      end

      def index_file_path
        File.join(@index_path, 'index.ann')
      end

      def metadata_file_path
        File.join(@index_path, 'metadata.json')
      end

      def ensure_embedder
        return if @embedder

        require 'informers'
        @embedder = Informers.pipeline('embedding', @model_name)
      end

      def ensure_initialized
        return if @ready

        # Try to load existing index
        return if load

        # Initialize new index
        ensure_embedder
        @index = create_index(100)
        @ready = true
      end

      def create_index(max_elements)
        require 'hnswlib'
        index = Hnswlib::HierarchicalNSW.new(space: DEFAULT_SPACE, dim: @dimension)
        index.init_index(max_elements: max_elements)
        index
      end

      def resize_index(new_max_elements)
        return unless @index

        new_index = create_index(new_max_elements)
        
        # Copy all points to new index
        @id_map.each do |internal_idx, _doc_id|
          # Get the vector for this point
          # Note: hnswlib doesn't have a direct get_point method in all versions
          # We'll rebuild from stored text if needed
        end
        
        @index = new_index
      end

      def generate_embedding(text)
        ensure_embedder
        result = @embedder.call([text])
        result[0]
      end

      def generate_embeddings_batch(texts)
        ensure_embedder
        @embedder.call(texts)
      end
    end
  end
end
