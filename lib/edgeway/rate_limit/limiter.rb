module Edgeway
  module RateLimit
    class Limiter
      def exceeded?(binding_name, key)
        raise Edgeway::Error, "#{self.class.name} does not check limits"
      end
    end
  end
end
