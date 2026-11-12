module Edgeway
  module Controller
    module Dispatcher
      def self.instantiate(name, request) = nil

      def self.dispatch(route, request)
        controller = Dispatcher.instantiate(route.controller_class_name, request)
        raise RoutingError, "no controller for #{route.controller_path}" if controller.nil?
        controller.action_name = route.action
        # The build refuses a route to an action that isn't defined (or is one
        # of Base's own public methods); this stays so that a private method
        # or a Base method can't be reached whatever generated the dispatch.
        raise RoutingError, "no route for #{request.method} #{request.path}" unless controller.action?(route.action)
        begin
          # instantiate and _run_action are generated from the routes by
          # `edgeway build` / `edgeway test`: a class found by name and a send
          # with a computed name make Spinel emit a branch for every class and
          # every method name of the program, and keep their code reachable.
          controller._run_action(route.action) if controller.run_before_actions(route.action)
          implicit_render(controller, route) unless controller.performed?
        rescue => e
          raise e unless controller.rescue_with_handler(e)
          # A handler that rendered nothing answers 204, as an action does.
          controller.head(:no_content) unless controller.performed?
        end
        controller.to_response
      end

      def self.implicit_render(controller, route)
        content = controller._render_view(route.action)
        if content.nil?
          controller.head(:no_content)
        else
          controller.render(html: View::SafeHTML.new(content))
        end
      end
    end
  end
end
