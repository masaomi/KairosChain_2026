# frozen_string_literal: true

module Kairomone
  # All runtime paths are derived from the selected host data directory. Tool
  # arguments never select an arbitrary filesystem path. Private directories
  # and per-instance flock serialize this SkillSet's writers; unrelated writers
  # that ignore its lock are outside this single-owner v0 contract.
  module Paths
    ID = /\A[a-z][a-z0-9_-]{0,63}\z/
    BACKUP_NAME = /\A[a-zA-Z0-9_-]{1,100}\.kairomone\.json\z/
    module_function

    def id!(value)
      raise Error, 'ID must start with a lowercase letter and contain 1–64 lowercase letters, digits, underscores or hyphens' unless value.is_a?(String) && ID.match?(value)
      value
    end

    def checked(root, relative)
      parts = relative.split('/')
      raise Error, 'Unsafe relative path' if parts.empty? || parts.any? { |p| p.empty? || p == '.' || p == '..' || p.include?("\\") || p.include?("\0") }
      current = root
      cursor = root
      loop do
        raise Error, "Symlink not allowed: #{cursor}" if File.symlink?(cursor)
        parent = File.dirname(cursor)
        break if parent == cursor
        cursor = parent
      end
      parts.each do |part|
        current = File.join(current, part)
        raise Error, "Symlink not allowed: #{current}" if File.symlink?(current)
      end
      current
    end

    def regular_file!(path, optional: false, limit: nil)
      return if optional && !File.exist?(path) && !File.symlink?(path)
      st = File.lstat(path)
      raise Error, 'Expected a regular, singly linked file' unless st.file? && st.nlink == 1
      raise Error, "File exceeds #{limit} bytes" if limit && st.size > limit
      st
    end

    def read(root, relative, limit: 1_048_576)
      path = checked(root, relative)
      regular_file!(path, limit: limit)
      File.open(path, 'rb') do |io|
        data = io.read(limit + 1)
        raise Error, 'File grew beyond its size limit' if data.bytesize > limit
        data
      end
    end

    def mkdir(root, relative)
      path = checked(root, relative)
      FileUtils.mkdir_p(path, mode: 0o700)
      path
    end

    def write(root, relative, content, replace: false)
      path = checked(root, relative)
      mkdir(root, File.dirname(relative)) unless File.dirname(relative) == '.'
      raise Error, "Refusing to replace #{relative}" if !replace && File.exist?(path)
      temp = "#{path}.tmp-#{SecureRandom.hex(8)}"
      begin
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(content); f.flush; f.fsync }
        # Writers under the instance lock cannot race this existence check.
        raise Error, "Refusing to replace #{relative}" if !replace && File.exist?(path)
        File.rename(temp, path)
      ensure
        File.unlink(temp) if File.exist?(temp)
      end
      path
    end
  end
end
