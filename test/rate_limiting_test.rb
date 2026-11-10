require "spinel_test/unit"
require "edgeway"
require "edgeway/http/auth/stub"
require "edgeway/rate_limit/stub_limiter"
require "edgeway/service/cloudflare/rate_limiter"

class RateLimitingTest < SpinelTest::Unit::TestCase
  class LogCollector < Edgeway::Logger
    attr_reader :lines

    def initialize
      @lines = []
    end

    def warn(message, fields = {})
      @lines << "warn #{message} #{JSON.generate(fields)}"
    end

    def info(message, fields = {})
      @lines << "info #{message} #{JSON.generate(fields)}"
    end

    def error(message, fields = {})
      @lines << "error #{message} #{JSON.generate(fields)}"
    end
  end

  class FakeTransport < Edgeway::Cloudflare::RateLimitTransport
    attr_reader :calls

    def initialize(answer)
      @answer = answer
      @calls = []
    end

    def check(binding_name, key)
      @calls << "#{binding_name} #{key}"
      @answer
    end
  end

  class ApplicationController < Edgeway::Controller::Base
    private

    def rate_limit_key = "tenant-#{request.header("X-Tenant")}"
  end

  class PostsController < ApplicationController
    rate_limit "WRITE_LIMITER", only: [:create]

    def index = render(json: { "ok" => "index" })

    def create
      Edgeway.logger.info("create ran")
      render json: { "ok" => "create" }
    end
  end

  class ReportsController < ApplicationController
    rate_limit "READ_LIMITER", by: :rate_limit_key, retry_after: 30, except: [:show]
    rate_limit "BURST_LIMITER", name: "reports", retry_after: 5

    def index
      Edgeway.logger.info("index ran")
      render json: { "ok" => "index" }
    end

    def show = render(json: { "ok" => "show" })
  end

  class ArchivesController < ReportsController
    def index = render(json: { "ok" => "archive" })
  end

  class AccountsController < ApplicationController
    before_action :authenticate!
    rate_limit "ACCOUNT_LIMITER"

    def show = render(json: { "ok" => "show" })
  end

  class CustomController < ApplicationController
    rate_limit "CUSTOM_LIMITER", retry_after: 9

    rescue_from Edgeway::TooManyRequests, with: :slow_down

    def index = render(json: { "ok" => "index" })

    def slow_down(error)
      render json: { "slow" => error.retry_after }, status: 503
    end
  end

  class HaltedController < ApplicationController
    before_action :refuse
    rate_limit "HALTED_LIMITER"

    def index = render(json: { "ok" => "index" })

    private

    def refuse = render(json: { "refused" => true }, status: 403)
  end

  class ChildAuthController < PostsController
    before_action :authenticate!

    def index = render(json: { "ok" => "child" })
  end

  class AccountKeyController < ApplicationController
    rate_limit "ACCOUNT_KEY_LIMITER", by: :account_id
    rate_limit "NOTHING_LIMITER", by: :nothing

    def index = render(json: { "ok" => "index" })

    private

    def account_id = 42
    def nothing = nil
  end

  class PublicByController < ApplicationController
    rate_limit "PUBLIC_BY_LIMITER", by: :tenant_key

    def index = render(json: { "ok" => "index" })
    def tenant_key = "t1"
  end

  class PublicByChildController < PublicByController
  end

  class OpenController < ApplicationController
    def index = render(json: { "ok" => "open" })
  end

  class MacroTargetController < ApplicationController
  end

  ENVIRONMENT_NAMES = ["JWT_ISSUER", "JWT_AUDIENCE", "REMOTE_ADDR", "HTTP_X_TENANT", "HTTP_AUTHORIZATION"]

  ISSUER = "https://idp.example/"
  CLIENT_ADDRESS = "203.0.113.7"
  KEY_DIGEST = "abc3a47b8ad18b855c687d9ca2c6091ee7312db5563021942a57ada889c87b34"

  JSON_HEADER = ["Content-Type", "application/json"]
  NOSNIFF_HEADER = ["X-Content-Type-Options", "nosniff"]
  JSON_HEADERS = [JSON_HEADER]
  ERROR_HEADERS = [JSON_HEADER, NOSNIFF_HEADER]
  CHALLENGE_HEADERS = [JSON_HEADER, NOSNIFF_HEADER, ["WWW-Authenticate", "Bearer"]]

  RATE_LIMIT_EXCEEDED_BODY = "{\"error\":\"rate limit exceeded\"}\n"
  AUTHENTICATION_REQUIRED_BODY = "{\"error\":\"authentication required\"}\n"
  NOT_FOUND_BODY = "{\"error\":\"not found\"}\n"
  INDEX_BODY = "{\"ok\":\"index\"}\n"
  CREATE_BODY = "{\"ok\":\"create\"}\n"
  SHOW_BODY = "{\"ok\":\"show\"}\n"

  WRITE_KEY = "RateLimitingTest::PostsController:ip:#{CLIENT_ADDRESS}"
  READ_KEY = "RateLimitingTest::ReportsController:tenant-t1"
  BURST_KEY = "reports:ip:#{CLIENT_ADDRESS}"
  UNAUTHORIZED_LOG = "info authentication required {\"status\":401}"
  EXCEEDED_WRITE_LOG = "info rate limit exceeded (WRITE_LIMITER) {\"status\":429}"

  def setup
    @original_verifier = Edgeway::Auth.verifier
    @original_logger = Edgeway.logger
    @original_rate_limiter = Edgeway::Controller.rate_limiter
    @original_environment = {}
    ENVIRONMENT_NAMES.each do |name|
      @original_environment[name] = ENV[name]
      ENV.delete(name)
    end
    @verifier = Edgeway::Auth::StubVerifier.new
    Edgeway::Auth.verifier = @verifier
    @limiter = Edgeway::RateLimit::StubLimiter.new
    Edgeway::Controller.rate_limiter = @limiter
    @log = LogCollector.new
    Edgeway.logger = @log
    @app = build_app
  end

  def teardown
    ENVIRONMENT_NAMES.each { |name| restore_environment(name) }
    Edgeway.logger = @original_logger
    Edgeway::Controller.rate_limiter = @original_rate_limiter
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
      mapper.get "/posts", to: "rate_limiting_test/posts#index"
      mapper.post "/posts", to: "rate_limiting_test/posts#create"
      mapper.get "/reports", to: "rate_limiting_test/reports#index"
      mapper.get "/reports/1", to: "rate_limiting_test/reports#show"
      mapper.get "/archives", to: "rate_limiting_test/archives#index"
      mapper.get "/account", to: "rate_limiting_test/accounts#show"
      mapper.get "/custom", to: "rate_limiting_test/custom#index"
      mapper.get "/open", to: "rate_limiting_test/open#index"
      mapper.get "/public_by", to: "rate_limiting_test/public_by#index"
      mapper.get "/public_by/tenant_key", to: "rate_limiting_test/public_by#tenant_key"
      mapper.get "/public_by_child/tenant_key", to: "rate_limiting_test/public_by_child#tenant_key"
      mapper.get "/halted", to: "rate_limiting_test/halted#index"
      mapper.get "/child", to: "rate_limiting_test/child_auth#index"
      mapper.post "/child", to: "rate_limiting_test/child_auth#create"
      mapper.get "/account_key", to: "rate_limiting_test/account_key#index"
    end
    app
  end

  def environment_name(header)
    "HTTP_" + header.upcase.gsub("-", "_")
  end

  def request(verb, path, headers = {})
    headers.each { |name, value| ENV[environment_name(name)] = value }
    @app.call(Edgeway::HTTP::Request.new(verb, path, "", "", ""))
  ensure
    headers.each { |name, _value| ENV.delete(environment_name(name)) }
  end

  def use_client_address(address = CLIENT_ADDRESS)
    ENV["REMOTE_ADDR"] = address
  end

  def allow_good_token
    ENV["JWT_ISSUER"] = ISSUER
    ENV["JWT_AUDIENCE"] = "api"
    @verifier.allow("good", { "sub" => "u1", "exp" => Time.now.to_i + 600, "iss" => ISSUER, "aud" => "api" })
  end

  def bearer_good = { "Authorization" => "Bearer good" }

  def tenant_one = { "X-Tenant" => "t1" }

  def assert_response(response, status, headers, body)
    assert_equal status, response.status
    assert_equal headers, response.headers.to_a
    assert_equal body, response.body
  end

  def assert_address_key(expected, address)
    assert_equal expected, Edgeway::Controller::RateLimiting.address_key(address)
  end

  def assert_retry_after(expected, value)
    assert_equal expected, Edgeway::TooManyRequests.new("slow", value).retry_after
  end

  def assert_rate_limit_rejected(message, &block)
    error = assert_raise(ArgumentError, &block)
    assert_equal message, error.message
  end

  def checks = @limiter.checks

  def test_the_null_limiter_lets_every_request_through
    Edgeway::Controller.rate_limiter = Edgeway::RateLimit::NullLimiter.new
    assert_response request("GET", "/open"), 200, JSON_HEADERS, "{\"ok\":\"open\"}\n"
    assert_response request("POST", "/posts"), 200, JSON_HEADERS, CREATE_BODY
    assert_equal ["info create ran {}"], @log.lines
  end

  def test_the_default_limiter_is_the_null_limiter
    assert_equal true, @original_rate_limiter.is_a?(Edgeway::RateLimit::NullLimiter)
  end

  def test_only_checks_the_limiter_for_a_listed_action
    use_client_address
    assert_response request("POST", "/posts"), 200, JSON_HEADERS, CREATE_BODY
    assert_equal [["WRITE_LIMITER", WRITE_KEY]], checks
    assert_equal ["info create ran {}"], @log.lines
  end

  def test_by_picks_the_key_and_name_replaces_the_controller_name
    use_client_address
    assert_response request("GET", "/reports", tenant_one), 200, JSON_HEADERS, INDEX_BODY
    assert_equal [["READ_LIMITER", READ_KEY], ["BURST_LIMITER", BURST_KEY]], checks
    assert_equal ["info index ran {}"], @log.lines
  end

  def test_the_key_of_a_subclass_uses_the_subclass_name
    use_client_address
    assert_response request("GET", "/archives", tenant_one), 200, JSON_HEADERS, "{\"ok\":\"archive\"}\n"
    assert_equal [["READ_LIMITER", "RateLimitingTest::ArchivesController:tenant-t1"], ["BURST_LIMITER", BURST_KEY]], checks
  end

  def test_the_default_key_of_an_authenticated_request_is_the_subject
    allow_good_token
    assert_response request("GET", "/account", bearer_good), 200, JSON_HEADERS, SHOW_BODY
    assert_equal [["ACCOUNT_LIMITER", "RateLimitingTest::AccountsController:user:u1"]], checks
  end

  def test_an_unauthenticated_request_is_refused_before_the_limiter
    assert_response request("GET", "/account"), 401, CHALLENGE_HEADERS, AUTHENTICATION_REQUIRED_BODY
    assert_equal [], checks
    assert_equal [UNAUTHORIZED_LOG], @log.lines
  end

  def test_an_empty_client_address_gives_an_empty_ip
    use_client_address("")
    assert_response request("POST", "/posts"), 200, JSON_HEADERS, CREATE_BODY
    assert_equal [["WRITE_LIMITER", "RateLimitingTest::PostsController:ip:"]], checks
  end

  def test_an_unset_client_address_gives_an_empty_ip
    assert_response request("POST", "/posts"), 200, JSON_HEADERS, CREATE_BODY
    assert_equal [["WRITE_LIMITER", "RateLimitingTest::PostsController:ip:"]], checks
  end

  def test_by_answering_an_integer_or_nil_is_keyed_by_its_text
    assert_response request("GET", "/account_key"), 200, JSON_HEADERS, INDEX_BODY
    assert_equal [["ACCOUNT_KEY_LIMITER", "RateLimitingTest::AccountKeyController:42"],
                  ["NOTHING_LIMITER", "RateLimitingTest::AccountKeyController:"]], checks
  end

  def test_a_before_action_that_renders_halts_before_the_limiter
    assert_response request("GET", "/halted"), 403, JSON_HEADERS, "{\"refused\":true}\n"
    assert_equal [], checks
  end

  def test_a_child_without_a_token_is_unauthorized_and_the_inherited_only_skips_the_limiter
    assert_response request("GET", "/child"), 401, CHALLENGE_HEADERS, AUTHENTICATION_REQUIRED_BODY
    assert_equal [], checks
    assert_equal [UNAUTHORIZED_LOG], @log.lines
  end

  def test_a_child_with_a_token_is_served_and_the_inherited_only_skips_the_limiter
    allow_good_token
    assert_response request("GET", "/child", bearer_good), 200, JSON_HEADERS, "{\"ok\":\"child\"}\n"
    assert_equal [], checks
    assert_equal [], @log.lines
  end

  def test_the_parents_rate_limit_runs_before_the_childs_authenticate
    use_client_address
    @limiter.stub("WRITE_LIMITER", true)
    assert_response request("POST", "/child"), 429, ERROR_HEADERS, RATE_LIMIT_EXCEEDED_BODY
    assert_equal [["WRITE_LIMITER", "RateLimitingTest::ChildAuthController:ip:#{CLIENT_ADDRESS}"]], checks
    assert_equal [EXCEEDED_WRITE_LOG], @log.lines
  end

  def test_an_ipv6_client_is_keyed_by_its_64_prefix
    use_client_address("2001:db8:1:2:ffff:ffff:ffff:ffff")
    assert_response request("POST", "/posts"), 200, JSON_HEADERS, CREATE_BODY
    assert_equal [["WRITE_LIMITER", "RateLimitingTest::PostsController:ip:2001:db8:1:2::/64"]], checks
  end

  def test_ipv6_addresses_are_cut_to_their_64_prefix
    assert_address_key "2001:db8:1:2::/64", "2001:db8:1:2:aaaa:bbbb:cccc:dddd"
    assert_address_key "2001:db8:1:2::/64", "2001:0DB8:0001:0002::1"
    assert_address_key "2001:db8:1:2::/64", "2001:db8:1:2::"
    assert_address_key "0:0:0:0::/64", "::1"
    assert_address_key "0:0:0:0::/64", "::"
    assert_address_key "1:0:0:0::/64", "1::"
    assert_address_key "fe80:0:0:0::/64", "fe80::1%eth0"
    assert_address_key "2001:db8:0:0::/64", "2001:db8::1:2:3"
    assert_address_key "1:2:3:4::/64", "1:2:3:4:5:6:7:8"
    assert_address_key "1:2:3:4::/64", "1:2:3:4:5:6:7::"
    assert_address_key "64:ff9b:0:0::/64", "64:ff9b::192.0.2.1"
  end

  def test_ipv4_mapped_ipv6_addresses_are_keyed_as_ipv4
    assert_address_key "192.0.2.1", "::ffff:192.0.2.1"
    assert_address_key "192.0.2.1", "::ffff:c000:201"
    assert_address_key "192.0.2.1", "0:0:0:0:0:ffff:192.0.2.1"
    assert_address_key "192.0.2.1", "0000:0000:0000:0000:0000:FFFF:C000:0201"
    assert_address_key "192.0.2.1", "::FFFF:192.000.002.001"
  end

  def test_addresses_that_are_not_ipv4_mapped_keep_the_prefix_key
    assert_address_key "0:0:0:0::/64", "::fffe:192.0.2.1"
    assert_address_key "1:0:0:0::/64", "1::ffff:c000:201"
    assert_address_key "0:0:0:0::/64", "::1:ffff:c000:201"
  end

  def test_addresses_that_do_not_parse_are_kept_as_they_are
    assert_address_key "::ffff:192.0.2", "::ffff:192.0.2"
    assert_address_key "::ffff:192.0.2.256", "::ffff:192.0.2.256"
    assert_address_key "1:2:3:4:5:6:7", "1:2:3:4:5:6:7"
    assert_address_key "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8:9"
    assert_address_key "1::2::3", "1::2::3"
    assert_address_key "12345::1", "12345::1"
    assert_address_key "g::1", "g::1"
    assert_address_key "not-an-address:", "not-an-address:"
    assert_address_key "1:2:3:4:5:6:7:8::", "1:2:3:4:5:6:7:8::"
    assert_address_key "1:2:3:4:5:6:7:", "1:2:3:4:5:6:7:"
    assert_address_key "::ffff:0192.0.2.1", "::ffff:0192.0.2.1"
    assert_address_key "::ffff:.0.2.1", "::ffff:.0.2.1"
  end

  def test_an_ipv4_address_is_kept_as_it_is
    assert_address_key "198.51.100.9", "198.51.100.9"
  end

  def test_the_client_address_is_empty_when_the_platform_reports_none
    assert_equal "", Edgeway::HTTP::Request.new("GET", "/", "", "", "").remote_addr
  end

  def test_the_client_address_is_the_one_the_platform_reports
    use_client_address("198.51.100.4")
    assert_equal "198.51.100.4", Edgeway::HTTP::Request.new("GET", "/", "", "", "").remote_addr
  end

  def test_an_exceeded_limiter_answers_429_and_logs_without_the_key
    use_client_address
    @limiter.stub("WRITE_LIMITER", true)
    assert_response request("POST", "/posts"), 429, ERROR_HEADERS, RATE_LIMIT_EXCEEDED_BODY
    assert_equal [["WRITE_LIMITER", WRITE_KEY]], checks
    assert_equal [EXCEEDED_WRITE_LOG], @log.lines
  end

  def test_an_exceeded_limiter_is_not_checked_for_an_action_outside_only
    @limiter.stub("WRITE_LIMITER", true)
    assert_response request("GET", "/posts"), 200, JSON_HEADERS, INDEX_BODY
    assert_equal [], checks
    assert_equal [], @log.lines
  end

  def test_a_request_is_served_again_when_the_limiter_allows_it_after_a_429
    use_client_address
    assert_response request("POST", "/posts"), 200, JSON_HEADERS, CREATE_BODY
    @limiter.stub("WRITE_LIMITER", true)
    assert_response request("POST", "/posts"), 429, ERROR_HEADERS, RATE_LIMIT_EXCEEDED_BODY
    @limiter.stub("WRITE_LIMITER", false)
    assert_response request("POST", "/posts"), 200, JSON_HEADERS, CREATE_BODY
    assert_equal [["WRITE_LIMITER", WRITE_KEY], ["WRITE_LIMITER", WRITE_KEY], ["WRITE_LIMITER", WRITE_KEY]], checks
    assert_equal ["info create ran {}", EXCEEDED_WRITE_LOG, "info create ran {}"], @log.lines
  end

  def test_an_exceeded_first_limiter_answers_429_with_its_retry_after_and_skips_the_second
    use_client_address
    @limiter.stub("READ_LIMITER", true)
    assert_response request("GET", "/reports", tenant_one), 429, [JSON_HEADER, NOSNIFF_HEADER, ["Retry-After", "30"]], RATE_LIMIT_EXCEEDED_BODY
    assert_equal [["READ_LIMITER", READ_KEY]], checks
    assert_equal ["info rate limit exceeded (READ_LIMITER) {\"status\":429}"], @log.lines
  end

  def test_an_exceeded_limiter_is_not_checked_for_an_action_listed_in_except
    use_client_address
    @limiter.stub("READ_LIMITER", true)
    assert_response request("GET", "/reports/1"), 200, JSON_HEADERS, SHOW_BODY
    assert_equal [["BURST_LIMITER", BURST_KEY]], checks
    assert_equal [], @log.lines
  end

  def test_an_exceeded_second_limiter_answers_429_with_its_retry_after
    use_client_address
    @limiter.stub("BURST_LIMITER", true)
    assert_response request("GET", "/reports", tenant_one), 429, [JSON_HEADER, NOSNIFF_HEADER, ["Retry-After", "5"]], RATE_LIMIT_EXCEEDED_BODY
    assert_equal [["READ_LIMITER", READ_KEY], ["BURST_LIMITER", BURST_KEY]], checks
    assert_equal ["info rate limit exceeded (BURST_LIMITER) {\"status\":429}"], @log.lines
  end

  def test_rescue_from_handles_too_many_requests_with_the_retry_after
    use_client_address
    @limiter.stub("CUSTOM_LIMITER", true)
    assert_response request("GET", "/custom"), 503, JSON_HEADERS, "{\"slow\":9}\n"
    assert_equal [["CUSTOM_LIMITER", "RateLimitingTest::CustomController:ip:#{CLIENT_ADDRESS}"]], checks
    assert_equal [], @log.lines
  end

  def test_a_public_by_method_still_gives_the_key
    assert_response request("GET", "/public_by"), 200, JSON_HEADERS, INDEX_BODY
    assert_equal [["PUBLIC_BY_LIMITER", "RateLimitingTest::PublicByController:t1"]], checks
  end

  def test_a_by_method_is_not_a_routable_action
    assert_response request("GET", "/public_by/tenant_key"), 404, ERROR_HEADERS, NOT_FOUND_BODY
    assert_equal [], checks
    assert_equal ["info no route for GET /public_by/tenant_key {\"status\":404}"], @log.lines
  end

  def test_a_by_method_of_a_parent_is_not_a_routable_action_of_the_child
    assert_response request("GET", "/public_by_child/tenant_key"), 404, ERROR_HEADERS, NOT_FOUND_BODY
    assert_equal [], checks
    assert_equal ["info no route for GET /public_by_child/tenant_key {\"status\":404}"], @log.lines
  end

  def test_a_by_method_is_not_an_action_but_other_public_methods_are
    bare_request = Edgeway::HTTP::Request.new("GET", "/", "", "", "")
    assert_equal false, PublicByController.new(bare_request).action?("tenant_key")
    assert_equal false, PublicByChildController.new(bare_request).action?("tenant_key")
    assert_equal true, PublicByController.new(bare_request).action?("index")
    assert_equal false, PostsController.new(bare_request).action?("tenant_key")
  end

  def test_retry_after_defaults_to_zero
    assert_equal 0, Edgeway::TooManyRequests.new.retry_after
    assert_retry_after 0, nil
  end

  def test_retry_after_keeps_a_positive_integer
    assert_retry_after 7, 7
  end

  def test_retry_after_is_zero_for_a_string_a_negative_number_or_a_float
    assert_retry_after 0, "10"
    assert_retry_after 0, -1
    assert_retry_after 0, 1.5
  end

  def test_the_default_response_to_too_many_requests_is_429
    assert_equal 429, @app.rescue_default(Edgeway::TooManyRequests.new("slow", nil)).status
  end

  def test_rate_limit_rejects_a_binding_name_that_is_not_a_string
    assert_rate_limit_rejected("the limiter binding name must be a non-empty String") { MacroTargetController.rate_limit(:WRITE_LIMITER) }
  end

  def test_rate_limit_rejects_an_empty_binding_name
    assert_rate_limit_rejected("the limiter binding name must be a non-empty String") { MacroTargetController.rate_limit("") }
  end

  def test_rate_limit_rejects_a_by_that_is_not_a_symbol
    assert_rate_limit_rejected("by: must be a Symbol") { MacroTargetController.rate_limit("A", by: "key") }
  end

  def test_rate_limit_rejects_a_name_that_is_not_a_string
    assert_rate_limit_rejected("name: must be a String") { MacroTargetController.rate_limit("A", name: :scope) }
  end

  def test_rate_limit_rejects_a_zero_retry_after
    assert_rate_limit_rejected("retry_after: must be a positive Integer") { MacroTargetController.rate_limit("A", retry_after: 0) }
  end

  def test_rate_limit_rejects_a_negative_retry_after
    assert_rate_limit_rejected("retry_after: must be a positive Integer") { MacroTargetController.rate_limit("A", retry_after: -1) }
  end

  def test_rate_limit_rejects_a_float_retry_after
    assert_rate_limit_rejected("retry_after: must be a positive Integer") { MacroTargetController.rate_limit("A", retry_after: 1.5) }
  end

  def test_rate_limit_rejects_a_string_retry_after
    assert_rate_limit_rejected("retry_after: must be a positive Integer") { MacroTargetController.rate_limit("A", retry_after: "5") }
  end

  def test_the_base_limiter_does_not_check_limits
    error = assert_raise(Edgeway::Error) { Edgeway::RateLimit::Limiter.new.exceeded?("A", "k") }
    assert_equal "Edgeway::RateLimit::Limiter does not check limits", error.message
  end

  def test_the_stub_limiter_records_every_check_and_answers_by_binding
    stub = Edgeway::RateLimit::StubLimiter.new
    assert_equal false, stub.exceeded?("A", "k")
    stub.stub("A", true)
    assert_equal true, stub.exceeded?("A", "k")
    assert_equal false, stub.exceeded?("B", "k")
    stub.stub("A", false)
    assert_equal false, stub.exceeded?("A", "k")
    assert_equal 4, stub.checks.length
  end

  def ask_transport(answer)
    transport = FakeTransport.new(answer)
    limiter = Edgeway::Cloudflare::RateLimiter.new(transport: transport)
    exceeded = limiter.exceeded?("API_LIMITER", "user:1")
    [exceeded, transport.calls]
  end

  def test_a_successful_answer_is_not_exceeded
    exceeded, calls = ask_transport("{\"success\":true}")
    assert_equal false, exceeded
    assert_equal ["API_LIMITER #{KEY_DIGEST}"], calls
    assert_equal [], @log.lines
  end

  def test_an_unsuccessful_answer_is_exceeded
    exceeded, calls = ask_transport("{\"success\":false}")
    assert_equal true, exceeded
    assert_equal ["API_LIMITER #{KEY_DIGEST}"], calls
    assert_equal [], @log.lines
  end

  def test_an_error_answer_fails_open_and_logs_a_warning
    exceeded, calls = ask_transport("{\"error\":\"invalid key: 1\"}")
    assert_equal false, exceeded
    assert_equal ["API_LIMITER #{KEY_DIGEST}"], calls
    assert_equal ["warn rate limit check failed {\"binding\":\"API_LIMITER\",\"error\":\"invalid key: 1\"}"], @log.lines
  end

  def test_an_empty_answer_is_not_exceeded
    exceeded, calls = ask_transport("{}")
    assert_equal false, exceeded
    assert_equal ["API_LIMITER #{KEY_DIGEST}"], calls
    assert_equal [], @log.lines
  end

  def test_a_misconfigured_answer_raises_a_configuration_error
    error = assert_raise(Edgeway::ConfigurationError) { ask_transport("{\"misconfigured\":\"no rate limit binding API_LIMITER\"}") }
    assert_equal "rate limit: no rate limit binding API_LIMITER", error.message
    assert_equal [], @log.lines
  end

  def test_a_misconfigured_answer_wins_over_an_error_answer
    error = assert_raise(Edgeway::ConfigurationError) { ask_transport("{\"misconfigured\":\"m\",\"error\":\"e\"}") }
    assert_equal "rate limit: m", error.message
    assert_equal [], @log.lines
  end

  def test_a_configuration_error_is_a_500_that_logs_the_reason
    response = @app.rescue_default(Edgeway::ConfigurationError.new("rate limit: no rate limit binding API_LIMITER"))
    assert_response response, 500, ERROR_HEADERS, "{\"error\":\"internal error\"}\n"
    assert_equal ["error Edgeway::ConfigurationError: rate limit: no rate limit binding API_LIMITER {\"status\":500}"], @log.lines
  end

  def digest_keys(keys)
    transport = FakeTransport.new("{\"success\":true}")
    limiter = Edgeway::Cloudflare::RateLimiter.new(transport: transport)
    keys.each { |key| limiter.exceeded?("API_LIMITER", key) }
    transport.calls.map { |call| call.split(" ")[1].to_s }
  end

  def test_the_binding_gets_a_sha256_digest_of_each_key
    invalid_one = "key".b + [0xff].pack("C")
    invalid_two = "key".b + [0xfe].pack("C")
    digests = digest_keys(["user:1", invalid_one, invalid_two, "abc\0x1", "abc\0x2", "日本"])
    assert_equal [KEY_DIGEST,
                  "925639ec1d0198e115910095fe1939e96668a0975040dba17fab18954f9e92f9",
                  "59434f4a2e4677e45c56e658be9a313961d31d866a3ad459238df9d00cd73fe5",
                  "57bcbaee2a55738b51b4c82f954772e020a06da820902ee8aafb28b2540e49bd",
                  "af65b9d79e5b05c4ebf725318dae0bd55c7f14fcebdb490fe1151f573a9513ee",
                  "cf2abf0c5be326cb922a70f8163f91079c4d9aa8655c60ead89ad545c9de2e92"], digests
    assert_equal [64], digests.map { |digest| digest.length }.uniq
    assert_equal 6, digests.uniq.length
    assert_equal Digest::SHA256.hexdigest("user:1"), digests[0]
    assert_equal [], @log.lines
  end

  def test_the_base_transport_does_not_check
    error = assert_raise(Edgeway::Error) { Edgeway::Cloudflare::RateLimitTransport.new.check("A", "k") }
    assert_equal "Edgeway::Cloudflare::RateLimitTransport does not check", error.message
  end
end
