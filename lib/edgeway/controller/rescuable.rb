module Edgeway
  module Controller
    class Handler
      attr_reader :error_class, :method_name

      def initialize(error_class, method_name)
        @error_class = error_class
        @method_name = method_name
      end
    end

    module Rescuable
      # true when a handler took the error. The handler is called with the
      # error, as in Rails (def not_found(e)).
      def rescue_with_handler(error)
        self.class.all_handlers.reverse.each do |handler|
          if error.is_a?(handler.error_class)
            send(handler.method_name, error)
            return true
          end
        end
        false
      end
    end
  end
end
