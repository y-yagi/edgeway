require "json"
require_relative "../../rate_limit"

module Edgeway
  module Cloudflare
    class RateLimitTransport
      def check(binding_name, key)
        raise Edgeway::Error, "#{self.class.name} does not check"
      end
    end

    class RateLimiter < RateLimit::Limiter
      def initialize(transport:)
        @transport = transport
      end

      def exceeded?(binding_name, key)
        answer = JSON.parse(@transport.check(binding_name, Digest::SHA256.hexdigest(key)))
        raise ConfigurationError, "rate limit: #{answer["misconfigured"]}" if answer.key?("misconfigured")
        return failed_open(binding_name, answer["error"]) if answer.key?("error")

        answer["success"] == false
      end

      private

      def failed_open(binding_name, message)
        Edgeway.logger.warn("rate limit check failed", { "binding" => binding_name, "error" => message })
        false
      end
    end
  end
end
