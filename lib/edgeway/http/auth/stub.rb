require_relative "jwt"

module Edgeway
  module Auth
    # A verifier for tests, like DB::MemoryAdapter: it knows the tokens a test
    # gave it, and nothing is signed.
    #
    #   stub = Edgeway::Auth::StubVerifier.new
    #   Edgeway::Auth.verifier = stub
    #   stub.allow("good", { "sub" => "u1", "exp" => 4102444800 })
    class StubVerifier < Verifier
      def initialize
        @answers = {}
      end

      # verify answers this payload for the token.
      def allow(token, payload)
        @answers[token] = JSON.generate({ "header" => { "alg" => "stub" }, "payload" => payload })
      end

      # verify answers this error for the token.
      def reject(token, message)
        @answers[token] = JSON.generate({ "error" => message })
      end

      # verify says the token could not be checked.
      def unavailable(token, message)
        @answers[token] = JSON.generate({ "error" => message, "unavailable" => true })
      end

      def verify(token)
        @answers[token] || JSON.generate({ "error" => "signature is not valid" })
      end
    end
  end
end
