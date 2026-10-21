# frozen_string_literal: true

require 'shellwords'

module Kairomone
  module Console
    # The project folder the console serves, read once at start. Everything the
    # child is given comes from here: the single MCP server, the data
    # directory that server writes, and the restrictive permission rules the
    # owner saved for this folder. Nothing in this class writes to the dot.
    class Project
      SERVER_NAME = /\A[A-Za-z0-9_-]{1,64}\z/
      CONFIG_LIMIT = 1_048_576
      LOCK_NAME = 'kairomone_console.lock'
      LOG_NAME = 'kairomone_console.log'
      # Where Claude Code reads organization-managed settings (macOS, Linux).
      MANAGED_POLICY_DIRS = ['/Library/Application Support/ClaudeCode', '/etc/claude-code'].freeze
      # Characters Dir[] reads as a pattern rather than as part of a path.
      GLOB_CHARACTERS = /[*?\[\]{}\\]/

      # Held for the console's lifetime; the kernel drops it if the console dies.
      class Lock
        def initialize(io)
          @io = io
        end

        def release
          return false if @io.closed?
          @io.flock(File::LOCK_UN)
          @io.close
          true
        end
      end

      attr_reader :dir, :server_name, :data_dir, :package_root, :skill_md_path, :run_dir

      def self.load(dir, env: ENV, home: Dir.home)
        new(dir, env: env, home: home)
      end

      def initialize(dir, env:, home:)
        raise Refusal, 'No project folder was given' unless dir.is_a?(String) && !dir.empty?
        @dir = File.expand_path(dir)
        raise Refusal, "Project folder does not exist: #{@dir}" unless File.directory?(@dir)
        @home = File.expand_path(home)
        servers = read_json(File.join(@dir, '.mcp.json'), missing: :refuse)
        servers = servers['mcpServers'] if servers.is_a?(Hash)
        raise Refusal, '.mcp.json must name exactly one server under "mcpServers"' unless servers.is_a?(Hash) && servers.length == 1
        @server_name, server = servers.first
        # The name becomes part of every tool name the gate admits and is
        # written into the gate's program, so only plain names are accepted.
        raise Refusal, 'The .mcp.json server name must be 1-64 letters, digits, "_" or "-"' unless SERVER_NAME.match?(@server_name)
        raise Refusal, "The #{@server_name} server in .mcp.json is not an object" unless server.is_a?(Hash)
        raise Refusal, "The #{@server_name} server in .mcp.json must be a local (stdio) server" unless server['type'].nil? || server['type'] == 'stdio'
        @data_dir = data_dir_from(server, env)
        package = File.expand_path(Kairomone::PACKAGE_ROOT)
        raise Refusal, 'The data directory must be outside the installed SkillSet package' if @data_dir == package || @data_dir.start_with?(package + '/')
        @package_root = Kairomone::PACKAGE_ROOT
        @skill_md_path = File.join(@package_root, 'plugin', 'SKILL.md')
        raise Refusal, "The standing rules are missing: #{@skill_md_path}" unless File.file?(@skill_md_path)
        @run_dir = File.join(@data_dir, 'run')
        @user_settings = user_settings_path(env)
      end

      # => {"deny" => [...], "ask" => [...]}. Rules that grant are never read,
      # so the child keeps every protection saved for this folder and none of
      # the permissions. A file that cannot be read whole refuses the start:
      # dropping part of a deny list would be a silent loss of protection.
      def restrictive_rules
        result = { 'deny' => [], 'ask' => [] }
        settings_files.each do |path|
          data = read_json(path, missing: :skip)
          next if data.nil?
          raise Refusal, "#{path} is not a JSON object" unless data.is_a?(Hash)
          permissions = data['permissions']
          next if permissions.nil?
          raise Refusal, "#{path}: \"permissions\" is not an object" unless permissions.is_a?(Hash)
          result.each_key do |key|
            list = permissions[key]
            next if list.nil?
            raise Refusal, "#{path}: \"permissions.#{key}\" is not a list of rule strings" unless list.is_a?(Array) && list.all?(String)
            list.each { |rule| result[key] << rule unless result[key].include?(rule) }
          end
        end
        result
      end

      # The installed package must be exactly what was recorded on the host
      # chain when it was installed. This covers the console's own program, the
      # gate's source and the standing rules; it does not cover an edit that
      # also rewrites this check, which runs with the same rights.
      def start_check!
        # The core lists the package's files with Dir[], which reads these
        # characters in the package's own path as a pattern: the list then
        # misses files or is empty, the hash recorded at install and the one
        # computed here agree whatever the files hold, and the check would
        # pass for any content.
        if GLOB_CHARACTERS.match?(File.expand_path(@package_root))
          raise Refusal, "The Kairomone package path #{@package_root} contains one of * ? [ ] { } \\, which KairosChain's " \
                         'file listing reads as a pattern, so its content cannot be checked; move the project to a folder whose path has none of them'
        end
        installed = begin
          skillset = KairosMcp::Skillset.new(@package_root)
          raise Refusal, "KairosChain lists no files in the Kairomone package at #{@package_root}, so its content cannot be checked" if skillset.file_list.empty?
          skillset.content_hash
        rescue ArgumentError, SystemCallError, IOError => e
          raise Refusal, "Cannot read the Kairomone package at #{@package_root}: #{e.message}"
        end
        chain = host_chain
        raise Refusal, "The host chain is #{chain.load_state}, so the installed package cannot be checked. #{reinstall_hint}" unless %i[readable absent].include?(chain.load_state)
        event = latest_event(chain)
        raise Refusal, "No Kairomone install is recorded on the host chain. #{reinstall_hint}" unless event
        if %w[remove disable].include?(event['action'])
          raise Refusal, "The host chain's latest Kairomone record is \"#{event['action']}\"; install or enable it first. #{reinstall_hint}"
        end
        unless event['content_hash'].is_a?(String) && event['content_hash'] == installed
          raise Refusal, "The Kairomone package at #{@package_root} differs from the content recorded when it was installed. #{reinstall_hint}"
        end
        true
      end

      def lock!
        ensure_run_dir!
        path = File.join(@run_dir, LOCK_NAME)
        raise Refusal, "#{path} is a symlink; remove it" if File.symlink?(path)
        io = File.open(path, File::RDWR | File::CREAT, 0o600)
        unless io.flock(File::LOCK_EX | File::LOCK_NB)
          io.close
          raise Refusal, 'Another Kairomone console is running for this folder; stop it first'
        end
        Lock.new(io)
      rescue SystemCallError => e
        raise Refusal, "Cannot take the console lock in #{@run_dir}: #{e.class}"
      end

      def log_path
        File.join(@run_dir, LOG_NAME)
      end

      # Organization-managed settings bind the child whatever the console
      # passes (--setting-sources does not govern them), so the console can only
      # name them on the page. => paths present, [] when there are none.
      def managed_policy_paths(dirs: MANAGED_POLICY_DIRS)
        dirs.flat_map do |dir|
          next [] unless File.directory?(dir)
          Dir.children(dir).reject { |name| name.start_with?('.') }.sort.map { |name| File.join(dir, name) }
        rescue SystemCallError
          [dir] # present but unreadable: name the directory
        end
      end

      private

      def data_dir_from(server, env)
        args = server['args']
        raise Refusal, "The #{@server_name} server in .mcp.json has no \"args\" list of strings" unless args.is_a?(Array) && args.all?(String)
        raise Refusal, 'Write "--data-dir" and its path as two separate args in .mcp.json' if args.any? { |a| a.start_with?('--data-dir=') }
        # kairos-chain reads its arguments with OptionParser, which also takes
        # abbreviations (--data, --da), other letter case, "=" forms, a later
        # repeat and "--"; each can make the server use another directory than
        # the one the console reads and checks. The one shape whose meaning is
        # certain is the one kairos-chain init writes.
        unless args.length == 2 && args[0] == '--data-dir'
          raise Refusal, "The #{@server_name} server's args in .mcp.json must be exactly [\"--data-dir\", \"<absolute path>\"], " \
                         'as kairos-chain init writes them; other arguments can change the directory the server uses'
        end
        raw = args[1]
        raise Refusal, "The --data-dir in .mcp.json must be an absolute path: #{raw}" unless File.absolute_path?(raw)
        raise Refusal, "The --data-dir in .mcp.json is not an existing directory: #{raw}" unless File.directory?(raw)
        data_dir = File.expand_path(raw)
        server_env = server['env']
        raise Refusal, "The #{@server_name} server's \"env\" in .mcp.json is not an object" unless server_env.nil? || server_env.is_a?(Hash)
        raise Refusal, "Remove KAIROS_DATA_DIR from the #{@server_name} server's \"env\" in .mcp.json; --data-dir names the data directory" if server_env&.key?('KAIROS_DATA_DIR')
        selected = env['KAIROS_DATA_DIR']
        # An empty value is still a selection: the core expands it to the
        # current directory, so it is compared like any other.
        if !selected.nil? && File.expand_path(selected) != data_dir
          raise Refusal, "KAIROS_DATA_DIR in this shell names a different directory than .mcp.json's --data-dir (#{data_dir}); unset it or make them equal"
        end
        data_dir
      end

      def settings_files
        [@user_settings,
         File.join(@dir, '.claude', 'settings.json'),
         File.join(@dir, '.claude', 'settings.local.json')]
      end

      # Claude Code keeps the user settings in $CLAUDE_CONFIG_DIR when it is
      # set and in ~/.claude otherwise, and the child inherits this
      # environment. A value the console cannot resolve the same way (empty or
      # relative) stops the start rather than dropping that file's rules.
      def user_settings_path(env)
        config = env['CLAUDE_CONFIG_DIR']
        return File.join(@home, '.claude', 'settings.json') if config.nil?
        unless File.absolute_path?(config)
          raise Refusal, 'CLAUDE_CONFIG_DIR in this shell must be an absolute path, so that the console carries the deny and ask ' \
                         'rules of the user settings Claude Code reads; unset it or make it absolute'
        end
        File.join(File.expand_path(config), 'settings.json')
      end

      def read_json(path, missing:)
        begin
          st = File.stat(path)
        rescue Errno::ENOENT, Errno::ENOTDIR
          return nil if missing == :skip
          raise Refusal, "No #{File.basename(path)} in #{File.dirname(path)}"
        rescue SystemCallError => e
          raise Refusal, "Cannot read #{path}: #{e.class}"
        end
        raise Refusal, "#{path} is not a regular file" unless st.file?
        raise Refusal, "#{path} exceeds #{CONFIG_LIMIT} bytes" if st.size > CONFIG_LIMIT
        text = File.read(path, mode: 'rb').force_encoding(Encoding::UTF_8)
        raise Refusal, "#{path} is not valid UTF-8" unless text.valid_encoding?
        JSON.parse(text)
      rescue JSON::ParserError
        raise Refusal, "Cannot parse #{path} as JSON; fix it before starting the console"
      rescue SystemCallError, IOError => e
        raise Refusal, "Cannot read #{path}: #{e.class}"
      end

      # The core resolves where the host chain lives (storage settings in the
      # data directory's skills/config.yml), so read it through the core with
      # the data directory selected, then put the previous selection back.
      def host_chain
        previous = KairosMcp.data_dir
        begin
          KairosMcp.data_dir = @data_dir
          KairosMcp::KairosChain::Chain.new
        ensure
          KairosMcp.data_dir = previous
        end
      end

      def latest_event(chain)
        chain.chain.flat_map { |block| Array(block.data) }.filter_map do |data|
          event = begin
            JSON.parse(data) if data.is_a?(String)
          rescue JSON::ParserError
            nil
          end
          event if event.is_a?(Hash) && event['type'] == 'skillset_event' && event['skillset_name'] == 'kairomone'
        end.last
      end

      def reinstall_hint
        "Reinstall it at a terminal: kairos-chain skillset install kairomone --force --data-dir #{Shellwords.escape(@data_dir)}"
      end

      def ensure_run_dir!
        raise Refusal, "#{@run_dir} is a symlink; remove it" if File.symlink?(@run_dir)
        if File.exist?(@run_dir)
          raise Refusal, "#{@run_dir} is not a directory" unless File.directory?(@run_dir)
        else
          Dir.mkdir(@run_dir, 0o700)
          File.chmod(0o700, @run_dir)
        end
      end
    end
  end
end
