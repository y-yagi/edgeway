require_relative "limiter"

module Edgeway
  module RateLimit
    class NullLimiter < Limiter
      def exceeded?(binding_name, key) = false
    end
  end
end
