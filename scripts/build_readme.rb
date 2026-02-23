#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

# build_readme.rb - Generate README.md and README_jp.md from L1 knowledge files
#
# This script reads L1 knowledge files with readme_order and readme_lang
# frontmatter fields, combines them with header/footer templates, and
# generates README files at the project root.
#
# Usage:
#   ruby scripts/build_readme.rb
#   ruby scripts/build_readme.rb --dry-run   # Preview without writing
#   ruby scripts/build_readme.rb --check      # Check if READMEs are up to date

require "yaml"
require "date"

class ReadmeBuilder
  PROJECT_ROOT = File.expand_path("..", __dir__)
  KNOWLEDGE_DIR = File.join(PROJECT_ROOT, "KairosChain_mcp_server", "knowledge")
  TEMPLATE_DIR = File.join(PROJECT_ROOT, "scripts", "readme_templates")
  VERSION_FILE = File.join(PROJECT_ROOT, "KairosChain_mcp_server", "lib", "kairos_mcp", "version.rb")

  LANG_CONFIG = {
    "en" => {
      header: File.join(TEMPLATE_DIR, "header_en.md"),
      footer: File.join(TEMPLATE_DIR, "footer_en.md"),
      output: File.join(PROJECT_ROOT, "README.md")
    },
    "jp" => {
      header: File.join(TEMPLATE_DIR, "header_jp.md"),
      footer: File.join(TEMPLATE_DIR, "footer_jp.md"),
      output: File.join(PROJECT_ROOT, "README_jp.md")
    }
  }.freeze

  def initialize(dry_run: false, check: false)
    @dry_run = dry_run
    @check = check
  end

  def run
    knowledge_files = scan_knowledge_files
    version = read_version
    date = Date.today.strftime("%Y-%m-%d")

    results = {}

    LANG_CONFIG.each do |lang, config|
      files = knowledge_files
        .select { |f| f[:lang] == lang }
        .sort_by { |f| f[:order] }

      if files.empty?
        warn "[WARN] No L1 knowledge files found for lang=#{lang}, skipping."
        next
      end

      content = build_readme(files, config, version, date)
      results[lang] = { content: content, output: config[:output], files: files }
    end

    if @check
      check_mode(results)
    elsif @dry_run
      dry_run_mode(results)
    else
      write_mode(results)
    end
  end

  private

  # Scan knowledge/ for files with readme_order and readme_lang frontmatter
  def scan_knowledge_files
    files = []

    Dir.glob(File.join(KNOWLEDGE_DIR, "*", "*.md")).each do |path|
      content = File.read(path, encoding: 'UTF-8')
      frontmatter = parse_frontmatter(content)
      next unless frontmatter && frontmatter["readme_order"] && frontmatter["readme_lang"]

      body = strip_frontmatter(content)

      files << {
        path: path,
        name: frontmatter["name"],
        order: frontmatter["readme_order"].to_i,
        lang: frontmatter["readme_lang"],
        body: body
      }
    end

    files
  end

  # Parse YAML frontmatter from markdown file
  def parse_frontmatter(content)
    return nil unless content.start_with?("---")

    parts = content.split("---", 3)
    return nil if parts.length < 3

    YAML.safe_load(parts[1])
  rescue Psych::SyntaxError => e
    warn "[WARN] YAML parse error: #{e.message}"
    nil
  end

  # Remove YAML frontmatter, returning only the markdown body
  def strip_frontmatter(content)
    return content unless content.start_with?("---")

    parts = content.split("---", 3)
    return content if parts.length < 3

    # Strip leading blank lines from body
    parts[2].sub(/\A\n+/, "")
  end

  # Build a single README from template + knowledge files
  def build_readme(files, config, version, date)
    header = File.read(config[:header], encoding: 'UTF-8')
    footer = File.read(config[:footer], encoding: 'UTF-8')

    # Combine all L1 knowledge bodies
    body_parts = files.map { |f| f[:body].rstrip }
    body = body_parts.join("\n\n---\n\n")

    # Generate table of contents from ## headings
    toc = generate_toc(body)

    # Assemble final content
    output = header.gsub("{{TABLE_OF_CONTENTS}}", toc)
    output += body
    output += "\n"
    output += footer
      .gsub("{{VERSION}}", version)
      .gsub("{{DATE}}", date)

    # Ensure file ends with newline
    output.rstrip + "\n"
  end

  # Generate markdown table of contents from ## and ### headings
  # Correctly skips headings inside code blocks (``` ... ```)
  def generate_toc(body)
    lines = body.lines
    toc_entries = []
    in_code_block = false

    lines.each do |line|
      # Track code block boundaries
      if line.strip.start_with?("```")
        in_code_block = !in_code_block
      end

      next if in_code_block

      if line.match?(/\A## /)
        title = line.sub(/\A## /, "").strip
        anchor = title_to_anchor(title)
        toc_entries << "- [#{title}](##{anchor})"
      elsif line.match?(/\A### /)
        title = line.sub(/\A### /, "").strip
        anchor = title_to_anchor(title)
        toc_entries << "  - [#{title}](##{anchor})"
      end
    end

    toc_entries.join("\n")
  end

  # Convert a heading title to a GitHub-compatible anchor
  def title_to_anchor(title)
    title
      .downcase
      .gsub(/[^\w\s\u3000-\u9fff\uff00-\uffef-]/, "") # Keep alphanumeric, CJK, hyphens, spaces
      .gsub(/\s+/, "-")                                  # Spaces to hyphens
      .gsub(/-+/, "-")                                   # Collapse multiple hyphens
      .gsub(/\A-|-\z/, "")                               # Strip leading/trailing hyphens
  end

  # Read version from version.rb
  def read_version
    content = File.read(VERSION_FILE)
    match = content.match(/VERSION\s*=\s*"([^"]+)"/)
    match ? match[1] : "unknown"
  rescue Errno::ENOENT
    "unknown"
  end

  # --check mode: verify READMEs are up to date
  def check_mode(results)
    all_ok = true

    results.each do |lang, data|
      if File.exist?(data[:output])
        current = File.read(data[:output])
        if current == data[:content]
          puts "[OK] #{File.basename(data[:output])} is up to date"
        else
          puts "[OUTDATED] #{File.basename(data[:output])} needs regeneration"
          all_ok = false
        end
      else
        puts "[MISSING] #{File.basename(data[:output])} does not exist"
        all_ok = false
      end
    end

    exit(all_ok ? 0 : 1)
  end

  # --dry-run mode: show what would be generated
  def dry_run_mode(results)
    results.each do |lang, data|
      puts "=" * 60
      puts "Would generate: #{File.basename(data[:output])}"
      puts "From #{data[:files].length} L1 knowledge files:"
      data[:files].each do |f|
        puts "  [#{f[:order]}] #{f[:name]} (#{File.basename(f[:path])})"
      end
      puts "Output size: #{data[:content].length} bytes, #{data[:content].lines.count} lines"
      puts "=" * 60
      puts
    end
  end

  # Normal mode: write README files
  def write_mode(results)
    results.each do |lang, data|
      File.write(data[:output], data[:content])

      puts "Generated: #{File.basename(data[:output])}"
      puts "  From #{data[:files].length} L1 knowledge files:"
      data[:files].each do |f|
        puts "    [#{f[:order]}] #{f[:name]}"
      end
      puts "  Size: #{data[:content].length} bytes, #{data[:content].lines.count} lines"
      puts
    end

    puts "Done. README files generated from L1 knowledge."
    puts "Remember to commit the generated files."
  end
end

# CLI entry point
if __FILE__ == $PROGRAM_NAME
  dry_run = ARGV.include?("--dry-run")
  check = ARGV.include?("--check")

  if ARGV.include?("--help") || ARGV.include?("-h")
    puts "Usage: ruby scripts/build_readme.rb [options]"
    puts
    puts "Options:"
    puts "  --dry-run   Preview what would be generated without writing files"
    puts "  --check     Check if README files are up to date (exit 1 if outdated)"
    puts "  --help, -h  Show this help message"
    puts
    puts "L1 knowledge files must have readme_order and readme_lang in YAML frontmatter."
    exit 0
  end

  ReadmeBuilder.new(dry_run: dry_run, check: check).run
end
