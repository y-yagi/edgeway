require_relative "jwt"

module Edgeway
  module Auth
    class StubVerifier < Verifier
      def initialize
        @answers = {}
      end

      def allow(token, payload)
        @answers[token] = JSON.generate({ "header" => { "alg" => "stub" }, "payload" => payload })
      end

      def reject(token, message)
        @answers[token] = JSON.generate({ "error" => message })
      end

      def unavailable(token, message)
        @answers[token] = JSON.generate({ "error" => message, "unavailable" => true })
      end

      def verify(token)
        @answers[token] || JSON.generate({ "error" => "signature is not valid" })
      end
    end
  end
end
