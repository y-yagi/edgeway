require_relative "test_helper"

class CachingTest < DatabaseTestCase
  class ApplicationModel < Edgeway::Model::Base
    extend Edgeway::Model::Macros
  end

  class Note < ApplicationModel
    attribute :title, :string
    timestamps
  end

  class Plain < ApplicationModel
    attribute :title, :string
  end

  def self.note_at(id, updated_at)
    Note.instantiate({ "id" => id, "title" => "t", "created_at" => "2026-01-01T00:00:00.000Z", "updated_at" => updated_at })
  end

  class ApplicationController < Edgeway::Controller::Base
  end

  class PagesController < ApplicationController
    def show
      note = CachingTest.note_at(5, "2026-11-01T09:05:03.123Z")
      render json: note if stale?(etag: note, last_modified: note.updated_at)
    end

    def etag_only
      render json: { "ok" => true } if stale?(etag: params["v"])
    end

    def modified_only
      render json: { "ok" => true } if stale?(last_modified: Time.utc(2026, 11, 1, 9, 5, 3))
    end

    def shared
      render json: { "ok" => true } if stale?(etag: "x", public: true)
    end

    def preset
      expires_in 60, public: true
      render json: { "ok" => true } if stale?(etag: "x")
    end

    def returns
      render json: { "fresh" => fresh_when(etag: "x") }
    end

    def plain_model
      render json: { "ok" => true } if stale?(etag: Plain.new(title: "a"))
    end

    def relation
      render json: { "ok" => true } if stale?(etag: Note.order(:id))
    end

    def local_time
      time = Time.new(2026, 11, 1, 18, 5, 3, "+09:00")
      before = "#{time.utc_offset} #{time.hour}"
      fresh_when(last_modified: time)
      render json: { "before" => before, "after" => "#{time.utc_offset} #{time.hour}" }
    end

    def typed
      headers["Content-Type"] = "application/json"
      headers["X-Content-Type-Options"] = "nosniff"
      render json: { "ok" => true } if stale?(etag: "x")
    end

    def lowercase_cache_control
      headers["cache-control"] = "max-age=5"
      render json: { "ok" => true } if stale?(etag: "x")
    end

    def unvalidated
      render json: { "ok" => true } if stale?
    end

    def list
      render json: { "ok" => true } if stale?(etag: [CachingTest.note_at(1, "a"), CachingTest.note_at(2, "b")])
    end

    def create
      render json: { "ok" => true } if stale?(etag: "x")
    end

    def expiry
      expires_in(params["n"].to_i, public: params["public"] == "1", must_revalidate: params["revalidate"] == "1")
      head :ok
    end

    def bad_expiry
      expires_in(params["n"] == "float" ? 1.5 : -1)
    end

    def bad_expiry_type
      expires_in("60")
    end

    def store
      no_store
      head :ok
    end

    def bad_last_modified
      fresh_when(last_modified: params["v"] == "number" ? 5 : "yesterday")
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

  INVALID_SECONDS_LOG = "error ArgumentError: seconds must be a non-negative Integer {\"status\":500}"
  LAST_MODIFIED = "Sun, 01 Nov 2026 09:05:03 GMT"
  ETAG_FORMAT = /\AW\/"[0-9a-f]{32}"\z/
  SHOW_ETAG = "W/\"de62aea1bc0342603a09129915257db5\""
  STRING_ETAG = "W/\"2d711642b726b04401627ca9fbac32f5\""
  RELATION_ETAG = "W/\"b2876576156978107266365879472409\""

  LAST_MODIFIED_HEADER = ["Last-Modified", LAST_MODIFIED]
  REVALIDATE_HEADER = ["Cache-Control", "max-age=0, private, must-revalidate"]
  SHOW_ETAG_HEADER = ["ETag", SHOW_ETAG]
  STRING_ETAG_HEADER = ["ETag", STRING_ETAG]
  RELATION_ETAG_HEADER = ["ETag", RELATION_ETAG]
  JSON_HEADER = ["Content-Type", "application/json"]
  NOSNIFF_HEADER = ["X-Content-Type-Options", "nosniff"]

  JSON_ERROR_HEADERS = [JSON_HEADER, NOSNIFF_HEADER]
  OK_BODY = "{\"ok\":true}\n"
  NOTE_BODY = "{\"id\":5,\"title\":\"t\",\"created_at\":\"2026-01-01T00:00:00.000Z\",\"updated_at\":\"2026-11-01T09:05:03.123Z\"}\n"
  INTERNAL_ERROR_BODY = "{\"error\":\"internal error\"}\n"
  NOT_FOUND_BODY = "{\"error\":\"not found\"}\n"

  def setup
    super
    @original_logger = Edgeway.logger
    @log = LogCollector.new
    Edgeway.logger = @log
    draw_routes
  end

  def teardown
    Edgeway.application.routes.list.clear
    Edgeway.logger = @original_logger
    super
  end

  def draw_routes
    routes = Edgeway.application.routes
    routes.list.clear
    routes.draw do |mapper|
      mapper.get "/show", to: "caching_test/pages#show"
      mapper.get "/etag_only", to: "caching_test/pages#etag_only"
      mapper.get "/modified_only", to: "caching_test/pages#modified_only"
      mapper.get "/shared", to: "caching_test/pages#shared"
      mapper.get "/preset", to: "caching_test/pages#preset"
      mapper.get "/returns", to: "caching_test/pages#returns"
      mapper.get "/list", to: "caching_test/pages#list"
      mapper.get "/plain_model", to: "caching_test/pages#plain_model"
      mapper.get "/relation", to: "caching_test/pages#relation"
      mapper.get "/local_time", to: "caching_test/pages#local_time"
      mapper.get "/typed", to: "caching_test/pages#typed"
      mapper.get "/lowercase_cache_control", to: "caching_test/pages#lowercase_cache_control"
      mapper.get "/unvalidated", to: "caching_test/pages#unvalidated"
      mapper.post "/create", to: "caching_test/pages#create"
      mapper.get "/expiry", to: "caching_test/pages#expiry"
      mapper.get "/bad_expiry", to: "caching_test/pages#bad_expiry"
      mapper.get "/bad_expiry_type", to: "caching_test/pages#bad_expiry_type"
      mapper.get "/store", to: "caching_test/pages#store"
      mapper.get "/bad_last_modified", to: "caching_test/pages#bad_last_modified"
      mapper.get "/fresh_when", to: "caching_test/pages#fresh_when"
      mapper.get "/stale", to: "caching_test/pages#stale?"
      mapper.get "/expires_in", to: "caching_test/pages#expires_in"
      mapper.get "/no_store", to: "caching_test/pages#no_store"
    end
  end

  def request(verb, path, query = "", request_headers = {})
    request_headers.each { |name, value| ENV[environment_name(name)] = value }
    Edgeway.application.call(Edgeway::HTTP::Request.new(verb, path, query, "", ""))
  ensure
    request_headers.each { |name, _value| ENV.delete(environment_name(name)) }
  end

  def environment_name(header_name)
    "HTTP_" + header_name.upcase.gsub("-", "_")
  end

  def get(path, query = "", request_headers = {})
    request("GET", path, query, request_headers)
  end

  def etag_of(path, query = "")
    get(path, query).headers["ETag"]
  end

  def show_etag
    etag_of("/show")
  end

  def relation_rows
    [{ "id" => 1, "title" => "a", "created_at" => nil, "updated_at" => "2026-11-01T09:05:03.123Z" },
     { "id" => 2, "title" => "b", "created_at" => nil, "updated_at" => "2026-11-01T09:06:03.123Z" }]
  end

  def assert_response(response, status, headers, body)
    assert_equal status, response.status
    assert_equal headers, response.headers.to_a
    assert_equal body, response.body
  end

  def assert_internal_error(response, log_line)
    assert_response response, 500, JSON_ERROR_HEADERS, INTERNAL_ERROR_BODY
    assert_equal [log_line], @log.lines
  end

  def assert_not_found(response)
    assert_response response, 404, JSON_ERROR_HEADERS, NOT_FOUND_BODY
  end

  def assert_not_modified(response, headers)
    assert_response response, 304, headers, ""
  end

  def assert_show_fresh(response)
    assert_not_modified response, [SHOW_ETAG_HEADER, LAST_MODIFIED_HEADER, REVALIDATE_HEADER]
  end

  def assert_show_rendered(response)
    assert_response response, 200, [SHOW_ETAG_HEADER, LAST_MODIFIED_HEADER, REVALIDATE_HEADER, JSON_HEADER], NOTE_BODY
  end

  def assert_modified_only_rendered(response)
    assert_response response, 200, [LAST_MODIFIED_HEADER, REVALIDATE_HEADER, JSON_HEADER], OK_BODY
  end

  def assert_modified_only_fresh(response)
    assert_not_modified response, [LAST_MODIFIED_HEADER, REVALIDATE_HEADER]
  end

  def test_expires_in_zero_is_private
    assert_response get("/expiry", "n=0"), 200, [["Cache-Control", "max-age=0, private"]], ""
  end

  def test_expires_in_public
    assert_response get("/expiry", "n=60&public=1"), 200, [["Cache-Control", "max-age=60, public"]], ""
  end

  def test_expires_in_must_revalidate
    response = get("/expiry", "n=3600&revalidate=1")
    assert_response response, 200, [["Cache-Control", "max-age=3600, private, must-revalidate"]], ""
  end

  def test_expires_in_public_and_must_revalidate
    response = get("/expiry", "n=3600&public=1&revalidate=1")
    assert_response response, 200, [["Cache-Control", "max-age=3600, public, must-revalidate"]], ""
  end

  def test_expires_in_rejects_a_negative_number
    assert_internal_error get("/bad_expiry"), INVALID_SECONDS_LOG
  end

  def test_expires_in_rejects_a_float
    assert_internal_error get("/bad_expiry", "n=float"), INVALID_SECONDS_LOG
  end

  def test_expires_in_rejects_a_string
    assert_internal_error get("/bad_expiry_type"), INVALID_SECONDS_LOG
  end

  def test_no_store
    assert_response get("/store"), 200, [["Cache-Control", "no-store"]], ""
  end

  def test_etag_has_the_weak_format
    assert_match ETAG_FORMAT, show_etag
  end

  def test_etag_of_a_model_is_stable
    assert_equal SHOW_ETAG, show_etag
    assert_equal SHOW_ETAG, show_etag
  end

  def test_the_same_string_gives_the_same_etag
    assert_equal "W/\"6b86b273ff34fce19d6b804eff5a3f57\"", etag_of("/etag_only", "v=1")
    assert_equal etag_of("/etag_only", "v=1"), etag_of("/etag_only", "v=1")
  end

  def test_a_different_string_gives_a_different_etag
    assert_not_equal etag_of("/etag_only", "v=1"), etag_of("/etag_only", "v=2")
  end

  def test_a_list_of_models_has_its_own_etag
    assert_equal "W/\"e84e2e0c890e4657c4cfca904237aeba\"", etag_of("/list")
  end

  def test_a_model_differs_from_a_list_of_itself
    note = CachingTest.note_at(5, "2026-11-01T09:05:03.123Z")
    assert_not_equal Edgeway::Controller::Caching.etag_for(note), Edgeway::Controller::Caching.etag_for([note])
  end

  def test_a_different_updated_at_gives_a_different_etag
    assert_equal SHOW_ETAG, show_etag
    other = Edgeway::Controller::Caching.etag_for(CachingTest.note_at(5, "2026-11-01T09:05:03.124Z"))
    assert_not_equal show_etag, other
  end

  def test_a_different_id_gives_a_different_etag
    assert_equal SHOW_ETAG, show_etag
    other = Edgeway::Controller::Caching.etag_for(CachingTest.note_at(6, "2026-11-01T09:05:03.123Z"))
    assert_not_equal show_etag, other
  end

  def test_a_nested_list_is_not_a_flat_list
    nested = Edgeway::Controller::Caching.etag_for([[1, 2], 3])
    assert_not_equal Edgeway::Controller::Caching.etag_for([1, 2, 3]), nested
  end

  def test_list_order_matters
    forward = Edgeway::Controller::Caching.etag_for([1, 2])
    assert_not_equal Edgeway::Controller::Caching.etag_for([2, 1]), forward
  end

  def test_last_modified_alone_sets_the_header
    assert_modified_only_rendered get("/modified_only")
  end

  def test_last_modified_rejects_a_string
    assert_internal_error get("/bad_last_modified"), "error ArgumentError: last_modified is not an ISO 8601 String: \"yesterday\" {\"status\":500}"
  end

  def test_last_modified_rejects_a_number
    assert_internal_error get("/bad_last_modified", "v=number"), "error ArgumentError: last_modified must be a Time or an ISO 8601 String {\"status\":500}"
  end

  def test_public_cache_control
    response = get("/shared")
    assert_response response, 200, [STRING_ETAG_HEADER, ["Cache-Control", "max-age=0, public, must-revalidate"], JSON_HEADER], OK_BODY
  end

  def test_a_preset_cache_control_is_kept
    response = get("/preset")
    assert_response response, 200, [["Cache-Control", "max-age=60, public"], STRING_ETAG_HEADER, JSON_HEADER], OK_BODY
  end

  def test_if_none_match_with_the_etag_answers_304
    assert_show_fresh get("/show", "", { "If-None-Match" => show_etag })
  end

  def test_if_none_match_with_the_strong_form_answers_304
    assert_show_fresh get("/show", "", { "If-None-Match" => show_etag.delete_prefix("W/") })
  end

  def test_if_none_match_with_a_list_containing_the_etag_answers_304
    assert_show_fresh get("/show", "", { "If-None-Match" => "W/\"other\", #{show_etag}" })
  end

  def test_if_none_match_star_answers_304
    assert_show_fresh get("/show", "", { "If-None-Match" => "*" })
  end

  def test_if_none_match_with_another_etag_renders
    assert_show_rendered get("/show", "", { "If-None-Match" => "W/\"other\"" })
  end

  def test_if_none_match_star_renders_without_an_etag
    assert_modified_only_rendered get("/modified_only", "", { "If-None-Match" => "*" })
  end

  def test_if_none_match_wins_over_if_modified_since
    request_headers = { "If-None-Match" => "W/\"other\"", "If-Modified-Since" => LAST_MODIFIED }
    assert_show_rendered get("/show", "", request_headers)
  end

  def test_head_with_if_none_match_answers_304
    assert_show_fresh request("HEAD", "/show", "", { "If-None-Match" => show_etag })
  end

  def test_if_modified_since_at_the_last_modified_time_answers_304
    assert_modified_only_fresh get("/modified_only", "", { "If-Modified-Since" => LAST_MODIFIED })
  end

  def test_if_modified_since_after_the_last_modified_time_answers_304
    assert_modified_only_fresh get("/modified_only", "", { "If-Modified-Since" => "Sun, 01 Nov 2026 09:05:04 GMT" })
  end

  def test_if_modified_since_before_the_last_modified_time_renders
    assert_modified_only_rendered get("/modified_only", "", { "If-Modified-Since" => "Sun, 01 Nov 2026 09:05:02 GMT" })
  end

  def test_an_unparsable_if_modified_since_renders
    assert_modified_only_rendered get("/modified_only", "", { "If-Modified-Since" => "garbage" })
  end

  def test_if_modified_since_answers_304_for_a_model_with_last_modified
    assert_show_fresh get("/show", "", { "If-Modified-Since" => LAST_MODIFIED })
  end

  def test_if_modified_since_renders_without_a_last_modified
    response = get("/etag_only", "", { "If-Modified-Since" => LAST_MODIFIED })
    assert_response response, 200, [REVALIDATE_HEADER, JSON_HEADER], OK_BODY
  end

  def test_a_304_drops_the_content_type_headers
    response = get("/typed", "", { "If-None-Match" => "*" })
    assert_not_modified response, [STRING_ETAG_HEADER, REVALIDATE_HEADER]
  end

  def test_a_200_keeps_the_content_type_headers
    response = get("/typed")
    assert_response response, 200, [JSON_HEADER, NOSNIFF_HEADER, STRING_ETAG_HEADER, REVALIDATE_HEADER], OK_BODY
  end

  def test_a_lowercase_cache_control_header_is_kept
    response = get("/lowercase_cache_control")
    assert_response response, 200, [["cache-control", "max-age=5"], STRING_ETAG_HEADER, JSON_HEADER], OK_BODY
  end

  def test_a_model_without_updated_at_is_a_500
    assert_internal_error get("/plain_model"), "error ArgumentError: CachingTest::Plain has no updated_at (add timestamps) {\"status\":500}"
  end

  def test_last_modified_is_sent_in_utc_and_leaves_the_time_alone
    response = get("/local_time")
    body = "{\"before\":\"32400 18\",\"after\":\"32400 18\"}\n"
    assert_response response, 200, [LAST_MODIFIED_HEADER, REVALIDATE_HEADER, JSON_HEADER], body
  end

  def test_head_without_conditional_headers_renders
    assert_show_rendered request("HEAD", "/show")
  end

  def test_if_none_match_star_renders_without_validators
    response = get("/unvalidated", "", { "If-None-Match" => "*" })
    assert_response response, 200, [REVALIDATE_HEADER, JSON_HEADER], OK_BODY
  end

  def test_a_relation_etag_is_the_etag_of_its_list
    @database.queue(relation_rows)
    list = relation_rows.map { |row| Note.instantiate(row) }
    assert_equal Edgeway::Controller::Caching.etag_for(list), etag_of("/relation")
  end

  def test_a_relation_etag_has_the_weak_format
    @database.queue(relation_rows)
    assert_match ETAG_FORMAT, etag_of("/relation")
  end

  def test_a_relation_answers_304_for_its_etag
    @database.queue(relation_rows)
    relation_etag = etag_of("/relation")
    @database.queue(relation_rows)
    response = get("/relation", "", { "If-None-Match" => relation_etag })
    assert_not_modified response, [RELATION_ETAG_HEADER, REVALIDATE_HEADER]
  end

  def test_post_is_never_answered_304
    response = request("POST", "/create", "", { "If-None-Match" => "*" })
    assert_response response, 200, [STRING_ETAG_HEADER, REVALIDATE_HEADER, JSON_HEADER], OK_BODY
  end

  def test_fresh_when_returns_false_when_it_did_not_answer_304
    response = get("/returns")
    assert_response response, 200, [STRING_ETAG_HEADER, REVALIDATE_HEADER, JSON_HEADER], "{\"fresh\":false}\n"
  end

  def test_fresh_when_returns_true_when_it_answered_304
    response = get("/returns", "", { "If-None-Match" => "*" })
    assert_response response, 200, [STRING_ETAG_HEADER, REVALIDATE_HEADER, JSON_HEADER], "{\"fresh\":true}\n"
  end

  def test_fresh_when_is_not_an_action
    assert_not_found get("/fresh_when")
  end

  def test_stale_is_not_an_action
    assert_not_found get("/stale")
  end

  def test_expires_in_is_not_an_action
    assert_not_found get("/expires_in")
  end

  def test_no_store_is_not_an_action
    assert_not_found get("/no_store")
  end
end
