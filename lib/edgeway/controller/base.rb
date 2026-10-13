module Edgeway
  module Controller
    class Base
      include Callbacks
      include Rescuable
      include Rendering
      include Authentication

      # Base's own public methods, which a route can't name as an action
      # (action?).
      NON_ACTIONS = ["render", "head", "headers", "params", "request", "performed?", "to_response",
                     "action?", "run_before_actions", "rescue_with_handler",
                     "authenticate!", "current_claims", "authenticated?"]

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

      def initialize(request)
        @request = request
        @status = 200
        @headers = {}
        @response_body = ""
        @performed = false
        @params = nil
        @current_claims = {}
        @authenticated = false
      end

      def headers = @headers

      # true when name is an action of this controller: a public method that
      # isn't one of Base's. (respond_to? is how Spinel can ask; it is false
      # for private methods.) The explicit self matters: a receiverless
      # respond_to? with a computed name is checked in Spinel against only
      # the first 256 candidate names of the whole program, and an app's own
      # actions come last, so past that they answer false (404).
      def action?(name)
        self.respond_to?(name.to_sym) && !NON_ACTIONS.include?(name)
      end

      # The request's parameters. A JSON body without the controller's scope
      # is also found under it ("title" as "todo[title]" in TodosController),
      # as Rails' wrap_parameters does.
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

      # "TodosController" -> "todo", "Admin::CommentsController" -> "comment".
      def self.param_scope
        base = name.split("::").last.sub(/Controller\z/, "")
        base = base.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        Inflector.singularize(base)
      end
    end
  end
end
