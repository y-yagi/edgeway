require "edgeway"
require "edgeway/http/auth/stub"

NOW = 1_800_000_000

stub = Edgeway::Auth::StubVerifier.new
Edgeway::Auth.verifier = stub

# A method, not a constant: since matz/spinel 44119ab30 a String constant put
# into Hashes beside a const_get with a computed name emits C that does not compile.
def iss = "https://idp.example/"

def decode(stub, token, payload, issuer: iss, audience: "api", leeway: 0)
  stub.allow(token, payload) unless payload.nil?
  jwt = Edgeway::Auth::JWT.new(stub, issuer: issuer, audience: audience, leeway: leeway, now: NOW)
  claims = jwt.decode(token)
  puts "ok #{JSON.generate(claims)}"
rescue Edgeway::InvalidToken => e
  puts "invalid: #{e.message}"
rescue Edgeway::ConfigurationError => e
  puts "unavailable: #{e.message}"
end

puts "-- the verifier's answers"
decode(stub, "t1", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 60 })
decode(stub, "unknown", nil)
stub.reject("t2", "algorithm is not allowed")
decode(stub, "t2", nil)
stub.unavailable("t3", "JWT_SECRET is not set")
decode(stub, "t3", nil)
puts Edgeway::Auth::Verifier.new.verify("x")

puts "-- exp, nbf, iat"
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 1 })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW - 1 })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW - 5 }, leeway: 10)
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW - 10 }, leeway: 10)
decode(stub, "a", { "sub" => "no exp", "iss" => iss, "aud" => "api" })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => "soon" })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => 4_102_444_800 })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 60.5 })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 60, "nbf" => NOW })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 60, "nbf" => NOW + 1 })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 60, "nbf" => NOW + 5 }, leeway: 5)
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 60, "nbf" => "x" })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 60, "iat" => NOW })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 60, "iat" => NOW + 1 })
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW + 60, "iat" => NOW + 1 }, leeway: 1)

puts "-- iss, aud"
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api" })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => "https://evil.example/", "aud" => "api" })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "aud" => "api" })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => 7, "aud" => "api" })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => ["web", "api"] })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => ["web"] })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "web" })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => 7 })

puts "-- sub"
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api" })
decode(stub, "a", { "exp" => NOW + 60, "iss" => iss, "aud" => "api" })
decode(stub, "a", { "sub" => "", "exp" => NOW + 60, "iss" => iss, "aud" => "api" })
decode(stub, "a", { "sub" => 123, "exp" => NOW + 60, "iss" => iss, "aud" => "api" })
decode(stub, "a", { "sub" => nil, "exp" => NOW + 60, "iss" => iss, "aud" => "api" })
decode(stub, "a", { "sub" => ["u1"], "exp" => NOW + 60, "iss" => iss, "aud" => "api" })
decode(stub, "a", { "sub" => "abc@clients", "exp" => NOW + 60, "iss" => iss, "aud" => "api" })

puts "-- auth_time"
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api", "auth_time" => NOW - 100 })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api", "auth_time" => NOW })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api", "auth_time" => NOW + 1 })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api", "auth_time" => NOW + 1 }, leeway: 1)
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api", "auth_time" => NOW + 2 }, leeway: 1)
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api", "auth_time" => "yesterday" })
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api", "auth_time" => nil })

puts "-- unset issuer or audience is a misconfiguration"
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api" }, issuer: "")
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api" }, audience: "")
decode(stub, "a", { "sub" => "u1", "exp" => NOW + 60, "iss" => iss, "aud" => "api" }, issuer: "", audience: "")
decode(stub, "nope", nil, issuer: "")
decode(stub, "t3", nil, audience: "")

puts "-- the clock"
stub.allow("c", { "sub" => "u1", "exp" => Time.now.to_i + 3600, "iat" => Time.now.to_i - 5, "iss" => iss, "aud" => "api" })
puts Edgeway::Auth::JWT.new(stub, issuer: iss, audience: "api").decode("c").key?("exp")
stub.allow("old", { "sub" => "u1", "exp" => Time.now.to_i - 3600, "iss" => iss, "aud" => "api" })
begin
  Edgeway::Auth::JWT.new(stub, issuer: iss, audience: "api").decode("old")
rescue Edgeway::InvalidToken => e
  puts "invalid: #{e.message}"
end

puts "-- the default leeway is 5 seconds"
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW - 4 }, leeway: Edgeway::Auth::JWT::DEFAULT_LEEWAY)
decode(stub, "a", { "sub" => "u1", "iss" => iss, "aud" => "api", "exp" => NOW - 5 }, leeway: Edgeway::Auth::JWT::DEFAULT_LEEWAY)
puts Edgeway::Auth::JWT::DEFAULT_LEEWAY
ENV["JWT_ISSUER"] = "https://idp.example/"
ENV["JWT_AUDIENCE"] = "api"
# JWT_LEEWAY is not set yet: from_config (Auth.decode) uses the default.
stub.allow("d1", { "sub" => "u1", "exp" => Time.now.to_i - 3, "iss" => iss, "aud" => "api" })
puts Edgeway::Auth.decode("d1")["iss"]
stub.allow("d2", { "sub" => "u1", "exp" => Time.now.to_i - 30, "iss" => iss, "aud" => "api" })
begin
  Edgeway::Auth.decode("d2")
