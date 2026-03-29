# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'yaml'
require 'zlib'
require 'time'

module KairosMcp
  module SkillSets
    module Dream
      class Archiver
        LOCK_FILE = '.dream_lock'

        def initialize(config: {})
          archive_config = config.fetch('archive', {})
          @archive_dir_name = archive_config.fetch('archive_dir', 'dream/archive')
          @preserve_gzip = archive_config.fetch('preserve_gzip', true)
        end

        # Soft-archive a single L2 context.
        # Moves full directory contents to archive, leaves stub-only dir.
        #
        # @param session_id [String] Session ID
        # @param context_name [String] Context name
        # @param summary [String] Caller-provided summary for the stub
        # @return [Hash] Result with content_hash, sizes, moved_subdirs
        def archive_context!(session_id:, context_name:, summary:)
          src_dir  = context_dir_path(session_id, context_name)
          arch_dir = archive_dir_path(session_id, context_name)
          md_file  = File.join(src_dir, "#{context_name}.md")

          with_lock(src_dir) do
            # 1. Validate source exists and is not already archived
            raise "Context not found: #{md_file}" unless File.exist?(md_file)
            raise "Already archived: #{context_name}" if archived?(session_id: session_id, context_name: context_name)

            # 2. Read and compress the markdown
            original_content = File.read(md_file)
            original_size = original_content.bytesize
            content_hash = Digest::SHA256.hexdigest(original_content)

            FileUtils.mkdir_p(arch_dir)
            gz_path = File.join(arch_dir, "#{context_name}.md.gz")
            Zlib::GzipWriter.open(gz_path) { |gz| gz.write(original_content) }

            # 3. Verify gzip integrity immediately after write
            verify_hash = Digest::SHA256.hexdigest(Zlib::GzipReader.open(gz_path, &:read))
            unless verify_hash == content_hash
              FileUtils.rm_f(gz_path)
              raise "Gzip verification failed — archive aborted, original intact"
            end

            # 4. Move ALL subdirs/files (except .md and .dream_lock) to archive
            moved_subdirs = []
            Dir.children(src_dir).each do |child|
              next if child == "#{context_name}.md"
              next if child == LOCK_FILE

              child_src = File.join(src_dir, child)
              FileUtils.mv(child_src, File.join(arch_dir, child))
              moved_subdirs << child if File.directory?(File.join(arch_dir, child))
            end

            # 5. Extract original frontmatter for stub metadata
            original_meta = extract_frontmatter(original_content)

            # 6. Detect what was moved for stub flags
            has_scripts    = moved_subdirs.include?('scripts')
            has_assets     = moved_subdirs.include?('assets')
            has_references = moved_subdirs.include?('references')

            # 7. Write stub atomically (tempfile + rename)
            stub_content = generate_stub(
              context_name: context_name,
              summary: summary,
              content_hash: content_hash,
              original_size: original_size,
              original_meta: original_meta,
              archive_ref: archive_ref_path(session_id, context_name),
              has_scripts: has_scripts,
              has_assets: has_assets,
              has_references: has_references
            )
            tmp_path = "#{md_file}.tmp"
            File.write(tmp_path, stub_content)
            File.rename(tmp_path, md_file) # POSIX atomic

            {
              success: true,
              context_name: context_name,
              session_id: session_id,
              content_hash: content_hash,
              original_size: original_size,
              stub_size: stub_content.bytesize,
              moved_subdirs: moved_subdirs,
              verified: true
            }
          end
        end

        # Restore a soft-archived context.
        #
        # @param session_id [String] Session ID
        # @param context_name [String] Context name
        # @return [Hash] Result with restored_hash, verified
        def recall_context!(session_id:, context_name:)
          src_dir  = context_dir_path(session_id, context_name)
          arch_dir = archive_dir_path(session_id, context_name)
          md_file  = File.join(src_dir, "#{context_name}.md")
          gz_path  = File.join(arch_dir, "#{context_name}.md.gz")

          with_lock(src_dir) do
            # 1. Verify archive exists and integrity
            raise "Archive not found: #{gz_path}" unless File.exist?(gz_path)
            raise "Stub not found: #{md_file}" unless File.exist?(md_file)

            stub_meta = parse_stub(md_file)
            restored_content = Zlib::GzipReader.open(gz_path, &:read)
            restored_hash = Digest::SHA256.hexdigest(restored_content)

            unless restored_hash == stub_meta[:content_hash]
              raise "Archive integrity check failed. Expected #{stub_meta[:content_hash]}, " \
                    "got #{restored_hash}. Archive may be corrupted."
            end

            # 2. Restore markdown atomically
            tmp_path = "#{md_file}.tmp"
            File.write(tmp_path, restored_content)
            File.rename(tmp_path, md_file) # POSIX atomic

            # 3. Move subdirectories and files back from archive
            moved_back = []
            Dir.children(arch_dir).each do |child|
              next if child == "#{context_name}.md.gz"

              child_arch = File.join(arch_dir, child)
              FileUtils.mv(child_arch, File.join(src_dir, child))
              moved_back << child
            end

            # 4. Clean up archive (configurable)
            if @preserve_gzip
              # Keep gzip for safety — no cleanup
            else
              FileUtils.rm_rf(arch_dir)
            end

            {
              success: true,
              context_name: context_name,
              session_id: session_id,
              restored_hash: restored_hash,
              restored_size: restored_content.bytesize,
              moved_back: moved_back,
              verified: true,
              archive_preserved: @preserve_gzip
            }
          end
        end

        # Preview archived content without restoring.
        #
        # @param session_id [String] Session ID
        # @param context_name [String] Context name
        # @return [Hash] Preview result with content and metadata
        def preview(session_id:, context_name:)
          arch_dir = archive_dir_path(session_id, context_name)
          gz_path  = File.join(arch_dir, "#{context_name}.md.gz")
          md_file  = File.join(context_dir_path(session_id, context_name), "#{context_name}.md")

          raise "Archive not found: #{gz_path}" unless File.exist?(gz_path)

          content = Zlib::GzipReader.open(gz_path, &:read)
          stub_meta = File.exist?(md_file) ? parse_stub(md_file) : {}

          {
            success: true,
            context_name: context_name,
            session_id: session_id,
            content: content,
            content_size: content.bytesize,
            content_hash: Digest::SHA256.hexdigest(content),
            stub_meta: stub_meta
          }
        end

        # Check if a context is soft-archived.
        #
        # @param session_id [String] Session ID
        # @param context_name [String] Context name
        # @return [Boolean]
        def archived?(session_id:, context_name:)
          md_file = File.join(context_dir_path(session_id, context_name), "#{context_name}.md")
          return false unless File.exist?(md_file)

          content = File.read(md_file)
          status = extract_status(content)
          status == 'soft-archived'
        end

        # Verify archive integrity without modifying anything.
        #
        # @param session_id [String] Session ID
        # @param context_name [String] Context name
        # @return [Hash] Verification result
        def verify(session_id:, context_name:)
          arch_dir = archive_dir_path(session_id, context_name)
          md_file  = File.join(context_dir_path(session_id, context_name), "#{context_name}.md")
          gz_path  = File.join(arch_dir, "#{context_name}.md.gz")

          issues = []

          # Check stub exists and is archived
          unless File.exist?(md_file)
            issues << "Stub file not found: #{md_file}"
          end

          stub_meta = {}
          if issues.empty?
            content = File.read(md_file)
            status = extract_status(content)
            unless status == 'soft-archived'
              issues << "Context is not archived (status: #{status || 'nil'})"
            end
            stub_meta = parse_stub(md_file)
          end

          # Check gzip exists
          unless File.exist?(gz_path)
            issues << "Gzip archive not found: #{gz_path}"
          end

          # Verify SHA256 if both stub and gzip exist
          if issues.empty? && stub_meta[:content_hash]
            actual_hash = Digest::SHA256.hexdigest(Zlib::GzipReader.open(gz_path, &:read))
            unless actual_hash == stub_meta[:content_hash]
              issues << "SHA256 mismatch. Stub: #{stub_meta[:content_hash]}, Actual: #{actual_hash}"
            end
          end

          # Check archived subdirs exist
          if stub_meta[:archive_ref] && File.directory?(arch_dir)
            archived_children = Dir.children(arch_dir).reject { |c| c.end_with?('.md.gz') }
            has_expected = []
            has_expected << 'scripts' if stub_meta[:has_scripts]
            has_expected << 'assets' if stub_meta[:has_assets]
            has_expected << 'references' if stub_meta[:has_references]

            has_expected.each do |subdir|
              unless archived_children.include?(subdir)
                issues << "Expected archived subdir '#{subdir}' not found in archive"
              end
            end
          end

          {
            success: issues.empty?,
            context_name: context_name,
            session_id: session_id,
            issues: issues,
            stub_meta: stub_meta,
            gzip_exists: File.exist?(gz_path),
            archive_dir_exists: File.directory?(arch_dir)
          }
        end

        private

        # ---------------------------------------------------------------
        # Path helpers
        # ---------------------------------------------------------------

        def context_dir_path(session_id, context_name)
          dir = context_dir
          File.join(dir, session_id, context_name)
        end

        def archive_dir_path(session_id, context_name)
          base = storage_dir
          File.join(base, @archive_dir_name, session_id, context_name)
        end

        def archive_ref_path(session_id, context_name)
          File.join(@archive_dir_name, session_id, context_name)
        end

        def context_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:context_dir)
            KairosMcp.context_dir
          else
            File.join(Dir.pwd, '.kairos', 'context')
          end
        end

        def storage_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:storage_dir)
            KairosMcp.storage_dir
          elsif defined?(KairosMcp) && KairosMcp.respond_to?(:kairos_dir)
            KairosMcp.kairos_dir
          else
            File.join(Dir.pwd, '.kairos')
          end
        end

        # ---------------------------------------------------------------
        # Lock
        # ---------------------------------------------------------------

        def with_lock(dir)
          FileUtils.mkdir_p(dir)
          lock_path = File.join(dir, LOCK_FILE)
          File.open(lock_path, File::CREAT | File::RDWR) do |f|
            unless f.flock(File::LOCK_EX | File::LOCK_NB)
              raise "Context is locked by another operation. Try again later."
            end
            begin
              yield
            ensure
              f.flock(File::LOCK_UN)
            end
          end
        ensure
          FileUtils.rm_f(File.join(dir, LOCK_FILE)) if File.exist?(File.join(dir, LOCK_FILE))
        end

        # ---------------------------------------------------------------
        # Stub generation and parsing
        # ---------------------------------------------------------------

        def generate_stub(context_name:, summary:, content_hash:, original_size:,
                          original_meta:, archive_ref:, has_scripts:, has_assets:, has_references:)
          title = original_meta['title'] || context_name
          tags = Array(original_meta['tags'])
          description = original_meta['description'] || ''

          frontmatter = {
            'title' => title,
            'tags' => tags,
            'description' => description,
            'status' => 'soft-archived',
            'archived_at' => Time.now.utc.iso8601,
            'archived_by' => 'dream_archive',
            'archive_ref' => archive_ref,
            'content_hash' => content_hash,
            'original_size' => original_size,
            'has_scripts' => has_scripts,
            'has_assets' => has_assets,
            'has_references' => has_references,
            'summary' => summary
          }

          includes = []
          includes << 'scripts/' if has_scripts
          includes << 'assets/' if has_assets
          includes << 'references/' if has_references

          body_lines = []
          body_lines << "# #{context_name} [ARCHIVED]"
          body_lines << ""
          body_lines << "This context has been soft-archived. Use `dream_recall` to restore full text."
          body_lines << ""
          body_lines << "**Tags**: #{tags.join(', ')}" unless tags.empty?
          body_lines << "**Original size**: #{format_bytes(original_size)}"
          body_lines << "**Includes**: #{includes.join(', ')}" unless includes.empty?

          "---\n#{YAML.dump(frontmatter).sub(/\A---\n/, '')}---\n\n#{body_lines.join("\n")}\n"
        end

        def parse_stub(md_file)
          content = File.read(md_file)
          meta = extract_frontmatter(content)
          {
            content_hash: meta['content_hash'],
            original_size: meta['original_size'],
            archive_ref: meta['archive_ref'],
            archived_at: meta['archived_at'],
            has_scripts: meta['has_scripts'] == true,
            has_assets: meta['has_assets'] == true,
            has_references: meta['has_references'] == true,
            summary: meta['summary'],
            status: meta['status']
          }
        end

        # ---------------------------------------------------------------
        # Frontmatter helpers
        # ---------------------------------------------------------------

        def extract_frontmatter(content)
          if content =~ /\A---\n(.*?)\n---/m
            YAML.safe_load($1, permitted_classes: [Symbol]) || {}
          else
            {}
          end
        rescue StandardError
          {}
        end

        def extract_status(content)
          meta = extract_frontmatter(content)
          meta['status'] || meta[:status]
        end

        def format_bytes(bytes)
          if bytes >= 1_048_576
            "#{(bytes / 1_048_576.0).round(1)} MB"
          elsif bytes >= 1024
            "#{(bytes / 1024.0).round(1)} KB"
          else
            "#{bytes} bytes"
          end
        end
      end
    end
  end
end
