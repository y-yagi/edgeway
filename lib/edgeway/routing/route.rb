module Edgeway
  module Routing
    class Route
      attr_reader :verb, :pattern, :controller_path, :action

      def initialize(verb, pattern, controller_path, action)
        @verb = verb
        @pattern = pattern
        @segments = Route.split(pattern)
        @controller_path = controller_path
        @action = action
      end

      def self.split(path) = path.split("/").reject(&:empty?)

      def controller_class_name = Inflector.controller_class_name(@controller_path)

      def match(verb, path)
        return nil unless verb == @verb || (verb == "HEAD" && @verb == "GET")
        parts = Route.split(path)
        return nil unless parts.size == @segments.size
        found = {}
        @segments.each_with_index do |seg, i|
          if seg.start_with?(":")
            found[seg[1..]] = parts[i]
          elsif seg != parts[i]
            return nil
          end
        end
        found
      end
    end
  end
end
