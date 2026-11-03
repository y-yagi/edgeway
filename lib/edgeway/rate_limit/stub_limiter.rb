require_relative "limiter"

module Edgeway
  module RateLimit
    class StubLimiter < Limiter
      attr_reader :checks

      def initialize
        @exceeded_bindings = []
        @checks = []
      end

      def stub(binding_name, exceeded)
        @exceeded_bindings.delete(binding_name)
        @exceeded_bindings << binding_name if exceeded
      end

      def exceeded?(binding_name, key)
        @checks << [binding_name, key]
        @exceeded_bindings.include?(binding_name)
      end
    end
  end
end
