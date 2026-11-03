module Edgeway
  module Controller
    class Callback
      attr_reader :name

      def initialize(name, only, except)
        @name = name
        @only = only
        @except = except
      end

      def run(controller)
        controller.send(@name)
      end

      def applies?(action)
        return false if @except.include?(action)
        @only.empty? || @only.include?(action)
      end
    end

    module Callbacks
      def run_before_actions(action)
        self.class.all_before_actions.each do |callback|
          next unless callback.applies?(action)
          callback.run(self)
          return false if performed?
        end
        true
      end
    end
  end
end
