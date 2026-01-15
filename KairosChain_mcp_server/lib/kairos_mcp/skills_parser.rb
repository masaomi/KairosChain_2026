module KairosMcp
  class SkillsParser
    SKILLS_PATH = File.expand_path('../../skills/kairos.md', __dir__)

    Section = Struct.new(:id, :title, :content, :use_when, keyword_init: true)

    def initialize(skills_path = SKILLS_PATH)
      @skills_path = skills_path
      @sections = nil
    end

    def sections
      @sections ||= parse_sections
    end

    def list_sections
      sections.map do |section|
        {
          id: section.id,
          title: section.title,
          use_when: section.use_when
        }
      end
    end

    def get_section(section_id)
      sections.find { |s| s.id == section_id }
    end

    def search_sections(query, max_results = 3)
      pattern = Regexp.new(query, Regexp::IGNORECASE)
      
      matches = sections.select do |section|
        section.title.match?(pattern) ||
          section.content.match?(pattern) ||
          (section.use_when && section.use_when.match?(pattern))
      end

      matches.first(max_results)
    end

    private

    def parse_sections
      return [] unless File.exist?(@skills_path)

      content = File.read(@skills_path)
      parsed_sections = []
      current_section = nil
      content_lines = []

      content.each_line do |line|
        # Match section headers like "## [ARCH-010] System Architecture"
        if line =~ /^##\s+\[([A-Z]+-\d+)\]\s+(.+)$/
          # Save previous section if exists
          if current_section
            current_section.content = content_lines.join
            parsed_sections << current_section
          end

          section_id = $1
          section_title = $2.strip
          
          current_section = Section.new(
            id: section_id,
            title: section_title,
            content: '',
            use_when: nil
          )
          content_lines = []
        elsif current_section
          content_lines << line
        end
      end

      # Don't forget the last section
      if current_section
        current_section.content = content_lines.join
        parsed_sections << current_section
      end

      # Extract "use_when" from TOC if available
      extract_use_when_from_toc(content, parsed_sections)

      parsed_sections
    end

    def extract_use_when_from_toc(content, sections)
      # Parse the TOC table to extract "Use When" information
      # Format: | Section ID | Title | Use When |
      toc_pattern = /\|\s*([A-Z]+-\d+)\s*\|[^|]+\|\s*([^|]+)\s*\|/

      content.scan(toc_pattern) do |id, use_when|
        section = sections.find { |s| s.id == id }
        section.use_when = use_when.strip if section && use_when
      end
    end
  end
end
