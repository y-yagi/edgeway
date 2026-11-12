module Edgeway
  module Controller
    class Base
      include Callbacks
      include Rescuable
      include Rendering
      include BearerTokenAuthentication
      include Caching
      include RateLimiting

      NON_ACTIONS = ["render", "head", "headers", "params", "request", "performed?", "to_response",
                     "action?", "run_before_actions", "rescue_with_handler",
                     "authenticate!", "current_claims", "authenticated?",
                     "action_name", "action_name=", "raw",
                     "expires_in", "no_store", "fresh_when", "stale?"]

      def self.before_action(name, only: [], except: [])
        add_before_action(Callback.new(name, only.map(&:to_s), except.map(&:to_s)))
      end

      def self.rate_limit(binding_name, by: nil, name: nil, retry_after: nil, only: [], except: [])
        add_before_action(RateLimiting::Rule.build(binding_name, by, name, retry_after, only, except))
        (@own_non_actions ||= []) << by.to_s unless by.nil?
      end

      def self.own_non_actions = (@own_non_actions || [])

      def self.non_action?(name)
        lineage.any? { |c| c.own_non_actions.include?(name) }
      end

      def self.add_before_action(callback)
        @own_before_actions ||= []
        @own_before_actions << callback
      end
      private_class_method :add_before_action

      def self.own_before_actions = (@own_before_actions || [])

      def self.rescue_from(error_class, with:)
        @own_handlers ||= []
        @own_handlers << Handler.new(error_class, with)
      end

      def self.own_handlers = (@own_handlers || [])

      def self.lineage
        chain = []
        k = self
        while k
          chain.unshift(k)
          break if k == Base
          k = k.superclass
        end
        chain
      end

      def self.all_before_actions
        all = []
        lineage.each { |c| c.own_before_actions.each { |cb| all << cb } }
        all
      end

      def self.all_handlers
        all = []
        lineage.each { |c| c.own_handlers.each { |h| all << h } }
        all
      end

      attr_reader :request
      attr_accessor :action_name

      def initialize(request)
        @request = request
        @action_name = ""
        @status = 200
        @headers = {}
        @response_body = ""
        @performed = false
        @params = nil
        @current_claims = {}
        @authenticated = false
      end

      def headers = @headers

      def action?(name)
        return false if name.start_with?("_view_") || name.start_with?("_render_") || name.start_with?("_run_")
        respond_to?(name.to_sym) && !NON_ACTIONS.include?(name) && !self.class.non_action?(name)
      end

      def raw(text) = View::SafeHTML.new(text)

      def _render_view(action) = nil

      def _run_action(action) = nil

      def _render_layout(content) = content

      def params
        @params ||= wrapped_params
      end

      private

      def wrapped_params
        all = @request.params
        scope = self.class.param_scope
        prefix = "#{scope}["
        return all unless @request.json?
        return all if @request.body_params.keys.any? { |k| k.start_with?(prefix) }
        wrapped = HTTP::Parameters.new(all.to_h.dup)
        @request.body_params.each do |k, v|
          wrapped["#{scope}[#{k}]"] = v unless k.include?("[")
        end
        wrapped
      end

      def self.param_scope
        base = name.split("::").last.sub(/Controller\z/, "")
        base = base.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        Inflector.singularize(base)
      end
    end
  end
end
