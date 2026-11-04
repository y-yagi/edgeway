require "spinel_test/unit"
require "edgeway"
require "edgeway/db/memory"

class ServerTest < SpinelTest::Unit::TestCase
  class HealthController < Edgeway::Controller::Base
    def show = render json: { "status" => "ok", "q" => params["q"] }

    def leak
      headers["X-Name"] = params["name"]
      render json: {}
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

  JSON_200_HEAD = "Status: 200\nContent-Type: application/json\n\n"

  def setup
    @original_logger = Edgeway.logger
    @log = LogCollector.new
    Edgeway.logger = @log
    @primary = Edgeway::DB::MemoryAdapter.new
    Edgeway::Model.connection = @primary
    draw_routes
  end

  def teardown
    Edgeway.application.routes.list.clear
    Edgeway::Model.disconnect("analytics")
    Edgeway::Model.disconnect(Edgeway::Model::PRIMARY)
    Edgeway.logger = @original_logger
  end

  def draw_routes
    routes = Edgeway.application.routes
    routes.list.clear
    routes.draw do |mapper|
      mapper.get "/health", to: "server_test/health#show"
      mapper.get "/leak", to: "server_test/health#leak"
    end
  end

  # Server.run itself is not called: it reads STDIN to the end (blocks unless
  # the runner's stdin is closed) and prints to stdout.
  def cgi_for(path, query = "")
    request = Edgeway::HTTP::Request.new("GET", path, query, "", "")
    Edgeway.application.call(request).to_cgi
  end

  def logged_stats
    Edgeway::Server.log_query_stats
    @log.lines
  end

  def response_with_header(name, value)
    response = Edgeway::HTTP::Response.new(200, "")
    response.headers[name] = value
    response
  end

  def header_error_message(response)
    response.to_cgi
    "accepted"
  rescue Edgeway::InvalidHeader => error
    error.message
  end

  def primary_meta
    JSON.parse('{"rows_read":3,"rows_written":1,"duration":2,"served_by_region":"WEUR","served_by_primary":true}')
  end

  def analytics_meta
    JSON.parse('{"rows_read":5,"rows_written":0,"duration":1.5,"served_by_region":"WEUR","served_by_primary":true}')
  end

  def test_responds_with_the_decoded_query
    expected = JSON_200_HEAD + "{\"status\":\"ok\",\"q\":\"a b\"}\n"
    assert_equal expected, cgi_for("/health", "q=a%20b")
  end

  def test_answers_an_unknown_path_with_404
    expected = "Status: 404\nContent-Type: application/json\nX-Content-Type-Options: nosniff\n\n{\"error\":\"not found\"}\n"
    assert_equal expected, cgi_for("/nope")
  end

  def test_returns_a_header_set_from_a_param
    expected = "Status: 200\nX-Name: ok\nContent-Type: application/json\n\n{}\n"
    assert_equal expected, cgi_for("/leak", "name=ok")
  end

  def test_answers_a_bad_header_value_with_a_500_that_says_nothing_about_it
    expected = "Status: 500\nContent-Type: application/json\nX-Content-Type-Options: nosniff\n\n{\"error\":\"internal error\"}\n"
    assert_equal expected, cgi_for("/leak", "name=x%0D%0ASet-Cookie:%20a=1")
  end

  def test_to_cgi_prints_a_non_string_header_value
    response = Edgeway::HTTP::Response.new(201, "{}\n")
    response.headers["Content-Type"] = "application/json"
    response.headers["X-Count"] = 3
    assert_equal "Status: 201\nContent-Type: application/json\nX-Count: 3\n\n{}\n", response.to_cgi
  end

  def test_to_cgi_rejects_bad_header_names
    names = ["X Name", "X:Name", "X-Name\n", "", "Näme"]
    messages = names.map { |name| header_error_message(response_with_header(name, "v")) }
    expected = [
      'bad header name: "X Name"',
      'bad header name: "X:Name"',
      'bad header name: "X-Name\n"',
      'bad header name: ""',
      'bad header name: "Näme"'
    ]
    assert_equal expected, messages
  end

  def test_to_cgi_rejects_bad_header_values
    values = ["a\nStatus: 302", "a\rb", "a\0b"]
    messages = values.map { |value| header_error_message(response_with_header("X-Name", value)) }
    assert_equal ["bad value for header X-Name"] * 3, messages
  end

  def test_logs_nothing_when_there_were_no_queries
    assert_equal [], logged_stats
  end

  def test_logs_the_query_stats_of_the_primary_database
    @primary.record_meta(primary_meta)
    expected = ['info query stats {"queries":1,"rows_read":3,"rows_written":1,"db_ms":2.0}']
    assert_equal expected, logged_stats
  end

  def test_logs_an_extra_line_for_a_second_database
    analytics = Edgeway::DB::MemoryAdapter.new
    Edgeway::Model.connect("analytics", analytics)
    @primary.record_meta(primary_meta)
    analytics.record_meta(analytics_meta)
    expected = [
      'info query stats {"queries":1,"rows_read":3,"rows_written":1,"db_ms":2.0}',
      'info query stats {"queries":1,"rows_read":5,"rows_written":0,"db_ms":1.5,"database":"analytics"}'
    ]
    assert_equal expected, logged_stats
  end

  def test_logs_only_the_primary_line_when_the_second_database_had_no_queries
    Edgeway::Model.connect("analytics", Edgeway::DB::MemoryAdapter.new)
    @primary.record_meta(primary_meta)
    expected = ['info query stats {"queries":1,"rows_read":3,"rows_written":1,"db_ms":2.0}']
    assert_equal expected, logged_stats
  end

  def test_logs_nothing_when_no_database_is_connected
    Edgeway::Model.disconnect(Edgeway::Model::PRIMARY)
    assert_equal [], logged_stats
  end
end
