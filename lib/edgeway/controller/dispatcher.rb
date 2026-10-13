module Edgeway
  module Controller
    module Dispatcher
      def self.controller_class(route)
        klass = nil
        begin
          klass = Object.const_get(route.controller_class_name)
        rescue NameError
          return nil
        end
        klass.is_a?(Class) && klass < Base ? klass : nil
      end

      def self.dispatch(route, request)
        klass = controller_class(route)
        raise RoutingError, "no controller for #{route.controller_path}" if klass.nil?
        controller = klass.new(request)
        # A route whose action isn't defined (or is one of Base's own public
        # methods) is a 404, as in Rails.
        raise RoutingError, "no route for #{request.method} #{request.path}" unless controller.action?(route.action)
        begin
          # The action is called here, on an instance of a class found by
          # name, and not from a Base method: with a name taken as a method
          # argument Spinel's send looks among the literals of the program,
          # and misses a subclass's methods (matz/spinel#8592). public_send:
          # a route can't reach a private method.
          action = route.action.to_sym
          controller.public_send(action) if controller.run_before_actions(route.action)
          controller.head(:no_content) unless controller.performed?
        rescue => e
          raise e unless controller.rescue_with_handler(e)
          # A handler that rendered nothing answers 204, as an action does.
          controller.head(:no_content) unless controller.performed?
        end
        controller.to_response
      end
    end
  end
end
