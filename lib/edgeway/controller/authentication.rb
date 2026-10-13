module Edgeway
  module Controller
    # Bearer-token authentication:
    #
    #   class ApplicationController < Edgeway::Controller::Base
    #     before_action :authenticate!
    #   end
    #   # or before_action :authenticate!, only: [:create]
    #
    # authenticate! answers 401 unless the request has an
    # "Authorization: Bearer <JWT>" whose token passes Edgeway::Auth; the
    # claims are then in current_claims.
    module Authentication
      # Raises Unauthorized (no token) or InvalidToken. Both are 401 with a
      # WWW-Authenticate header, unless the app rescue_froms them.
      def authenticate!
        token = bearer_token
        raise Unauthorized, "authentication required" if token.empty?
        @current_claims = Auth.decode(token)
        @authenticated = true
        nil
      end

      # The token's claims (a Hash of the JSON payload), {} when the request
      # was not authenticated.
      def current_claims
        @authenticated ? @current_claims : {}
      end

      def authenticated? = @authenticated

      private

      # The token of "Authorization: Bearer <token>", "" when there is none.
      def bearer_token
        value = @request.header("Authorization")
        scheme = "Bearer "
        return "" unless value.length > scheme.length && value[0, scheme.length].downcase == "bearer "
        value[scheme.length, value.length - scheme.length].strip
      end
    end
  end
end
