require 'fileutils'
require 'json'
require 'time'
require_relative '../kairos_mcp'

module KairosMcp
  class VersionManager
    def self.versions_dir
      KairosMcp.versions_dir
    end

    def self.dsl_path
      KairosMcp.dsl_path
    end

    def self.create_snapshot(reason: nil)
      FileUtils.mkdir_p(versions_dir)
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      filename = "kairos_#{timestamp}.rb"
      version_path = File.join(versions_dir, filename)
      
      FileUtils.cp(dsl_path, version_path)
      
      # Save metadata
      meta = {
        timestamp: timestamp,
        reason: reason,
        filename: filename,
        created_at: Time.now.iso8601
      }
      meta_path = File.join(versions_dir, "#{filename}.meta.json")
      File.write(meta_path, JSON.pretty_generate(meta))
      
      filename
    end
    
    def self.list_versions
      FileUtils.mkdir_p(versions_dir)
      
      Dir[File.join(versions_dir, '*.rb')].map do |f|
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
      version_path = File.join(versions_dir, version_filename)
      raise "Version not found: #{version_filename}" unless File.exist?(version_path)
      
      # Backup current state before rollback
      create_snapshot(reason: "pre-rollback backup")
      
      # Perform rollback
      FileUtils.cp(version_path, dsl_path)
      
      version_filename
    end
    
    def self.get_version_content(version_filename)
      version_path = File.join(versions_dir, version_filename)
      raise "Version not found: #{version_filename}" unless File.exist?(version_path)
      
      File.read(version_path)
    end
    
    def self.diff(version_filename)
      version_path = File.join(versions_dir, version_filename)
      raise "Version not found: #{version_filename}" unless File.exist?(version_path)
      
      old_content = File.read(version_path)
      current_content = File.read(dsl_path)
      
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
