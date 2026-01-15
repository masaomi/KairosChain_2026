require_relative 'skills_dsl'
require_relative 'skills_ast'

module KairosMcp
  class DslSkillsProvider
    DSL_PATH = File.expand_path('../../skills/kairos.rb', __dir__)
    
    def initialize(dsl_path = DSL_PATH)
      @dsl_path = dsl_path
      @skills = nil
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
    
    def search_skills(query, max_results = 3)
      pattern = Regexp.new(query, Regexp::IGNORECASE)
      
      matches = skills.select do |skill|
        skill.title.match?(pattern) ||
          skill.content.match?(pattern) ||
          (skill.use_when && skill.use_when.match?(pattern))
      end

      matches.first(max_results)
    end
    
    def ast
      @ast ||= SkillsAst.parse(@dsl_path)
    end
    
    def validate
      nodes = SkillsAst.extract_skill_nodes(ast)
      SkillsAst.validate(nodes)
    end
  end
end