rescue Edgeway::InvalidToken => e
  puts "invalid: #{e.message}"
end

puts "-- settings from the environment"
ENV["JWT_LEEWAY"] = "30"
stub.allow("e1", { "sub" => "u1", "exp" => Time.now.to_i - 10, "iss" => "https://idp.example/", "aud" => "api" })
puts Edgeway::Auth.decode("e1")["aud"]
stub.allow("e2", { "sub" => "u1", "exp" => Time.now.to_i + 60, "iss" => "https://idp.example/", "aud" => "other" })
begin
  Edgeway::Auth.decode("e2")
rescue Edgeway::InvalidToken => e
  puts "invalid: #{e.message}"
end
puts "-- JWT_LEEWAY is validated"
["300", "0", "301", "-1", "abc", "5.5", "1e2", "99999999999"].each do |v|
  ENV["JWT_LEEWAY"] = v
  begin
    Edgeway::Auth.decode("e1")
    puts "#{v}: ok"
  rescue Edgeway::ConfigurationError => e
    puts "#{v}: unavailable: #{e.message}"
  rescue Edgeway::InvalidToken => e
    puts "#{v}: invalid: #{e.message}"
  end
end
[-1, 301, 1.5].each { |v| decode(stub, "e1", nil, leeway: v) }
ENV["JWT_LEEWAY"] = "30"
ENV["JWT_AUDIENCE"] = ""
begin
  Edgeway::Auth.decode("e1")
rescue Edgeway::ConfigurationError => e
  puts "unavailable: #{e.message}"
end
ENV["JWT_ISSUER"] = ""
begin
  Edgeway::Auth.decode("e1")
rescue Edgeway::ConfigurationError => e
  puts "unavailable: #{e.message}"
end
ENV["JWT_LEEWAY"] = "5"

puts "-- the error classes"
puts Edgeway::InvalidToken.ancestors.take_while { |k| k != Exception }.join(" < ")

# ---- in a controller ----

class ApplicationController < Edgeway::Controller::Base
end

class MeController < ApplicationController
  before_action :authenticate!, except: [:open]

  def show = render json: { "sub" => current_claims["sub"], "authenticated" => authenticated? }

  def open = render json: { "authenticated" => authenticated?, "claims" => current_claims }
end

class SoftController < ApplicationController
  before_action :authenticate!
  rescue_from Edgeway::Unauthorized, with: :denied

  def show = render json: { "ok" => true }

  def denied(e)
    render json: { "denied" => e.message }, status: :forbidden
  end
end

app = Edgeway::Application.new
app.routes.draw do |r|
  r.get "/me", to: "me#show"
  r.get "/open", to: "me#open"
  r.get "/soft", to: "soft#show"
end

ENV["JWT_ISSUER"] = iss
ENV["JWT_AUDIENCE"] = "api"
stub.allow("good", { "sub" => "u1", "exp" => Time.now.to_i + 600, "iss" => iss, "aud" => "api" })
stub.allow("old", { "sub" => "u1", "exp" => Time.now.to_i - 600, "iss" => iss, "aud" => "api" })

def get(app, path, authorization)
  ENV["HTTP_AUTHORIZATION"] = authorization
  res = app.call(Edgeway::HTTP::Request.new("GET", path, "", "", ""))
  challenge = res.headers["WWW-Authenticate"]
  puts "#{path} [#{authorization}] -> #{res.status} #{res.body.strip}#{challenge ? "  (#{challenge})" : ""}"
end

# What is logged (the reasons), kept in memory.
class CaptureLogger
  def initialize
    @lines = []
  end

  def info(message)
    @lines << "info #{message}"
  end

  def error(message)
    @lines << "error #{message}"
  end

  def take
    out = @lines
    @lines = []
    out
  end
end
capture = CaptureLogger.new
Edgeway.logger = capture

puts "-- requests"
get(app, "/me", "")
get(app, "/me", "Bearer good")
get(app, "/me", "bearer good")
get(app, "/me", "Bearer   good  ")
get(app, "/me", "Bearer")
get(app, "/me", "Bearer ")
get(app, "/me", "Basic Zm9vOmJhcg==")
get(app, "/me", "Bearer old")
get(app, "/me", "Bearer nope")
get(app, "/open", "")
get(app, "/open", "Bearer good")
get(app, "/soft", "")
get(app, "/soft", "Bearer nope")
get(app, "/soft", "Bearer good")

puts "-- the verifier can't check"
stub.unavailable("down", "cannot fetch the JWKS: down")
get(app, "/me", "Bearer down")

puts "-- the log has the reasons, never the token"
capture.take
get(app, "/me", "")
get(app, "/me", "Bearer old")
get(app, "/me", "Bearer secret-token-value")
get(app, "/me", "Bearer down")
capture.take.each { |line| puts line }

puts "-- the app has no issuer or audience"
ENV["JWT_AUDIENCE"] = ""
get(app, "/me", "Bearer good")
get(app, "/me", "")
ENV["JWT_ISSUER"] = ""
