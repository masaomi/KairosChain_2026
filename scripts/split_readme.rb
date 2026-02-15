#!/usr/bin/env ruby
# frozen_string_literal: true

# split_readme.rb - Split README into L1 knowledge files
#
# This is a one-time migration script. After splitting, use build_readme.rb
# to regenerate READMEs from L1 knowledge.
#
# Usage:
#   ruby scripts/split_readme.rb --lang jp --dry-run
#   ruby scripts/split_readme.rb --lang jp
#   ruby scripts/split_readme.rb --lang en --dry-run
#   ruby scripts/split_readme.rb --lang en

require "fileutils"

class ReadmeSplitter
  PROJECT_ROOT = File.expand_path("..", __dir__)
  KNOWLEDGE_DIR = File.join(PROJECT_ROOT, "KairosChain_mcp_server", "knowledge")

  # Section definitions: which ## headings go into which L1 knowledge
  # The heading text must match exactly (for the given language)
  SECTIONS_JP = {
    "kairoschain_philosophy_jp" => {
      description: "KairosChainの哲学、アーキテクチャ、レイヤー設計",
      tags: %w[documentation readme philosophy architecture layers data-model],
      headings: ["哲学", "アーキテクチャ", "レイヤー化されたスキルアーキテクチャ", "データモデル：SkillStateTransition"]
    },
    "kairoschain_setup_jp" => {
      description: "KairosChainのインストール、設定、テスト手順",
      tags: %w[documentation readme setup installation configuration testing],
      headings: ["セットアップ", "クライアント設定", "Gemのアップグレード", "セットアップのテスト"]
    },
    "kairoschain_usage_jp" => {
      description: "KairosChainのツール一覧、使用方法、進化ワークフロー",
      tags: %w[documentation readme usage tools workflow examples],
      headings: ["使用のヒント", "利用可能なツール（コア25個 + スキルツール）", "使用例", "自己進化ワークフロー"]
    },
    "kairoschain_design_jp" => {
      description: "Pure Skills設計とディレクトリ構造",
      tags: %w[documentation readme design architecture directory-structure],
      headings: ["Pure Skills設計", "ディレクトリ構造"]
    },
    "kairoschain_operations_jp" => {
      description: "将来のロードマップ、デプロイ、運用ガイド",
      tags: %w[documentation readme operations deployment roadmap backup],
      headings: ["将来のロードマップ", "デプロイと運用"]
    },
    "kairoschain_faq_jp" => {
      description: "よくある質問とサブツリー統合ガイド",
      tags: %w[documentation readme faq subtree integration],
      headings: ["FAQ", "サブツリー統合ガイド"]
    }
  }.freeze

  SECTIONS_EN = {
    "kairoschain_philosophy" => {
      description: "KairosChain philosophy, architecture, and layered skill design",
      tags: %w[documentation readme philosophy architecture layers data-model],
      headings: ["Philosophy", "Architecture", "Layered Skills Architecture", "Data Model: SkillStateTransition"]
    },
    "kairoschain_setup" => {
      description: "KairosChain installation, configuration, and testing guide",
      tags: %w[documentation readme setup installation configuration testing],
      headings: ["Setup", "Client Configuration", "Upgrading the Gem", "Testing the Setup"]
    },
    "kairoschain_usage" => {
      description: "KairosChain tools reference, usage patterns, and evolution workflow",
      tags: %w[documentation readme usage tools workflow examples],
      headings: ["Usage Tips", "Available Tools (25 core + skill-tools)", "Usage Examples", "Self-Evolution Workflow"]
    },
    "kairoschain_design" => {
      description: "Pure Skills design and directory structure",
      tags: %w[documentation readme design architecture directory-structure],
      headings: ["Pure Skills Design", "Directory Structure"]
    },
    "kairoschain_operations" => {
      description: "Future roadmap, deployment, and operations guide",
      tags: %w[documentation readme operations deployment roadmap backup],
      headings: ["Future Roadmap", "Deployment and Operation"]
    },
    "kairoschain_faq" => {
      description: "Frequently asked questions and subtree integration guide",
      tags: %w[documentation readme faq subtree integration],
      headings: ["FAQ", "Subtree Integration Guide"]
    }
  }.freeze

  def initialize(lang:, dry_run: false)
    @lang = lang
    @dry_run = dry_run
    @sections = lang == "jp" ? SECTIONS_JP : SECTIONS_EN
    @readme_path = lang == "jp" ?
      File.join(PROJECT_ROOT, "README_jp.md") :
      File.join(PROJECT_ROOT, "README.md")
  end

  def run
    content = File.read(@readme_path)
    lines = content.lines

    # Parse into ## sections
    parsed_sections = parse_sections(lines)

    # Map sections to L1 knowledge
    order = 0
    @sections.each do |knowledge_name, config|
      order += 1
      body = extract_body(parsed_sections, config[:headings])

      if body.strip.empty?
        warn "[WARN] No content found for #{knowledge_name}"
        next
      end

      frontmatter = {
        "name" => knowledge_name,
        "description" => config[:description],
        "version" => "1.0",
        "layer" => "L1",
        "tags" => config[:tags],
        "readme_order" => order,
        "readme_lang" => @lang
      }

      file_content = "---\n"
      file_content += frontmatter.map { |k, v|
        if v.is_a?(Array)
          "#{k}: [#{v.join(', ')}]"
        else
          "#{k}: #{v.is_a?(String) && v.match?(/[:#\[\]{},]/) ? "\"#{v}\"" : v}"
        end
      }.join("\n")
      file_content += "\n---\n\n"
      file_content += body.rstrip + "\n"

      output_dir = File.join(KNOWLEDGE_DIR, knowledge_name)
      output_path = File.join(output_dir, "#{knowledge_name}.md")

      if @dry_run
        puts "=" * 60
        puts "Would write: #{output_path}"
        puts "Body length: #{body.length} chars, #{body.lines.count} lines"
        puts "Headings: #{config[:headings].join(', ')}"
        puts "=" * 60
        puts
      else
        FileUtils.mkdir_p(output_dir)
        File.write(output_path, file_content)
        puts "Created: #{output_path} (#{body.lines.count} lines)"
      end
    end
  end

  private

  # Parse README into ## level sections
  # Returns hash: { heading_text => content_string }
  # Correctly handles ## headings inside code blocks (``` ... ```)
  def parse_sections(lines)
    sections = {}
    current_heading = nil
    current_lines = []
    in_code_block = false

    lines.each do |line|
      # Track code block boundaries
      if line.strip.start_with?("```")
        in_code_block = !in_code_block
      end

      if !in_code_block && line.match?(/\A## /)
        # Save previous section
        if current_heading
          sections[current_heading] = current_lines.join
        end

        current_heading = line.sub(/\A## /, "").strip
        current_lines = [line]
      elsif current_heading
        current_lines << line
      end
      # Lines before first ## heading are skipped (header/TOC)
    end

    # Save last section
    if current_heading
      sections[current_heading] = current_lines.join
    end

    sections
  end

  # Extract body for a set of headings, combining them in order
  def extract_body(parsed_sections, headings)
    parts = []

    headings.each do |heading|
      content = parsed_sections[heading]
      if content
        parts << content.rstrip
      else
        warn "[WARN] Heading not found: '#{heading}'"
      end
    end

    parts.join("\n\n")
  end
end

# CLI
if __FILE__ == $PROGRAM_NAME
  lang = nil
  dry_run = ARGV.include?("--dry-run")

  if ARGV.include?("--lang")
    idx = ARGV.index("--lang")
    lang = ARGV[idx + 1]
  end

  if lang.nil? || !%w[en jp].include?(lang)
    puts "Usage: ruby scripts/split_readme.rb --lang <en|jp> [--dry-run]"
    exit 1
  end

  ReadmeSplitter.new(lang: lang, dry_run: dry_run).run
end
