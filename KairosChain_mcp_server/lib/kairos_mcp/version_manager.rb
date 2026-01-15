require 'fileutils'
require 'json'
require 'time'

module KairosMcp
  class VersionManager
    VERSIONS_DIR = File.expand_path('../../skills/versions', __dir__)
    DSL_PATH = File.expand_path('../../skills/kairos.rb', __dir__)
    
    def self.create_snapshot(reason: nil)
      FileUtils.mkdir_p(VERSIONS_DIR)
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      filename = "kairos_#{timestamp}.rb"
      version_path = File.join(VERSIONS_DIR, filename)
      
      FileUtils.cp(DSL_PATH, version_path)
      
      # Save metadata
      meta = {
        timestamp: timestamp,
        reason: reason,
        filename: filename,
        created_at: Time.now.iso8601
      }
      meta_path = File.join(VERSIONS_DIR, "#{filename}.meta.json")
      File.write(meta_path, JSON.pretty_generate(meta))
      
      filename
    end
    
    def self.list_versions
      FileUtils.mkdir_p(VERSIONS_DIR)
      
      Dir[File.join(VERSIONS_DIR, '*.rb')].map do |f|
        filename = File.basename(f)
        meta_path = "#{f}.meta.json"
        meta = if File.exist?(meta_path)
                 JSON.parse(File.read(meta_path)) rescue {}
               else
                 {}
               end
        
        {
          filename: filename,
          created: File.mtime(f),
          reason: meta['reason']
        }
      end.sort_by { |v| v[:created] }.reverse
    end
    
    def self.rollback(version_filename)
      version_path = File.join(VERSIONS_DIR, version_filename)
      raise "Version not found: #{version_filename}" unless File.exist?(version_path)
      
      # Backup current state before rollback
      create_snapshot(reason: "pre-rollback backup")
      
      # Perform rollback
      FileUtils.cp(version_path, DSL_PATH)
      
      version_filename
    end
    
    def self.get_version_content(version_filename)
      version_path = File.join(VERSIONS_DIR, version_filename)
      raise "Version not found: #{version_filename}" unless File.exist?(version_path)
      
      File.read(version_path)
    end
    
    def self.diff(version_filename)
      version_path = File.join(VERSIONS_DIR, version_filename)
      raise "Version not found: #{version_filename}" unless File.exist?(version_path)
      
      old_content = File.read(version_path)
      current_content = File.read(DSL_PATH)
      
      # Simple line-by-line diff
      old_lines = old_content.lines
      current_lines = current_content.lines
      
      {
        old_lines: old_lines.size,
        current_lines: current_lines.size,
        added: (current_lines - old_lines).size,
        removed: (old_lines - current_lines).size
      }
    end
  end
end
