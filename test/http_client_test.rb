require "spinel_test/unit"
require "edgeway"
require "edgeway/http/stub_transport"

class HttpClientTest < SpinelTest::Unit::TestCase
  class PartnersController < Edgeway::Controller::Base
    def show
      reply = Edgeway::HTTP.get("https://api.example/down")
      render json: { "status" => reply.status }
    end

    def slow
      reply = Edgeway::HTTP.get("https://api.example/slow")
      render json: { "status" => reply.status }
    end

    def items
      reply = Edgeway::HTTP.get("https://api.example/items")
      render json: reply.json
    end
  end

  class LogCollector
    attr_reader :lines

    def initialize
      @lines = []
    end

    def info(message, fields = {})
      @lines << "info #{message} #{JSON.generate(fields)}"
    end

    def error(message, fields = {})
      @lines << "error #{message} #{JSON.generate(fields)}"
    end
  end

  ITEMS_URL = "https://api.example/items"
  INVALID_TIMEOUT_MESSAGE = "timeout must be 0.001 to 300 seconds"

  def setup
    @original_client = Edgeway::HTTP.client
    @original_logger = Edgeway.logger
    @log = LogCollector.new
    Edgeway.logger = @log
    @transport = Edgeway::HTTP::StubTransport.new
    Edgeway::HTTP.client = @transport
    stub_endpoints
  end

  def teardown
    Edgeway.application.routes.list.clear
    Edgeway::HTTP.client = @original_client
    Edgeway.logger = @original_logger
  end

  def stub_endpoints
    @transport.stub(:get, ITEMS_URL, 200, "{\"items\":[1,2]}", { "Content-Type" => "application/json", "X-Id" => "7" })
    @transport.stub("POST", ITEMS_URL, 201, "created", {})
    @transport.stub(:get, "https://api.example/missing", 404, "no", {})
    @transport.stub(:get, "https://api.example/moved", 302, "", { "Location" => ITEMS_URL })
    @transport.stub(:get, "https://api.example/text", 200, "café 日本", {})
    @transport.stub_error(:get, "https://api.example/down", "connection refused", false)
    @transport.stub_error(:get, "https://api.example/slow", "request timed out", true)
  end

  def timeout_message_from
    yield
    "accepted"
  rescue ArgumentError => error
    error.message
  end

  def describe_request(sent)
    "#{sent["method"]} #{sent["url"]} #{sent["body"].inspect} #{sent["headers"].inspect} #{sent["timeout_ms"]}"
  end

  def draw_partner_routes
    routes = Edgeway.application.routes
    routes.list.clear
    routes.draw do |mapper|
      mapper.get "/partner", to: "http_client_test/partners#show"
      mapper.get "/partner/slow", to: "http_client_test/partners#slow"
      mapper.get "/partner/items", to: "http_client_test/partners#items"
    end
  end

  def partner_reply(path)
    draw_partner_routes
    reply = Edgeway.application.call(Edgeway::HTTP::Request.new("GET", path, "", "", ""))
    "#{path} -> #{reply.status} #{reply.body.strip}"
  end

  def test_get_returns_the_status
    assert_equal 200, Edgeway::HTTP.get(ITEMS_URL).status
  end

  def test_get_is_successful_for_a_200
    assert_equal true, Edgeway::HTTP.get(ITEMS_URL).success?
  end

  def test_response_headers_have_lowercased_names
    assert_equal [["content-type", "application/json"], ["x-id", "7"]], Edgeway::HTTP.get(ITEMS_URL).headers.to_a
  end

  def test_response_body_is_the_stubbed_string
    assert_equal "{\"items\":[1,2]}", Edgeway::HTTP.get(ITEMS_URL).body
  end

  def test_response_json_parses_the_body
    assert_equal [1, 2], Edgeway::HTTP.get(ITEMS_URL).json["items"]
  end

  def test_post_returns_the_created_response
    created = Edgeway::HTTP.post(ITEMS_URL, body: "{\"name\":\"a\"}", headers: { "Authorization" => "Bearer t" })
    assert_equal 201, created.status
    assert_equal "created", created.body
  end

  def test_a_404_is_not_successful
    missing = Edgeway::HTTP.get("https://api.example/missing")
    assert_equal 404, missing.status
    assert_equal false, missing.success?
  end

  def test_a_redirect_is_returned_and_not_successful
    moved = Edgeway::HTTP.get("https://api.example/moved")
    assert_equal 302, moved.status
    assert_equal false, moved.success?
    assert_equal ITEMS_URL, moved.headers["location"]
  end

  def test_body_keeps_multibyte_text
    text = Edgeway::HTTP.get("https://api.example/text")
    assert_equal "café 日本", text.body
    assert_equal 7, text.body.length
  end

  def test_a_transport_error_raises_http_error
    error = assert_raise(Edgeway::HTTP::Error) { Edgeway::HTTP.get("https://api.example/down") }
    assert_equal "Edgeway::HTTP::Error", error.class.to_s
    assert_equal "connection refused", error.message
  end

  def test_a_timed_out_request_raises_timeout
    error = assert_raise(Edgeway::HTTP::Timeout) { Edgeway::HTTP.get("https://api.example/slow", timeout: 2) }
    assert_equal "request timed out", error.message
  end

  def test_timeout_is_an_http_error_and_an_edgeway_error
    error = assert_raise(Edgeway::HTTP::Timeout) { Edgeway::HTTP.get("https://api.example/slow", timeout: 2) }
    assert_equal true, error.is_a?(Edgeway::HTTP::Error)
    assert_equal true, error.is_a?(Edgeway::Error)
  end

  def test_an_unstubbed_request_raises
    error = assert_raise(Edgeway::HTTP::UnstubbedRequest) { Edgeway::HTTP.get("https://api.example/unknown") }
    assert_equal "no stub for GET https://api.example/unknown (add stub_http to the test)", error.message
  end

  def test_zero_timeout_is_rejected
    assert_equal INVALID_TIMEOUT_MESSAGE, timeout_message_from { Edgeway::HTTP.delete(ITEMS_URL, timeout: 0) }
    assert_equal [], @transport.requests
  end

  def test_negative_timeout_is_rejected
    assert_equal INVALID_TIMEOUT_MESSAGE, timeout_message_from { Edgeway::HTTP.delete(ITEMS_URL, timeout: -1) }
    assert_equal [], @transport.requests
  end

  def test_timeout_below_a_millisecond_is_rejected
    assert_equal INVALID_TIMEOUT_MESSAGE, timeout_message_from { Edgeway::HTTP.delete(ITEMS_URL, timeout: 0.0004) }
    assert_equal [], @transport.requests
  end

  def test_timeout_above_300_seconds_is_rejected
    assert_equal INVALID_TIMEOUT_MESSAGE, timeout_message_from { Edgeway::HTTP.delete(ITEMS_URL, timeout: 301) }
    assert_equal [], @transport.requests
  end

  def test_a_huge_timeout_is_rejected
    assert_equal INVALID_TIMEOUT_MESSAGE, timeout_message_from { Edgeway::HTTP.delete(ITEMS_URL, timeout: 5_000_000) }
    assert_equal [], @transport.requests
  end

  def test_put_and_patch_send_their_body_and_timeout
    @transport.stub(:put, ITEMS_URL, 200, "", {})
    @transport.stub(:patch, ITEMS_URL, 200, "", {})
    Edgeway::HTTP.put(ITEMS_URL, body: "x", timeout: 3)
    Edgeway::HTTP.patch(ITEMS_URL)
    expected = [
      "PUT https://api.example/items \"x\" {} 3000",
      "PATCH https://api.example/items \"\" {} 10000"
    ]
    assert_equal expected, @transport.requests.map { |sent| describe_request(sent) }
  end

  def test_every_request_is_recorded_with_its_body_headers_and_timeout
    Edgeway::HTTP.get(ITEMS_URL)
    Edgeway::HTTP.post(ITEMS_URL, body: "{\"name\":\"a\"}", headers: { "Authorization" => "Bearer t" })
    Edgeway::HTTP.get("https://api.example/missing")
    assert_raise(Edgeway::HTTP::Timeout) { Edgeway::HTTP.get("https://api.example/slow", timeout: 2) }
    assert_raise(Edgeway::HTTP::Error) { Edgeway::HTTP.get("https://api.example/down") }
    assert_raise(Edgeway::HTTP::UnstubbedRequest) { Edgeway::HTTP.get("https://api.example/unknown") }
    expected = [
      "GET https://api.example/items \"\" {} 10000",
      "POST https://api.example/items \"{\\\"name\\\":\\\"a\\\"}\" {\"Authorization\" => \"Bearer t\"} 10000",
      "GET https://api.example/missing \"\" {} 10000",
      "GET https://api.example/slow \"\" {} 2000",
      "GET https://api.example/down \"\" {} 10000",
      "GET https://api.example/unknown \"\" {} 10000"
    ]
    assert_equal expected, @transport.requests.map { |sent| describe_request(sent) }
  end

  def test_delete_requests_are_recorded_with_their_timeouts
    @transport.stub(:delete, ITEMS_URL, 204, "", {})
    Edgeway::HTTP.delete(ITEMS_URL, timeout: 300)
    Edgeway::HTTP.delete(ITEMS_URL, timeout: 0.001)
    expected = [
      "DELETE https://api.example/items \"\" {} 300000",
      "DELETE https://api.example/items \"\" {} 1"
    ]
    assert_equal expected, @transport.requests.map { |sent| describe_request(sent) }
  end

  def test_the_base_transport_refuses_requests
    Edgeway::HTTP.client = Edgeway::HTTP::Transport.new
    error = assert_raise(Edgeway::HTTP::Error) { Edgeway::HTTP.get(ITEMS_URL) }
    assert_equal "no HTTP transport is set", error.message
  end

  def test_a_controller_answers_500_when_the_partner_is_down
    assert_equal "/partner -> 500 {\"error\":\"internal error\"}", partner_reply("/partner")
    assert_equal ["error Edgeway::HTTP::Error: connection refused {\"status\":500}"], @log.lines
  end

  def test_a_controller_answers_500_when_the_partner_times_out
    assert_equal "/partner/slow -> 500 {\"error\":\"internal error\"}", partner_reply("/partner/slow")
    assert_equal ["error Edgeway::HTTP::Timeout: request timed out {\"status\":500}"], @log.lines
  end

  def test_a_controller_renders_the_partner_json
    assert_equal "/partner/items -> 200 {\"items\":[1,2]}", partner_reply("/partner/items")
  end
end
