require "edgeway"

module Edgeway
  module Controller
    class Base
      def _run_action(action)
        public_send(action.to_sym)
      end
    end

    module Dispatcher
      def self.instantiate(name, request)
        klass = nil
        begin
          klass = Object.const_get(name)
        rescue NameError
          return nil
        end
        klass.is_a?(Class) && klass < Base ? klass.new(request) : nil
      end
    end
  end
end
