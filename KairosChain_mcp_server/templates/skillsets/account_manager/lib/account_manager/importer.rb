# frozen_string_literal: true

require 'csv'
require 'digest'
require 'json'
require 'securerandom'

require 'account_manager/money'

module AccountManager
  # CSV rows land as proposals, never as postings (INV-AM-7). The importer
  # applies a column mapping the operator declared in configuration, which is
  # following an instruction rather than making one; everything inferential —
  # which account the other side belongs to, whether two rows are one
  # transaction — rides along as the agent's suggestion and is decided by the
  # operator.
  class Importer
    def initialize(store)
      @store = store
      @config = store.config
    end

    # rows: array of hashes (already parsed), or csv_text to parse with headers.
    # suggestions: optional, aligned with rows by position; each may carry
    # account / book / tax_label / note / join for the *other* side.
    def import(profile_name:, rows: nil, csv_text: nil, suggestions: nil, batch: nil,
               author: 'agent', now: Time.now)
      profile = @config.profile(profile_name)
      raise Refused, "unknown import profile: #{profile_name}" unless profile

      rows = parse_csv(csv_text) if rows.nil? && csv_text
      raise Refused, 'import needs rows or csv_text' if rows.nil?

      batch ||= "bat_#{SecureRandom.hex(4)}"
      suggestions = Array(suggestions)
      result = { 'profile' => profile_name, 'batch' => batch, 'rows' => rows.size,
                 'undeduplicable' => profile['reference_field'].nil?,
                 'proposed' => [], 'already_present' => [], 'changed' => [] }

      rows.each_with_index do |row, index|
        row = row.transform_keys(&:to_s)
        key = build_key(profile, profile_name, row, batch, index)
        existing = key['reference'] ? @store.find_by_key(key['profile'], key['reference']) : nil
        hash = ::Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))

        if existing
          # A re-import is not silence (INV-AM-9). A key already present whose
          # content differs is reported, never dropped: a bank that revised a
          # provisional amount must not leave the stale figure standing.
          if existing['content_hash'] && existing['content_hash'] != hash
            result['changed'] << { 'key' => key, 'existing_id' => existing['id'],
                                   'existing_state' => existing['state'] || 'posted',
                                   'stored_row' => existing['row'], 'incoming_row' => row }
          else
            result['already_present'] << { 'key' => key, 'existing_id' => existing['id'],
                                           'existing_state' => existing['state'] || 'posted' }
          end
          next
        end

        proposal = @store.add_proposal(
          **mapped_proposal(profile, row, suggestions[index], key, author, now)
        )
        result['proposed'] << proposal['id']
      end

      result
    end

    def parse_csv(text)
      CSV.parse(text, headers: true).map(&:to_h)
    end

    private

    def build_key(profile, profile_name, row, batch, index)
      field = profile['reference_field']
      if field.nil?
        # Stable within one import and meaningless across two, so the operator
        # sees a re-import as a re-import (INV-AM-9).
        { 'profile' => profile_name, 'batch' => batch, 'position' => index, 'reference' => nil }
      else
        reference = row[field]
        raise Refused, "row #{index + 1} has no value in reference field #{field.inspect}" if reference.to_s.empty?

        { 'profile' => profile_name, 'reference' => reference.to_s }
      end
    end

    def mapped_proposal(profile, row, suggestion, key, author, now)
      columns = profile['columns']
      amount = Money.to_minor(row.fetch(columns['amount']))
      debit = debit_side?(profile, row, amount)
      magnitude = Money.render(amount.abs)

      lines = [{ 'account' => profile['account'], 'book' => profile['book'],
                 'debit' => debit ? magnitude : nil, 'credit' => debit ? nil : magnitude }.compact]
      suggestion = (suggestion || {}).transform_keys(&:to_s)
      if suggestion['account']
        lines << { 'account' => suggestion['account'], 'book' => suggestion['book'] || profile['book'],
                   'debit' => debit ? nil : magnitude, 'credit' => debit ? magnitude : nil,
                   'tax_label' => suggestion['tax_label'], 'note' => suggestion['note'] }.compact
      end

      { transaction_date: row.fetch(columns['transaction_date']),
        settlement_date: columns['settlement_date'] ? row[columns['settlement_date']] : nil,
        description: row[columns['description']].to_s,
        lines: lines.size >= 2 ? lines : nil,
        suggested: { 'lines' => lines, 'join' => suggestion['join'], 'from_row' => true },
        author: author, key: key, row: row, now: now }
    end

    # How the source marks a debit is declared, never guessed. Either a marker
    # column carries the source's own word for it, or the amount is signed.
    def debit_side?(profile, row, amount)
      marker = profile['debit_marker']
      return row[marker['column']].to_s == marker['debit_value'].to_s if marker

      profile['sign'].to_s == 'positive_is_credit' ? amount.negative? : amount.positive?
    end
  end
end
