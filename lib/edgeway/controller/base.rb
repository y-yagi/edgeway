module Edgeway
  module Controller
    class Base
      include Callbacks
      include Rescuable
      include Rendering
      include Authentication

      NON_ACTIONS = ["render", "head", "headers", "params", "request", "performed?", "to_response",
                     "action?", "run_before_actions", "rescue_with_handler",
                     "authenticate!", "current_claims", "authenticated?",
                     "action_name", "action_name=", "raw"]

      def self.before_action(name, only: [], except: [])
        @own_before_actions ||= []
        @own_before_actions << Callback.new(name, only.map(&:to_s), except.map(&:to_s))
      end

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
        return false if name.start_with?("_view_") || name.start_with?("_render_")
        respond_to?(name.to_sym) && !NON_ACTIONS.include?(name)
      end

      def raw(text) = View::SafeHTML.new(text)

      def _render_view(action) = nil

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
