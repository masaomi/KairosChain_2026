# frozen_string_literal: true

require 'yaml'

module ProjectManager
  module ToolHelpers
    def pm_store
      @_pm_store ||= Store.new
    end

    # Named so a test can point the reader at a file it wrote, and still drive
    # the real pm_config rather than a stand-in for it.
    def pm_config_path
      File.expand_path('../../config/pm.yml', __dir__)
    end

    # pm.yml is the one file an operator is invited to edit, and `skillset
    # upgrade` deliberately never overwrites it, so a bad edit is permanent
    # rather than transient. YAML.safe_load_file is strict — a tab indent, an
    # unclosed quote, a bare date, an &anchor and a :symbol each raise, five of
    # five measured — and the raise happened here, one level above every guard
    # the tools carry. One stray character took every pm tool out at once.
    #
    # A document that parses but is not a mapping is the same failure in another
    # shape: it breaks the first caller that subscripts it. It is coerced here
    # rather than at each call site, because a call-site guard is re-acquired by
    # the next caller and pm_record's was never written.
    #
    # Falling back is not the whole fix. Defaults wearing the operator's settings
    # are worse than the outage they replace, so the reason is kept and
    # pm_config_error hands it to any caller that reports to a human.
    def pm_config
      return @_pm_config if defined?(@_pm_config)

      @_pm_config_error = nil
      loaded = File.exist?(pm_config_path) ? YAML.safe_load_file(pm_config_path) : {}
      @_pm_config =
        if loaded.is_a?(Hash)
          loaded
        else
          # An empty file — no bytes, blank lines, or comments only — parses to
          # nil, and that is the operator saying "no settings". Every other
          # non-mapping is a mistake and is named, `false` included: it is an
          # affirmative value that happens not to be a Hash, so treating it as
          # emptiness would hand back defaults with nothing said.
          @_pm_config_error = "pm.yml is #{loaded.class}, expected a mapping" unless loaded.nil?
          {}
        end
    rescue StandardError => e
      @_pm_config_error = "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
      @_pm_config = {}
    end

    # nil when pm.yml was usable, or absent — absence is the documented default,
    # not a failure. Otherwise, why the file was ignored.
    def pm_config_error
      pm_config
      @_pm_config_error
    end
  end
end
