module Edgeway
  module Routing
    class RouteSet
      attr_reader :list

      def initialize
        @list = []
      end

      def draw
        yield Mapper.new(self, "", "")
      end

      def add(route)
        @list << route
      end

      def recognize(verb, path)
        @list.each do |route|
          found = route.match(verb, path)
          return [route, found] if found
        end
        raise RoutingError, "no route for #{verb} #{path}"
      end
    end
  end
end
