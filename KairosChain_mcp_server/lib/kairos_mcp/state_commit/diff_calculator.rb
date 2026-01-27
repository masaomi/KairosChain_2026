# frozen_string_literal: true

require 'set'

module KairosMcp
  module StateCommit
    # DiffCalculator: Calculates differences between snapshots
    #
    # Detects:
    # - Added/modified/deleted items in each layer
    # - Promotions (L2→L1, L1→L0)
    # - Demotions (L1→L2, L0→L1)
    #
    class DiffCalculator
      # Calculate diff between previous snapshot and current manifest
      #
      # @param prev_snapshot [Hash, nil] Previous snapshot (nil for first commit)
      # @param current_manifest [Hash] Current manifest from ManifestBuilder
      # @return [Hash] Diff result with changes per layer
      def calculate(prev_snapshot, current_manifest)
        if prev_snapshot.nil?
          return initial_diff(current_manifest)
        end

        prev_layers = normalize_layers(prev_snapshot['layers'] || prev_snapshot[:layers])
        curr_layers = current_manifest[:layers]

        {
          L0: calculate_layer_diff(:L0, prev_layers, curr_layers),
          L1: calculate_layer_diff(:L1, prev_layers, curr_layers),
          L2: calculate_layer_diff(:L2, prev_layers, curr_layers),
          promotions: detect_promotions(prev_layers, curr_layers),
          demotions: detect_demotions(prev_layers, curr_layers),
          has_changes: has_changes?(prev_snapshot, current_manifest)
        }
      end

      # Check if there are any changes between snapshot and manifest
      #
      # @param prev_snapshot [Hash, nil] Previous snapshot
      # @param current_manifest [Hash] Current manifest
      # @return [Boolean] True if there are changes
      def has_changes?(prev_snapshot, current_manifest)
        return true if prev_snapshot.nil?

        prev_hash = prev_snapshot['snapshot_hash'] || prev_snapshot[:snapshot_hash]
        curr_hash = current_manifest[:combined_hash]

        prev_hash != curr_hash
      end

      # Generate a summary of changes
      #
      # @param diff [Hash] Diff result from calculate
      # @return [Hash] Summary with counts
      def summarize(diff)
        {
          L0_changed: diff[:L0][:changed],
          L1_added: diff[:L1][:added].size,
          L1_modified: diff[:L1][:modified].size,
          L1_deleted: diff[:L1][:deleted].size,
          L2_sessions_added: diff[:L2][:added].size,
          L2_sessions_deleted: diff[:L2][:deleted].size,
          promotions: diff[:promotions].size,
          demotions: diff[:demotions].size,
          total_changes: count_total_changes(diff)
        }
      end

      # Generate human-readable change description
      #
      # @param diff [Hash] Diff result from calculate
      # @return [String] Description of changes
      def describe(diff)
        parts = []

        if diff[:L0][:changed]
          parts << "L0: changed"
        end

        l1_changes = []
        l1_changes << "+#{diff[:L1][:added].size}" if diff[:L1][:added].any?
        l1_changes << "~#{diff[:L1][:modified].size}" if diff[:L1][:modified].any?
        l1_changes << "-#{diff[:L1][:deleted].size}" if diff[:L1][:deleted].any?
        parts << "L1: #{l1_changes.join(', ')}" if l1_changes.any?

        l2_changes = []
        l2_changes << "+#{diff[:L2][:added].size} sessions" if diff[:L2][:added].any?
        l2_changes << "-#{diff[:L2][:deleted].size} sessions" if diff[:L2][:deleted].any?
        parts << "L2: #{l2_changes.join(', ')}" if l2_changes.any?

        if diff[:promotions].any?
          parts << "Promotions: #{diff[:promotions].size}"
        end

        if diff[:demotions].any?
          parts << "Demotions: #{diff[:demotions].size}"
        end

        parts.empty? ? "No changes" : parts.join("; ")
      end

      private

      # Generate diff for initial commit (no previous snapshot)
      def initial_diff(current_manifest)
        layers = current_manifest[:layers]

        {
          L0: {
            changed: true,
            added: layers[:L0][:skills].map { |s| s[:id] },
            modified: [],
            deleted: []
          },
          L1: {
            changed: layers[:L1][:knowledge_count] > 0,
            added: layers[:L1][:knowledge].map { |k| k[:name] },
            modified: [],
            deleted: []
          },
          L2: {
            changed: layers[:L2][:session_count] > 0,
            added: layers[:L2][:sessions].map { |s| s[:id] },
            modified: [],
            deleted: []
          },
          promotions: [],
          demotions: [],
          has_changes: true
        }
      end

      # Normalize layer keys to symbols
      def normalize_layers(layers)
        return {} unless layers

        result = {}
        layers.each do |key, value|
          normalized_key = key.to_s.to_sym
          result[normalized_key] = deep_symbolize_keys(value)
        end
        result
      end

      # Deep symbolize keys in a hash
      def deep_symbolize_keys(obj)
        case obj
        when Hash
          obj.transform_keys(&:to_sym).transform_values { |v| deep_symbolize_keys(v) }
        when Array
          obj.map { |v| deep_symbolize_keys(v) }
        else
          obj
        end
      end

      # Calculate diff for a specific layer
      def calculate_layer_diff(layer, prev_layers, curr_layers)
        prev = prev_layers[layer] || {}
        curr = curr_layers[layer] || {}

        case layer
        when :L0
          calculate_l0_diff(prev, curr)
        when :L1
          calculate_l1_diff(prev, curr)
        when :L2
          calculate_l2_diff(prev, curr)
        end
      end

      # Calculate L0 diff (skill changes)
      def calculate_l0_diff(prev, curr)
        prev_skills = (prev[:skills] || []).map { |s| [s[:id], s[:hash]] }.to_h
        curr_skills = (curr[:skills] || []).map { |s| [s[:id], s[:hash]] }.to_h

        prev_ids = Set.new(prev_skills.keys)
        curr_ids = Set.new(curr_skills.keys)

        added = (curr_ids - prev_ids).to_a
        deleted = (prev_ids - curr_ids).to_a
        
        modified = (prev_ids & curr_ids).select do |id|
          prev_skills[id] != curr_skills[id]
        end.to_a

        # Also check dsl_file_hash for overall changes
        dsl_changed = prev[:dsl_file_hash] != curr[:dsl_file_hash]

        {
          changed: dsl_changed || added.any? || modified.any? || deleted.any?,
          added: added,
          modified: modified,
          deleted: deleted,
          dsl_file_changed: dsl_changed
        }
      end

      # Calculate L1 diff (knowledge changes)
      def calculate_l1_diff(prev, curr)
        prev_knowledge = (prev[:knowledge] || []).map { |k| [k[:name], k[:hash]] }.to_h
        curr_knowledge = (curr[:knowledge] || []).map { |k| [k[:name], k[:hash]] }.to_h

        prev_names = Set.new(prev_knowledge.keys)
        curr_names = Set.new(curr_knowledge.keys)

        added = (curr_names - prev_names).to_a
        deleted = (prev_names - curr_names).to_a

        modified = (prev_names & curr_names).select do |name|
          prev_knowledge[name] != curr_knowledge[name]
        end.to_a

        {
          changed: added.any? || modified.any? || deleted.any?,
          added: added,
          modified: modified,
          deleted: deleted
        }
      end

      # Calculate L2 diff (session/context changes)
      def calculate_l2_diff(prev, curr)
        prev_sessions = (prev[:sessions] || []).map { |s| [s[:id], s[:hash]] }.to_h
        curr_sessions = (curr[:sessions] || []).map { |s| [s[:id], s[:hash]] }.to_h

        prev_ids = Set.new(prev_sessions.keys)
        curr_ids = Set.new(curr_sessions.keys)

        added = (curr_ids - prev_ids).to_a
        deleted = (prev_ids - curr_ids).to_a

        modified = (prev_ids & curr_ids).select do |id|
          prev_sessions[id] != curr_sessions[id]
        end.to_a

        {
          changed: added.any? || modified.any? || deleted.any?,
          added: added,
          modified: modified,
          deleted: deleted
        }
      end

      # Detect promotions (L2→L1 or L1→L0)
      def detect_promotions(prev_layers, curr_layers)
        promotions = []

        # L2→L1: Item was in L2 before, now in L1
        prev_l2_items = extract_item_names(prev_layers[:L2], :sessions, :id)
        curr_l1_items = extract_item_names(curr_layers[:L1], :knowledge, :name)
        prev_l1_items = extract_item_names(prev_layers[:L1], :knowledge, :name)

        # Check for items that appear in L1 now but were in L2 before
        # (This is a heuristic - item names might match)
        new_l1_items = curr_l1_items - prev_l1_items
        new_l1_items.each do |name|
          # Check if a similar name existed in L2
          if prev_l2_items.any? { |s| s.include?(name) || name.include?(s.to_s.split('_').last.to_s) }
            promotions << { from: "L2", to: "L1", item: name }
          end
        end

        promotions
      end

      # Detect demotions (L1→L2 or L0→L1)
      def detect_demotions(prev_layers, curr_layers)
        demotions = []

        # L1→L2: Item was in L1 before, might be in L2 now (or archived)
        prev_l1_items = extract_item_names(prev_layers[:L1], :knowledge, :name)
        curr_l1_items = extract_item_names(curr_layers[:L1], :knowledge, :name)
        curr_l1_archived = (curr_layers[:L1][:archived] || []).map { |a| a[:name] }

        removed_from_l1 = prev_l1_items - curr_l1_items
        removed_from_l1.each do |name|
          if curr_l1_archived.include?(name)
            demotions << { from: "L1", to: "archived", item: name }
          end
        end

        demotions
      end

      # Extract item names from a layer
      def extract_item_names(layer, collection_key, name_key)
        return Set.new unless layer
        items = layer[collection_key] || []
        Set.new(items.map { |i| i[name_key] })
      end

      # Count total changes
      def count_total_changes(diff)
        count = 0
        count += 1 if diff[:L0][:changed]
        count += diff[:L1][:added].size
        count += diff[:L1][:modified].size
        count += diff[:L1][:deleted].size
        count += diff[:L2][:added].size
        count += diff[:L2][:deleted].size
        count += diff[:promotions].size
        count += diff[:demotions].size
        count
      end
    end
  end
end
