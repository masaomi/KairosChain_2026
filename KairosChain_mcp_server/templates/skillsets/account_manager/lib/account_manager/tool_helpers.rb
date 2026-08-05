# frozen_string_literal: true

require 'json'

module AccountManager
  module ToolHelpers
    DEFAULT_LEDGER = 'main'

    # The ledger is named on every call, defaulting to the single configured
    # one while only one exists — a default, not an inference: every result
    # reports the ledger it used (INV-AM-2).
    #
    # A FRESH store per call, never memoized. Tool objects are registered once
    # and reused for the life of the process, so a store cached on one tool
    # holds a snapshot taken before every write another tool has made since.
    # Saving that snapshot erases them: review R1 posted an invoice through
    # am_entry, imported evidence through am_receipt, posted a second invoice,
    # and the second invoice — acknowledged with an id — was absent from disk.
    # Re-reading costs one file read; the alternative cost figures.
    def am_store(args = {})
      Store.new(ledger: ledger_name(args))
    end

    # A ledger name reaches the filesystem, so it is checked rather than
    # trusted: `..` in it would address a directory outside the accounts tree.
    def ledger_name(args)
      name = (args['ledger'] || DEFAULT_LEDGER).to_s
      unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
        raise Refused, "ledger name #{name.inspect} is not a plain name (letters, digits, - and _)"
      end

      name
    end

    def am_report(args = {}) = Report.new(am_store(args))
    def am_importer(args = {}) = Importer.new(am_store(args))

    # Every refusal reaches the caller as a refusal, not as a stack trace, and
    # keeps the invariant reference the store put in the message.
    def am_respond(args = {})
      payload = yield
      payload = { 'result' => payload } unless payload.is_a?(Hash)
      text_content(JSON.pretty_generate(payload.merge('ledger' => (args['ledger'] || DEFAULT_LEDGER).to_s)))
    rescue Date::Error, ArgumentError => e
      # Unreadable dates and amounts are the caller's mistake, not the tool's
      # fault, and they must arrive as refusals like every other bad input.
      text_content(JSON.pretty_generate({ 'refused' => e.message }))
    rescue Refused, ConfigError => e
      text_content(JSON.pretty_generate({ 'refused' => e.message }))
    rescue StandardError => e
      text_content(JSON.pretty_generate({ 'error' => "#{e.class}: #{e.message}" }))
    end
  end
end
