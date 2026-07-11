# frozen_string_literal: true

require 'fileutils'

module KairosMcp
  module SkillSets
    module Agent
      module NativeBody
        # ToolLayer — NB-3 load-bearing enforcement of the granted tool
        # surface (native body design v0.6 FROZEN).
        #
        # The substrate confines WHERE a tool that runs may write (the work
        # area); it does not confine WHICH tool the body chooses to run —
        # for a native body that bound is only as strong as this dispatch
        # table. A request outside the granted surface is REFUSED here, and
        # that refusal is a guarded property, not an optimization. The two
        # surfaces are orthogonal and neither substitutes for the other.
        #
        # Every tool effect lands in the work area: paths are resolved
        # against it and a path that escapes it (absolute, dot-dot, or
        # symlink-resolved) is refused in-layer, independently of the
        # substrate's own write-deny.
        class ToolLayer
          class SurfaceRefusal < StandardError; end
          class PathRefusal < StandardError; end

          KNOWN_TOOLS = %w[Read Edit Write Glob Grep].freeze
          MAX_READ_BYTES = 262_144
          MAX_MATCHES = 200

          attr_reader :refused_requests

          def initialize(work_dir:, granted:)
            @work_dir = File.realpath(work_dir)
            @granted = Array(granted).map(&:to_s)
            @refused_requests = []
            unknown = @granted - KNOWN_TOOLS
            # A grant this layer cannot enforce is refused up front, not
            # silently narrowed (fail-closed; shell is not implementable
            # here and so not grantable to the native body in this slice).
            raise SurfaceRefusal, "ungoverned tools in grant: #{unknown.join(', ')}" unless unknown.empty?
          end

          def schemas
            @granted.map { |t| SCHEMAS.fetch(t) }
          end

          # Dispatch a model-proposed tool call. Out-of-surface requests
          # raise SurfaceRefusal (the caller reports the refusal back to the
          # model as an error result; the request is never executed).
          def execute(name, input)
            unless @granted.include?(name.to_s)
              @refused_requests << name.to_s
              raise SurfaceRefusal,
                    "tool #{name.inspect} is outside the granted surface #{@granted.inspect} (NB-3 refusal)"
            end

            input ||= {}
            case name.to_s
            when 'Read'  then tool_read(input)
            when 'Write' then tool_write(input)
            when 'Edit'  then tool_edit(input)
            when 'Glob'  then tool_glob(input)
            when 'Grep'  then tool_grep(input)
            end
          end

          private

          # Resolve a model-supplied path inside the work area or refuse.
          # The deepest existing ancestor is realpath-resolved so a symlink
          # planted inside the work area cannot re-aim a write outside it.
          def contained_path(rel, must_exist: false)
            raise PathRefusal, 'path is empty' if rel.to_s.empty?
            raise PathRefusal, "absolute path refused: #{rel}" if rel.to_s.start_with?('/')

            full = File.expand_path(rel, @work_dir)
            unless full == @work_dir || full.start_with?("#{@work_dir}/")
              raise PathRefusal, "path escapes the work area: #{rel}"
            end

            probe = full
            probe = File.dirname(probe) until File.exist?(probe) || probe == @work_dir
            resolved_probe = File.realpath(probe)
            unless resolved_probe == @work_dir || resolved_probe.start_with?("#{@work_dir}/")
              raise PathRefusal, "path resolves outside the work area (symlink escape): #{rel}"
            end
            raise PathRefusal, "file not found: #{rel}" if must_exist && !File.file?(full)

            full
          end

          def tool_read(input)
            path = contained_path(input['path'], must_exist: true)
            content = File.read(path, MAX_READ_BYTES) || ''
            { 'content' => content, 'truncated' => File.size(path) > MAX_READ_BYTES }
          end

          def tool_write(input)
            path = contained_path(input['path'])
            raise PathRefusal, 'content is required' unless input.key?('content')

            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, input['content'].to_s)
            { 'written' => input['path'], 'bytes' => input['content'].to_s.bytesize }
          end

          def tool_edit(input)
            path = contained_path(input['path'], must_exist: true)
            old = input['old_string'].to_s
            raise PathRefusal, 'old_string is required' if old.empty?

            text = File.read(path)
            raise PathRefusal, "old_string not found in #{input['path']}" unless text.include?(old)

            File.write(path, text.sub(old, input['new_string'].to_s))
            { 'edited' => input['path'] }
          end

          def tool_glob(input)
            pattern = input['pattern'].to_s
            raise PathRefusal, 'pattern is empty' if pattern.empty?
            raise PathRefusal, "pattern escapes the work area: #{pattern}" if pattern.start_with?('/') || pattern.include?('..')

            # R1 F3: the string checks above do not stop a match REACHED
            # through a symlinked intermediate directory (e.g. `link_out/*`
            # where link_out -> /outside) — that enumerated file NAMES outside
            # the work area, weaker than the realpath containment the write
            # tools use. Resolve every match and keep only those whose real
            # path stays under the work area (same test as contained_path).
            matches = Dir.glob(File.join(@work_dir, pattern))
                         .select { |p| File.file?(p) && !File.symlink?(p) }
                         .select { |p| within_work_area?(p) }
                         .map { |p| p.delete_prefix("#{@work_dir}/") }
                         .first(MAX_MATCHES)
            { 'matches' => matches }
          end

          def within_work_area?(path)
            real = File.realpath(path)
            real == @work_dir || real.start_with?("#{@work_dir}/")
          rescue StandardError
            false
          end

          def tool_grep(input)
            pattern = Regexp.new(input['pattern'].to_s)
            scope = input['path'] ? [contained_path(input['path'], must_exist: true)] :
                      Dir.glob(File.join(@work_dir, '**', '*'))
                         .select { |p| File.file?(p) && !File.symlink?(p) && within_work_area?(p) }
            hits = []
            scope.each do |file|
              File.foreach(file).with_index(1) do |line, n|
                next unless line.valid_encoding? && line =~ pattern

                hits << { 'file' => file.delete_prefix("#{@work_dir}/"), 'line' => n, 'text' => line.chomp[0, 500] }
                return { 'matches' => hits } if hits.size >= MAX_MATCHES
              end
            end
            { 'matches' => hits }
          rescue RegexpError => e
            raise PathRefusal, "invalid grep pattern: #{e.message}"
          end

          SCHEMAS = {
            'Read' => { 'name' => 'Read', 'description' => 'Read a file from the work area.',
                        'input_schema' => { 'type' => 'object',
                                            'properties' => { 'path' => { 'type' => 'string', 'description' => 'work-area-relative path' } },
                                            'required' => ['path'] } },
            'Write' => { 'name' => 'Write', 'description' => 'Write a file in the work area (creates parent dirs).',
                         'input_schema' => { 'type' => 'object',
                                             'properties' => { 'path' => { 'type' => 'string' },
                                                               'content' => { 'type' => 'string' } },
                                             'required' => %w[path content] } },
            'Edit' => { 'name' => 'Edit', 'description' => 'Replace the first occurrence of old_string in a work-area file.',
                        'input_schema' => { 'type' => 'object',
                                            'properties' => { 'path' => { 'type' => 'string' },
                                                              'old_string' => { 'type' => 'string' },
                                                              'new_string' => { 'type' => 'string' } },
                                            'required' => %w[path old_string new_string] } },
            'Glob' => { 'name' => 'Glob', 'description' => 'List work-area files matching a glob pattern.',
                        'input_schema' => { 'type' => 'object',
                                            'properties' => { 'pattern' => { 'type' => 'string' } },
                                            'required' => ['pattern'] } },
            'Grep' => { 'name' => 'Grep', 'description' => 'Search work-area files for a regex pattern.',
                        'input_schema' => { 'type' => 'object',
                                            'properties' => { 'pattern' => { 'type' => 'string' },
                                                              'path' => { 'type' => 'string' } },
                                            'required' => ['pattern'] } }
          }.freeze
        end
      end
    end
  end
end
