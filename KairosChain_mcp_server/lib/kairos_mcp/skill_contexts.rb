module KairosMcp
  # Guarantees block context
  class GuaranteesContext
    attr_reader :guarantees

    def initialize
      @guarantees = []
    end

    def method_missing(name, *args)
      @guarantees << name
      self
    end

    def respond_to_missing?(name, include_private = false)
      true
    end
  end

  # Effect block context
  class EffectContext
    attr_reader :name, :requirements, :recordings, :runner

    def initialize(name)
      @name = name
      @requirements = []
      @recordings = []
      @runner = nil
    end

    def requires(condition)
      @requirements << condition
    end

    def records(what)
      @recordings << what
    end

    def run(&block)
      @runner = block
    end

    def to_h
      {
        name: @name,
        requirements: @requirements,
        recordings: @recordings,
        has_runner: !@runner.nil?
      }
    end
  end

  # Evolve block context
  class EvolveContext
    attr_reader :skill_id, :allowed, :denied, :conditions

    def initialize(skill_id)
      @skill_id = skill_id
      @allowed = []
      @denied = []
      @conditions = {}
    end

    def allow(*fields)
      @allowed.concat(fields)
    end

    def deny(*fields)
      @denied.concat(fields)
    end

    def when_condition(name, &block)
      @conditions[name] = block
    end

    def can_evolve?(field)
      return false if @denied.include?(field.to_sym) || @denied.include?(:all)
      @allowed.empty? || @allowed.include?(field.to_sym)
    end

    def to_h
      {
        skill_id: @skill_id,
        allowed: @allowed,
        denied: @denied,
        conditions: @conditions.keys
      }
    end
  end
end
