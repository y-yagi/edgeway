module Edgeway
  module Auth
    # Checks a token's signature and algorithm. verify answers JSON text:
    #
    #   {"header": {...}, "payload": {...}}   the token is genuine
    #   {"error": "message"}                  it is not
    #   {"error": "message", "unavailable": true}  it could not be checked
    #                                         (a missing setting, no JWKS)
    #
    # The base answers "unavailable", for an app that set no verifier.
    class Verifier
      def verify(token)
        JSON.generate({ "error" => "no JWT verifier is set", "unavailable" => true })
      end
    end

    class JWT
      # Seconds of clock skew allowed when JWT_LEEWAY is not set.
      DEFAULT_LEEWAY = 5
      # The most JWT_LEEWAY may be: a larger skew would keep expired tokens alive.
      MAX_LEEWAY = 300

      # The settings come from the Worker's variables: JWT_ISSUER and
      # JWT_AUDIENCE (both required: decode fails closed when either is
      # empty, see decode), JWT_LEEWAY (seconds of clock skew to allow,
      # default DEFAULT_LEEWAY; "0" for none; a whole number of seconds, at
      # most MAX_LEEWAY: anything else is a ConfigurationError).
      def self.from_config
        new(Auth.verifier, issuer: Edgeway.config("JWT_ISSUER"), audience: Edgeway.config("JWT_AUDIENCE"),
            leeway: parse_leeway(Edgeway.config("JWT_LEEWAY", DEFAULT_LEEWAY.to_s)))
      end

      # JWT_LEEWAY as an Integer. Fails closed: a typo must not become 0 or
      # a huge skew.
      def self.parse_leeway(text)
        unless text.match?(/\A[0-9]+\z/) && text.length <= 6 && text.to_i <= MAX_LEEWAY
          raise ConfigurationError, "jwt: JWT_LEEWAY must be a whole number of seconds, 0 to #{MAX_LEEWAY}"
        end
        text.to_i
      end

      # now: the time as Unix seconds, for tests (0: the clock).
      def initialize(verifier, issuer: "", audience: "", leeway: DEFAULT_LEEWAY, now: 0)
        @verifier = verifier
        @issuer = issuer
        @audience = audience
        @leeway = leeway
        @now = now
      end

      # The token's claims (a Hash). Raises InvalidToken when the token is
      # not genuine or a claim fails, ConfigurationError when it could not
      # be checked. An empty issuer or audience is a misconfiguration (500,
      # never a pass), found before the token is looked at, for every
      # algorithm: without them a token from the same IdP for another API
      # (or, for Firebase, another project) would be accepted.
      def decode(token)
        raise ConfigurationError, "jwt: JWT_ISSUER is not set" if @issuer.empty?
        raise ConfigurationError, "jwt: JWT_AUDIENCE is not set" if @audience.empty?
        unless @leeway.is_a?(Integer) && @leeway >= 0 && @leeway <= MAX_LEEWAY
          raise ConfigurationError, "jwt: JWT_LEEWAY must be a whole number of seconds, 0 to #{MAX_LEEWAY}"
        end
        res = JSON.parse(@verifier.verify(token))
        if res.key?("error")
          raise ConfigurationError, "jwt: #{res["error"]}" if res.key?("unavailable")
          raise InvalidToken, res["error"].to_s
        end
        claims = res["payload"]
        check_claims(claims)
        claims
      end

      private

      def check_claims(claims)
        now = (@now == 0 ? Time.now.to_i : @now).to_f
        # A token that never expires is not accepted.
        raise InvalidToken, "exp is missing" unless claims.key?("exp")
        raise InvalidToken, "token expired" if now - @leeway >= number(claims, "exp")
        raise InvalidToken, "token is not valid yet" if claims.key?("nbf") && now + @leeway < number(claims, "nbf")
        raise InvalidToken, "token is issued in the future" if claims.key?("iat") && now + @leeway < number(claims, "iat")
        # auth_time (OIDC) is optional; when there, the login must not be in the future.
        raise InvalidToken, "authenticated in the future" if claims.key?("auth_time") && now + @leeway < number(claims, "auth_time")
        raise InvalidToken, "iss is missing" unless claims.key?("iss")
        raise InvalidToken, "issuer is not accepted" if claims["iss"] != @issuer
        raise InvalidToken, "aud is missing" unless claims.key?("aud")
        raise InvalidToken, "audience is not accepted" unless audience?(claims["aud"])
        # Apps scope their data by sub, so a missing or empty one must not pass
        # (a missing sub would match "user_id IS NULL", an empty one is shared).
        raise InvalidToken, "sub is missing" unless claims.key?("sub")
        raise InvalidToken, "sub is not a non-empty string" unless claims["sub"].is_a?(String) && !claims["sub"].empty?
      end

      # A time claim as a Float; anything else is a bad token. (JSON numbers
      # parse as Integer or Float.)
      def number(claims, name)
        v = claims[name]
        raise InvalidToken, "#{name} is not a number" unless v.is_a?(Integer) || v.is_a?(Float)
        v.to_f
      end

      # aud is a string or an array of strings.
      def audience?(aud)
        if aud.is_a?(String)
          aud == @audience
        elsif aud.is_a?(Array)
          aud.include?(@audience)
        else
          false
        end
      end
    end

    @verifier = Verifier.new

    def self.verifier = @verifier

    def self.verifier=(verifier)
      @verifier = verifier
    end

    # The claims of a token, checked with the app's settings.
    def self.decode(token)
      JWT.from_config.decode(token)
    end
  end
end
