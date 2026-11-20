# frozen_string_literal: true

require 'digest'

module KairosMcp
  module SkillSets
    module Dream
      # Principal — whoever performs a step of dream_digest: generating, reading a digest or
      # its label, checking (design v0.13, Definitions and I9).
      #
      # What a principal may read is what the core resolves for it: the context root and the
      # knowledge root of its user context (the instance's own roots when the invoking layer
      # supplies none). A node outside those roots is absent for it. This class is the one
      # place where that is decided; the Digester resolves every node through it.
      #
      # Identity (I7, I11): supplied by the invoking layer when the layer authenticated a user
      # for this request (`user_context[:user]`), otherwise declared by the context itself, or
      # absent. The recorder reads it from here, never from the event's own content.
      class Principal
        attr_reader :user_context

        # @param user_context [Hash, nil] as set by the invoking layer (Safety#current_user)
        # @param declared_identity [String, nil] what the context says of itself; used only
        #   where the layer supplies no identity
        def initialize(user_context: nil, declared_identity: nil)
          @user_context = user_context
          @declared_identity = declared_identity
        end

        def context_root
          KairosMcp.context_dir(user_context: @user_context)
        end

        def knowledge_root
          KairosMcp.knowledge_dir(user_context: @user_context)
        end

        # @return [Hash] { 'value' => String|nil, 'source' => 'layer'|'declared'|'none' }
        def identity
          supplied = layer_identity
          return { 'value' => supplied, 'source' => 'layer' } if supplied

          declared = @declared_identity.to_s.strip
          return { 'value' => declared, 'source' => 'declared' } unless declared.empty?

          { 'value' => nil, 'source' => 'none' }
        end

        # True when no user context was supplied: the instance's own operator-side principal.
        def local?
          @user_context.nil?
        end

        # An opaque name for the root a layer's nodes resolve under for this principal. Two
        # principals read the same node for a ref exactly when their scopes for its layer are
        # equal. A root inside the instance's data directory is named by its place in it, so
        # moving or restoring the data directory changes no scope. Reveals no path.
        def scope(layer)
          root = real(layer.to_s == 'l1' ? knowledge_root : context_root)
          data = real(KairosMcp.data_dir)
          place = root.start_with?("#{data}#{File::SEPARATOR}") ? "data:#{root[(data.size + 1)..]}" : "path:#{root}"
          Digest::SHA256.hexdigest("dream_digest.scope\0#{place}")
        end

        # True if this principal may read every node of a READ set recorded under `scopes`
        # ({layer => scope}). Evaluated now, from the roots this principal resolves to now.
        def within?(scopes)
          return false unless scopes.is_a?(Hash) && !scopes.empty?

          scopes.all? { |layer, recorded| %w[l1 l2].include?(layer.to_s) && scope(layer) == recorded }
        end

        private

        def layer_identity
          return nil unless @user_context.respond_to?(:[])

          user = (@user_context[:user] || @user_context['user']).to_s.strip
          return nil if user.empty?

          tenant = (@user_context[:tenant_schema] || @user_context['tenant_schema']).to_s.strip
          tenant.empty? ? user : "#{tenant}:#{user}"
        end

        # The real path of a root, whether or not it exists yet: the nearest existing ancestor
        # is resolved and the rest appended, so the scope does not change when the root is
        # created.
        def real(path)
          path = File.expand_path(path.to_s)
          rest = []
          until File.exist?(path)
            parent = File.dirname(path)
            break if parent == path

            rest.unshift(File.basename(path))
            path = parent
          end
          File.join(File.realpath(path), *rest)
        rescue StandardError
          File.expand_path(path.to_s)
        end
      end
    end
  end
end
