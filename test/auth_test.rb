require "spinel_test/unit"
require "edgeway"
require_relative "dynamic_dispatch"
require "edgeway/http/auth/stub"

class AuthTest < SpinelTest::Unit::TestCase
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

    def denied(error)
      render json: { "denied" => error.message }, status: :forbidden
    end
  end

  class LogCollector
    attr_reader :lines

    def initialize
      @lines = []
    end

    def info(message, fields = {})
      @lines << "info #{message}#{field_text(fields)}"
    end

    def error(message, fields = {})
      @lines << "error #{message}#{field_text(fields)}"
    end

    def field_text(fields)
      fields.map { |name, value| " #{name}=#{value}" }.join
    end
  end

  NOW = 1_800_000_000
  ISSUER = "https://idp.example/"
  ENVIRONMENT_NAMES = ["JWT_ISSUER", "JWT_AUDIENCE", "JWT_LEEWAY", "HTTP_AUTHORIZATION"]

  LEEWAY_MESSAGE = "jwt: JWT_LEEWAY must be a whole number of seconds, 0 to 300"
  JSON_HEADER = ["Content-Type", "application/json"]
  NOSNIFF_HEADER = ["X-Content-Type-Options", "nosniff"]
  BEARER_HEADER = ["WWW-Authenticate", "Bearer"]
  INVALID_TOKEN_HEADER = ["WWW-Authenticate", "Bearer error=\"invalid_token\""]

  JSON_HEADERS = [JSON_HEADER]
  CHALLENGE_HEADERS = [JSON_HEADER, NOSNIFF_HEADER, BEARER_HEADER]
  INVALID_TOKEN_HEADERS = [JSON_HEADER, NOSNIFF_HEADER, INVALID_TOKEN_HEADER]
  ERROR_HEADERS = [JSON_HEADER, NOSNIFF_HEADER]

  AUTHENTICATION_REQUIRED_BODY = "{\"error\":\"authentication required\"}\n"
  INVALID_TOKEN_BODY = "{\"error\":\"invalid token\"}\n"
  INTERNAL_ERROR_BODY = "{\"error\":\"internal error\"}\n"
  USER_BODY = "{\"sub\":\"u1\",\"authenticated\":true}\n"
  ANONYMOUS_BODY = "{\"authenticated\":false,\"claims\":{}}\n"

  def setup
    @original_verifier = Edgeway::Auth.verifier
    @original_logger = Edgeway.logger
    @original_environment = {}
    ENVIRONMENT_NAMES.each do |name|
      @original_environment[name] = ENV[name]
      ENV.delete(name)
    end
    @stub = Edgeway::Auth::StubVerifier.new
    Edgeway::Auth.verifier = @stub
    @log = LogCollector.new
    Edgeway.logger = @log
    @app = build_app
  end

  def teardown
    ENVIRONMENT_NAMES.each { |name| restore_environment(name) }
    Edgeway.logger = @original_logger
    Edgeway::Auth.verifier = @original_verifier
  end

  def restore_environment(name)
    original = @original_environment[name]
    if original.nil?
      ENV.delete(name)
    else
      ENV[name] = original
    end
  end

  def build_app
    app = Edgeway::Application.new
    app.routes.draw do |mapper|
      mapper.get "/me", to: "auth_test/me#show"
      mapper.get "/open", to: "auth_test/me#open"
      mapper.get "/soft", to: "auth_test/soft#show"
    end
    app
  end

  def decode_token(token, issuer: ISSUER, audience: "api", leeway: 0)
    Edgeway::Auth::JWT.new(@stub, issuer: issuer, audience: audience, leeway: leeway, now: NOW).decode(token)
  end

  def decode_payload(payload, issuer: ISSUER, audience: "api", leeway: 0)
    @stub.allow("a", payload)
    decode_token("a", issuer: issuer, audience: audience, leeway: leeway)
  end

  def assert_accepted(json, payload, leeway: 0)
    assert_equal json, JSON.generate(decode_payload(payload, leeway: leeway))
  end

  def assert_invalid(message, payload, leeway: 0)
    error = assert_raise(Edgeway::InvalidToken) { decode_payload(payload, leeway: leeway) }
    assert_equal message, error.message
  end

  def assert_unavailable(message, payload, issuer: ISSUER, audience: "api")
    error = assert_raise(Edgeway::ConfigurationError) { decode_payload(payload, issuer: issuer, audience: audience) }
    assert_equal message, error.message
  end

  def valid_payload
    { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api" }
  end

  def configure_issuer_and_audience
    ENV["JWT_ISSUER"] = ISSUER
    ENV["JWT_AUDIENCE"] = "api"
  end

  def allow_expiring(token, offset)
    @stub.allow(token, { "sub" => "u1", "exp" => Time.now.to_i + offset, "iss" => ISSUER, "aud" => "api" })
  end

  def assert_leeway_unavailable(text)
    configure_issuer_and_audience
    allow_expiring("e1", -10)
    ENV["JWT_LEEWAY"] = text
    error = assert_raise(Edgeway::ConfigurationError) { Edgeway::Auth.decode("e1") }
    assert_equal LEEWAY_MESSAGE, error.message
  end

  def assert_leeway_argument_unavailable(leeway)
    allow_expiring("e1", -10)
    error = assert_raise(Edgeway::ConfigurationError) { decode_token("e1", leeway: leeway) }
    assert_equal LEEWAY_MESSAGE, error.message
  end

  def prepare_requests
    configure_issuer_and_audience
    ENV["JWT_LEEWAY"] = "5"
    allow_expiring("good", 600)
    allow_expiring("old", -600)
  end

  def get(path, authorization)
    ENV["HTTP_AUTHORIZATION"] = authorization
    @app.call(Edgeway::HTTP::Request.new("GET", path, "", "", ""))
  ensure
    ENV.delete("HTTP_AUTHORIZATION")
  end

  def assert_response(response, status, headers, body)
    assert_equal status, response.status
    assert_equal headers, response.headers.to_a
    assert_equal body, response.body
  end

  def assert_authentication_required(response)
    assert_response response, 401, CHALLENGE_HEADERS, AUTHENTICATION_REQUIRED_BODY
  end

  def assert_invalid_token(response)
    assert_response response, 401, INVALID_TOKEN_HEADERS, INVALID_TOKEN_BODY
  end

  def assert_authenticated_user(response)
    assert_response response, 200, JSON_HEADERS, USER_BODY
  end

  def test_a_genuine_token_is_accepted
    @stub.allow("t1", { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 60 })
    claims = decode_token("t1")
    assert_equal '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":1800000060}', JSON.generate(claims)
  end

  def test_an_unknown_token_is_rejected
    error = assert_raise(Edgeway::InvalidToken) { decode_token("unknown") }
    assert_equal "signature is not valid", error.message
  end

  def test_a_token_the_verifier_rejects_gives_its_reason
    @stub.reject("t2", "algorithm is not allowed")
    error = assert_raise(Edgeway::InvalidToken) { decode_token("t2") }
    assert_equal "algorithm is not allowed", error.message
  end

  def test_a_token_the_verifier_cannot_check_is_unavailable
    @stub.unavailable("t3", "JWT_SECRET is not set")
    error = assert_raise(Edgeway::ConfigurationError) { decode_token("t3") }
    assert_equal "jwt: JWT_SECRET is not set", error.message
  end

  def test_the_base_verifier_is_unavailable
    assert_equal '{"error":"no JWT verifier is set","unavailable":true}', Edgeway::Auth::Verifier.new.verify("x")
  end

  def test_exp_one_second_ahead_is_accepted
    assert_accepted '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":1800000001}',
                    { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 1 }
  end

  def test_exp_at_the_current_time_is_expired
    assert_invalid "token expired", { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW }
  end

  def test_exp_one_second_ago_is_expired
    assert_invalid "token expired", { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW - 1 }
  end

  def test_exp_within_the_leeway_is_accepted
    assert_accepted '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":1799999995}',
                    { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW - 5 }, leeway: 10
  end

  def test_exp_at_the_edge_of_the_leeway_is_expired
    assert_invalid "token expired", { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW - 10 }, leeway: 10
  end

  def test_a_token_without_exp_is_rejected
    assert_invalid "exp is missing", { "sub" => "no exp", "iss" => ISSUER, "aud" => "api" }
  end

  def test_exp_that_is_not_a_number_is_rejected
    assert_invalid "exp is not a number", { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => "soon" }
  end

  def test_a_far_future_exp_is_accepted
    assert_accepted '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":4102444800}',
                    { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => 4_102_444_800 }
  end

  def test_a_float_exp_is_accepted_and_stays_a_float
    assert_accepted '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":1800000060.5}',
                    { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 60.5 }
  end

  def test_nbf_at_the_current_time_is_accepted
    assert_accepted '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":1800000060,"nbf":1800000000}',
                    { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 60, "nbf" => NOW }
  end

  def test_nbf_one_second_ahead_is_not_valid_yet
    assert_invalid "token is not valid yet",
                   { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 60, "nbf" => NOW + 1 }
  end

  def test_nbf_within_the_leeway_is_accepted
    assert_accepted '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":1800000060,"nbf":1800000005}',
                    { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 60, "nbf" => NOW + 5 }, leeway: 5
  end

  def test_nbf_that_is_not_a_number_is_rejected
    assert_invalid "nbf is not a number",
                   { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 60, "nbf" => "x" }
  end

  def test_iat_at_the_current_time_is_accepted
    assert_accepted '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":1800000060,"iat":1800000000}',
                    { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 60, "iat" => NOW }
  end

  def test_iat_one_second_ahead_is_issued_in_the_future
    assert_invalid "token is issued in the future",
                   { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 60, "iat" => NOW + 1 }
  end

  def test_iat_within_the_leeway_is_accepted
    assert_accepted '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":1800000060,"iat":1800000001}',
                    { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW + 60, "iat" => NOW + 1 }, leeway: 1
  end

  def test_the_expected_issuer_is_accepted
    assert_accepted '{"sub":"u1","exp":1800000060,"iss":"https://idp.example/","aud":"api"}', valid_payload
  end

  def test_another_issuer_is_rejected
    assert_invalid "issuer is not accepted",
                   { "sub" => "u1", "exp" => NOW + 60, "iss" => "https://evil.example/", "aud" => "api" }
  end

  def test_a_missing_iss_is_rejected
    assert_invalid "iss is missing", { "sub" => "u1", "exp" => NOW + 60, "aud" => "api" }
  end

  def test_an_iss_that_is_not_a_string_is_rejected
    assert_invalid "issuer is not accepted", { "sub" => "u1", "exp" => NOW + 60, "iss" => 7, "aud" => "api" }
  end

  def test_an_audience_list_containing_the_audience_is_accepted
    assert_accepted '{"sub":"u1","exp":1800000060,"iss":"https://idp.example/","aud":["web","api"]}',
                    { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => ["web", "api"] }
  end

  def test_an_audience_list_without_the_audience_is_rejected
    assert_invalid "audience is not accepted", { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => ["web"] }
  end

  def test_another_audience_is_rejected
    assert_invalid "audience is not accepted", { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "web" }
  end

  def test_a_missing_aud_is_rejected
    assert_invalid "aud is missing", { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER }
  end

  def test_an_aud_that_is_not_a_string_or_list_is_rejected
    assert_invalid "audience is not accepted", { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => 7 }
  end

  def test_a_string_sub_is_accepted
    assert_accepted '{"sub":"u1","exp":1800000060,"iss":"https://idp.example/","aud":"api"}', valid_payload
  end

  def test_a_missing_sub_is_rejected
    assert_invalid "sub is missing", { "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api" }
  end

  def test_an_empty_sub_is_rejected
    assert_invalid "sub is not a non-empty string", { "sub" => "", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api" }
  end

  def test_a_number_sub_is_rejected
    assert_invalid "sub is not a non-empty string", { "sub" => 123, "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api" }
  end

  def test_a_nil_sub_is_rejected
    assert_invalid "sub is not a non-empty string", { "sub" => nil, "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api" }
  end

  def test_a_list_sub_is_rejected
    assert_invalid "sub is not a non-empty string",
                   { "sub" => ["u1"], "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api" }
  end

  def test_a_client_sub_is_accepted
    assert_accepted '{"sub":"abc@clients","exp":1800000060,"iss":"https://idp.example/","aud":"api"}',
                    { "sub" => "abc@clients", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api" }
  end

  def test_auth_time_in_the_past_is_accepted
    assert_accepted '{"sub":"u1","exp":1800000060,"iss":"https://idp.example/","aud":"api","auth_time":1799999900}',
                    { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api", "auth_time" => NOW - 100 }
  end

  def test_auth_time_at_the_current_time_is_accepted
    assert_accepted '{"sub":"u1","exp":1800000060,"iss":"https://idp.example/","aud":"api","auth_time":1800000000}',
                    { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api", "auth_time" => NOW }
  end

  def test_auth_time_one_second_ahead_is_authenticated_in_the_future
    assert_invalid "authenticated in the future",
                   { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api", "auth_time" => NOW + 1 }
  end

  def test_auth_time_within_the_leeway_is_accepted
    assert_accepted '{"sub":"u1","exp":1800000060,"iss":"https://idp.example/","aud":"api","auth_time":1800000001}',
                    { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api", "auth_time" => NOW + 1 },
                    leeway: 1
  end

  def test_auth_time_beyond_the_leeway_is_authenticated_in_the_future
    assert_invalid "authenticated in the future",
                   { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api", "auth_time" => NOW + 2 },
                   leeway: 1
  end

  def test_auth_time_that_is_not_a_number_is_rejected
    assert_invalid "auth_time is not a number",
                   { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api", "auth_time" => "yesterday" }
  end

  def test_a_nil_auth_time_is_rejected
    assert_invalid "auth_time is not a number",
                   { "sub" => "u1", "exp" => NOW + 60, "iss" => ISSUER, "aud" => "api", "auth_time" => nil }
  end

  def test_an_empty_issuer_setting_is_a_misconfiguration
    assert_unavailable "jwt: JWT_ISSUER is not set", valid_payload, issuer: ""
  end

  def test_an_empty_audience_setting_is_a_misconfiguration
    assert_unavailable "jwt: JWT_AUDIENCE is not set", valid_payload, audience: ""
  end

  def test_an_empty_issuer_is_reported_before_an_empty_audience
    assert_unavailable "jwt: JWT_ISSUER is not set", valid_payload, issuer: "", audience: ""
  end

  def test_an_empty_issuer_is_reported_before_the_token_is_looked_at
    error = assert_raise(Edgeway::ConfigurationError) { decode_token("nope", issuer: "") }
    assert_equal "jwt: JWT_ISSUER is not set", error.message
  end

  def test_an_empty_audience_is_reported_before_the_verifier_is_asked
    @stub.unavailable("t3", "JWT_SECRET is not set")
    error = assert_raise(Edgeway::ConfigurationError) { decode_token("t3", audience: "") }
    assert_equal "jwt: JWT_AUDIENCE is not set", error.message
  end

  def test_a_token_that_expires_in_an_hour_is_accepted_with_the_clock
    @stub.allow("c", { "sub" => "u1", "exp" => Time.now.to_i + 3600, "iat" => Time.now.to_i - 5, "iss" => ISSUER, "aud" => "api" })
    claims = Edgeway::Auth::JWT.new(@stub, issuer: ISSUER, audience: "api").decode("c")
    assert_equal true, claims.key?("exp")
    assert_equal "u1", claims["sub"]
  end

  def test_a_token_that_expired_an_hour_ago_is_rejected_with_the_clock
    @stub.allow("old", { "sub" => "u1", "exp" => Time.now.to_i - 3600, "iss" => ISSUER, "aud" => "api" })
    error = assert_raise(Edgeway::InvalidToken) do
      Edgeway::Auth::JWT.new(@stub, issuer: ISSUER, audience: "api").decode("old")
    end
    assert_equal "token expired", error.message
  end

  def test_the_default_leeway_is_5_seconds
    assert_equal 5, Edgeway::Auth::JWT::DEFAULT_LEEWAY
  end

  def test_exp_inside_the_default_leeway_is_accepted
    assert_accepted '{"sub":"u1","iss":"https://idp.example/","aud":"api","exp":1799999996}',
                    { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW - 4 },
                    leeway: Edgeway::Auth::JWT::DEFAULT_LEEWAY
  end

  def test_exp_at_the_edge_of_the_default_leeway_is_expired
    assert_invalid "token expired", { "sub" => "u1", "iss" => ISSUER, "aud" => "api", "exp" => NOW - 5 },
                   leeway: Edgeway::Auth::JWT::DEFAULT_LEEWAY
  end

  def test_the_environment_uses_the_default_leeway_when_none_is_set
    configure_issuer_and_audience
    allow_expiring("d1", -3)
    assert_equal "https://idp.example/", Edgeway::Auth.decode("d1")["iss"]
  end

  def test_the_environment_default_leeway_rejects_an_older_token
    configure_issuer_and_audience
    allow_expiring("d2", -30)
    error = assert_raise(Edgeway::InvalidToken) { Edgeway::Auth.decode("d2") }
    assert_equal "token expired", error.message
  end

  def test_the_environment_default_leeway_rejects_just_past_5_seconds
    configure_issuer_and_audience
    allow_expiring("d3", -6)
    error = assert_raise(Edgeway::InvalidToken) { Edgeway::Auth.decode("d3") }
    assert_equal "token expired", error.message
  end

  def test_the_environment_leeway_tolerates_an_expired_token_within_it
    configure_issuer_and_audience
    ENV["JWT_LEEWAY"] = "30"
    allow_expiring("e1", -10)
    assert_equal "api", Edgeway::Auth.decode("e1")["aud"]
  end

  def test_the_environment_audience_is_enforced
    configure_issuer_and_audience
    ENV["JWT_LEEWAY"] = "30"
    @stub.allow("e2", { "sub" => "u1", "exp" => Time.now.to_i + 60, "iss" => "https://idp.example/", "aud" => "other" })
    error = assert_raise(Edgeway::InvalidToken) { Edgeway::Auth.decode("e2") }
    assert_equal "audience is not accepted", error.message
  end

  def test_jwt_leeway_300_is_accepted
    configure_issuer_and_audience
    allow_expiring("e1", -10)
    ENV["JWT_LEEWAY"] = "300"
    assert_equal "u1", Edgeway::Auth.decode("e1")["sub"]
  end

  def test_jwt_leeway_0_rejects_an_expired_token
    configure_issuer_and_audience
    allow_expiring("e1", -10)
    ENV["JWT_LEEWAY"] = "0"
    error = assert_raise(Edgeway::InvalidToken) { Edgeway::Auth.decode("e1") }
    assert_equal "token expired", error.message
  end

  def test_jwt_leeway_300_is_honoured_not_clamped
    configure_issuer_and_audience
    allow_expiring("e1", -200)
    ENV["JWT_LEEWAY"] = "300"
    assert_equal "u1", Edgeway::Auth.decode("e1")["sub"]
  end

  def test_jwt_leeway_0_rejects_a_token_inside_the_default_leeway
    configure_issuer_and_audience
    allow_expiring("e1", -3)
    ENV["JWT_LEEWAY"] = "0"
    error = assert_raise(Edgeway::InvalidToken) { Edgeway::Auth.decode("e1") }
    assert_equal "token expired", error.message
  end

  def test_jwt_leeway_301_is_unavailable
    assert_leeway_unavailable "301"
  end

  def test_jwt_leeway_minus_1_is_unavailable
    assert_leeway_unavailable "-1"
  end

  def test_jwt_leeway_abc_is_unavailable
    assert_leeway_unavailable "abc"
  end

  def test_jwt_leeway_5_point_5_is_unavailable
    assert_leeway_unavailable "5.5"
  end

  def test_jwt_leeway_1e2_is_unavailable
    assert_leeway_unavailable "1e2"
  end

  def test_jwt_leeway_99999999999_is_unavailable
    assert_leeway_unavailable "99999999999"
  end

  def test_a_negative_leeway_argument_is_unavailable
    assert_leeway_argument_unavailable(-1)
  end

  def test_a_leeway_argument_above_the_maximum_is_unavailable
    assert_leeway_argument_unavailable 301
  end

  def test_a_float_leeway_argument_is_unavailable
    assert_leeway_argument_unavailable 1.5
  end

  def test_an_empty_audience_setting_is_unavailable_from_the_environment
    ENV["JWT_ISSUER"] = ISSUER
    ENV["JWT_AUDIENCE"] = ""
    ENV["JWT_LEEWAY"] = "30"
    allow_expiring("e1", -10)
    error = assert_raise(Edgeway::ConfigurationError) { Edgeway::Auth.decode("e1") }
    assert_equal "jwt: JWT_AUDIENCE is not set", error.message
  end

  def test_an_empty_issuer_setting_is_unavailable_from_the_environment
    ENV["JWT_ISSUER"] = ""
    ENV["JWT_AUDIENCE"] = ""
    ENV["JWT_LEEWAY"] = "30"
    allow_expiring("e1", -10)
    error = assert_raise(Edgeway::ConfigurationError) { Edgeway::Auth.decode("e1") }
    assert_equal "jwt: JWT_ISSUER is not set", error.message
  end

  def test_invalid_token_is_an_unauthorized_error
    chain = Edgeway::InvalidToken.ancestors.take_while { |klass| klass != Exception }.join(" < ")
    assert_equal "Edgeway::InvalidToken < Edgeway::Unauthorized < Edgeway::Error < StandardError", chain
  end

  def test_a_request_with_an_empty_header_is_challenged
    prepare_requests
    assert_authentication_required get("/me", "")
  end

  def test_a_bearer_token_authenticates
    prepare_requests
    assert_authenticated_user get("/me", "Bearer good")
    assert_equal [], @log.lines
  end

  def test_the_bearer_scheme_is_case_insensitive
    prepare_requests
    assert_authenticated_user get("/me", "bearer good")
  end

  def test_whitespace_around_the_token_is_ignored
    prepare_requests
    assert_authenticated_user get("/me", "Bearer   good  ")
  end

  def test_a_bearer_scheme_without_a_token_is_challenged
    prepare_requests
    assert_authentication_required get("/me", "Bearer")
  end

  def test_a_bearer_scheme_with_a_blank_token_is_challenged
    prepare_requests
    assert_authentication_required get("/me", "Bearer ")
  end

  def test_another_scheme_is_challenged
    prepare_requests
    assert_authentication_required get("/me", "Basic Zm9vOmJhcg==")
    assert_equal ["info authentication required status=401"], @log.lines
  end

  def test_an_expired_token_is_an_invalid_token
    prepare_requests
    assert_invalid_token get("/me", "Bearer old")
  end

  def test_an_unknown_token_is_an_invalid_token
    prepare_requests
    assert_invalid_token get("/me", "Bearer nope")
  end

  def test_an_open_action_with_an_empty_header_is_anonymous
    prepare_requests
    assert_response get("/open", ""), 200, JSON_HEADERS, ANONYMOUS_BODY
  end

  def test_an_open_action_ignores_a_token
    prepare_requests
    assert_response get("/open", "Bearer good"), 200, JSON_HEADERS, ANONYMOUS_BODY
  end

  def test_a_rescued_action_denies_an_empty_header
    prepare_requests
    assert_response get("/soft", ""), 403, JSON_HEADERS, "{\"denied\":\"authentication required\"}\n"
  end

  def test_a_rescued_action_denies_an_unknown_token
    prepare_requests
    assert_response get("/soft", "Bearer nope"), 403, JSON_HEADERS, "{\"denied\":\"signature is not valid\"}\n"
  end

  def test_a_rescued_action_accepts_a_good_token
    prepare_requests
    assert_response get("/soft", "Bearer good"), 200, JSON_HEADERS, "{\"ok\":true}\n"
  end

  def test_a_success_does_not_carry_over_to_the_next_request
    prepare_requests
    assert_authenticated_user get("/me", "Bearer good")
    assert_authentication_required get("/me", "")
    assert_invalid_token get("/me", "Bearer nope")
    assert_response get("/soft", "Bearer good"), 200, JSON_HEADERS, "{\"ok\":true}\n"
    assert_response get("/soft", ""), 403, JSON_HEADERS, "{\"denied\":\"authentication required\"}\n"
  end

  def test_a_verifier_that_cannot_check_is_a_500
    prepare_requests
    @stub.unavailable("down", "cannot fetch the JWKS: down")
    assert_response get("/me", "Bearer down"), 500, ERROR_HEADERS, INTERNAL_ERROR_BODY
    assert_equal ["error Edgeway::ConfigurationError: jwt: cannot fetch the JWKS: down status=500"], @log.lines
  end

  def test_the_log_has_the_reasons_and_never_the_token
    prepare_requests
    @stub.unavailable("down", "cannot fetch the JWKS: down")
    assert_authentication_required get("/me", "")
    assert_invalid_token get("/me", "Bearer old")
    assert_invalid_token get("/me", "Bearer secret-token-value")
    assert_response get("/me", "Bearer down"), 500, ERROR_HEADERS, INTERNAL_ERROR_BODY
    expected = ["info authentication required status=401",
                "info token expired status=401",
                "info signature is not valid status=401",
                "error Edgeway::ConfigurationError: jwt: cannot fetch the JWKS: down status=500"]
    assert_equal expected, @log.lines
    @log.lines.each { |line| refute line.include?("secret-token-value") }
  end

  def test_an_app_without_an_audience_is_a_500_for_a_token
    prepare_requests
    ENV["JWT_AUDIENCE"] = ""
    assert_response get("/me", "Bearer good"), 500, ERROR_HEADERS, INTERNAL_ERROR_BODY
    assert_equal ["error Edgeway::ConfigurationError: jwt: JWT_AUDIENCE is not set status=500"], @log.lines
  end

  def test_an_app_without_an_audience_still_challenges_an_empty_header
    prepare_requests
    ENV["JWT_AUDIENCE"] = ""
    assert_authentication_required get("/me", "")
    assert_equal ["info authentication required status=401"], @log.lines
  end
end
