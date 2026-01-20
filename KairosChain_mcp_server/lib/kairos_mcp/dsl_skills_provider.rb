require_relative 'skills_dsl'
require_relative 'skills_ast'
require_relative 'vector_search/provider'

module KairosMcp
  class DslSkillsProvider
    DSL_PATH = File.expand_path('../../skills/kairos.rb', __dir__)
    SKILLS_INDEX_PATH = File.expand_path('../../storage/embeddings/skills', __dir__)
    
    def initialize(dsl_path = DSL_PATH, vector_search_enabled: true)
      @dsl_path = dsl_path
      @skills = nil
      @vector_search_enabled = vector_search_enabled
      @vector_search = nil
      @index_built = false
    end
    
    def skills
      @skills ||= SkillsDsl.load(@dsl_path)
    end
    
    def list_skills
      skills.map { |s| { id: s.id, title: s.title, use_when: s.use_when } }
    end
    
    def get_skill(id)
      skills.find { |s| s.id == id.to_sym }
    end
    
    # Search skills using vector search (semantic) or fallback (regex)
    #
    # @param query [String] Search query
    # @param max_results [Integer] Maximum number of results
    # @param semantic [Boolean] Force semantic search if available
    # @return [Array<Skill>] Matching skills
    def search_skills(query, max_results = 3, semantic: nil)
      # Use semantic search if available and enabled
      use_semantic = semantic.nil? ? @vector_search_enabled : semantic
      
      if use_semantic && vector_search.semantic?
        semantic_search_skills(query, max_results)
      else
        regex_search_skills(query, max_results)
      end
    end

    # Get vector search status
    #
    # @return [Hash] Status information
    def vector_search_status
      {
        enabled: @vector_search_enabled,
        semantic_available: VectorSearch.available?,
        index_built: @index_built,
        document_count: vector_search.count
      }
    end

    # Rebuild the vector search index
    #
    # @return [Boolean] Success status
    def rebuild_index
      documents = skills.map do |skill|
        {
          id: skill.id.to_s,
          text: build_searchable_text(skill),
          metadata: { title: skill.title, use_when: skill.use_when }
        }
      end
      
      result = vector_search.rebuild(documents)
      @index_built = result
      result
    end
    
    def ast
      @ast ||= SkillsAst.parse(@dsl_path)
    end
    
    def validate
      nodes = SkillsAst.extract_skill_nodes(ast)
      SkillsAst.validate(nodes)
    end

    private

    def vector_search
      @vector_search ||= VectorSearch.create(index_path: SKILLS_INDEX_PATH)
    end

    def ensure_index_built
      return if @index_built
      rebuild_index
    end

    def semantic_search_skills(query, max_results)
      ensure_index_built
      
      results = vector_search.search(query, k: max_results)
      
      results.filter_map do |result|
        skill = get_skill(result[:id])
        skill if skill
      end
    end

    def regex_search_skills(query, max_results)
      pattern = Regexp.new(query, Regexp::IGNORECASE)
      
      matches = skills.select do |skill|
        skill.title.match?(pattern) ||
          skill.content.match?(pattern) ||
          (skill.use_when && skill.use_when.match?(pattern))
      end

      matches.first(max_results)
    end

    def build_searchable_text(skill)
      parts = [
        skill.title,
        skill.use_when,
        skill.content
      ].compact
      
      parts.join("\n\n")
    end
  end
end
