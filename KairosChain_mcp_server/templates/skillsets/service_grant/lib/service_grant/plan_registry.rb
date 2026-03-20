# frozen_string_literal: true

require 'yaml'
require 'digest'

module ServiceGrant
  class PlanRegistry
    BILLING_MODELS = %w[per_action metered subscription free].freeze

    def initialize(config_path)
      @config = YAML.safe_load(File.read(config_path)) || {}
      @services = @config['services'] || {}
      @version = Digest::SHA256.hexdigest(File.read(config_path))[0..7]
      validate_config!
    end

    attr_reader :version

    def currency(service)
      @services.dig(service, 'currency') || 'USD'
    end

    def current_version(service, plan)
      "#{@version}_#{service}_#{plan}"
    end

    def cycle_unit(service)
      @services.dig(service, 'cycle') || 'monthly'
    end

    def action_for_tool(service, tool_name)
      @services.dig(service, 'action_map', tool_name)
    end

    def gated_action?(service, action)
      svc = @services[service]
      return false unless svc
      plans = svc['plans'] || {}
      plans.any? { |_name, plan| (plan['limits'] || {}).key?(action) }
    end

    def plan_exists?(service, plan)
      @services.dig(service, 'plans', plan) != nil
    end

    # Returns nil if plan not in config (denied), -1 for unlimited, 0+ for limit
    def limit_for(service, plan, action)
      @services.dig(service, 'plans', plan, 'limits', action)
    end

    def trust_requirement(service, plan, action)
      @services.dig(service, 'plans', plan, 'trust_requirements', action)
    end

    # Are any non-zero trust_requirements configured across all services/plans?
    def trust_requirements_configured?
      @services.any? do |_name, svc|
        (svc['plans'] || {}).any? do |_plan, cfg|
          (cfg['trust_requirements'] || {}).any? { |_action, threshold| threshold.to_f > 0.0 }
        end
      end
    end

    def write_action?(service, action)
      write_actions = @services.dig(service, 'write_actions') || []
      write_actions.include?(action)
    end

    def subscription_price(service, plan)
      @services.dig(service, 'plans', plan, 'subscription_price')
    end

    def services
      @services.keys
    end

    def plans_for(service)
      (@services.dig(service, 'plans') || {}).keys
    end

    private

    def validate_config!
      @services.each do |name, svc|
        model = svc['billing_model']
        unless BILLING_MODELS.include?(model)
          raise ConfigValidationError, "Invalid billing_model '#{model}' for service '#{name}'"
        end
      end
    end
  end
end
