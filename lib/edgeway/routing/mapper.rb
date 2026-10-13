module Edgeway
  module Routing
    class Mapper
      ACTIONS = ["index", "show", "create", "update", "destroy"]

      def initialize(routes, path_prefix, module_prefix)
        @routes = routes
        @path_prefix = path_prefix
        @module_prefix = module_prefix
      end

      def get(path, to:) = add("GET", path, to)
      def post(path, to:) = add("POST", path, to)
      def patch(path, to:) = add("PATCH", path, to)
      def put(path, to:) = add("PUT", path, to)
      def delete(path, to:) = add("DELETE", path, to)

      def root(to:) = add("GET", "/", to)

      def namespace(name)
        yield Mapper.new(@routes, "#{@path_prefix}/#{name}", "#{@module_prefix}#{name}/")
      end

      def resources(name, only: [], except: [])
        base = "/#{name}"
        member = "#{base}/:id"
        (only + except).each do |a|
          raise ArgumentError, "unknown action for resources :#{name}: #{a}" unless ACTIONS.include?(a.to_s)
        end
        want = ACTIONS.dup
        want = only.map(&:to_s) unless only.empty?
        want = want.reject { |a| except.map(&:to_s).include?(a) }

        add("GET", base, "#{name}#index") if want.include?("index")
        add("POST", base, "#{name}#create") if want.include?("create")
        add("GET", member, "#{name}#show") if want.include?("show")
        if want.include?("update")
          add("PATCH", member, "#{name}#update")
          add("PUT", member, "#{name}#update")
        end
        add("DELETE", member, "#{name}#destroy") if want.include?("destroy")
        if block_given?
          yield Mapper.new(@routes, "#{@path_prefix}#{base}/:#{Mapper.singular(name)}_id", @module_prefix)
        end
      end

      def self.singular(name) = Inflector.singularize(name)

      private

      def add(verb, path, to)
        controller, action = to.split("#", 2)
        @routes.add(Route.new(verb, @path_prefix + path, @module_prefix + controller, action))
      end
    end
  end
end
