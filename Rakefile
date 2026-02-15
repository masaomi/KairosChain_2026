# frozen_string_literal: true

# Project-root Rakefile for KairosChain
# For MCP server tasks, see KairosChain_mcp_server/Rakefile

desc "Generate README.md and README_jp.md from L1 knowledge"
task :build_readme do
  ruby "scripts/build_readme.rb"
end

desc "Check if README files are up to date with L1 knowledge"
task :check_readme do
  ruby "scripts/build_readme.rb --check"
end

desc "Preview README generation without writing files"
task :preview_readme do
  ruby "scripts/build_readme.rb --dry-run"
end
