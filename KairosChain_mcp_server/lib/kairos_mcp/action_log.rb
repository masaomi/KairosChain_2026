require 'json'
require 'time'
require 'fileutils'

module KairosMcp
  class ActionLog
    LOG_PATH = File.expand_path('../../skills/action_log.jsonl', __dir__)
    
    def self.record(action:, skill_id: nil, details: nil)
      entry = {
        timestamp: Time.now.iso8601,
        action: action,
        skill_id: skill_id,
        details: details
      }
      
      FileUtils.mkdir_p(File.dirname(LOG_PATH))
      
      File.open(LOG_PATH, 'a') { |f| f.puts(entry.to_json) }
    end
    
    def self.history(limit: 50)
      return [] unless File.exist?(LOG_PATH)
      File.readlines(LOG_PATH).last(limit).map { |l| JSON.parse(l) rescue nil }.compact
    end
    
    def self.clear!
      File.write(LOG_PATH, '')
    end
  end
end
