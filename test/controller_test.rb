require "spinel_test/unit"
require "edgeway"
require "edgeway/db/memory"

class ControllerTest < SpinelTest::Unit::TestCase
  class ApplicationModel < Edgeway::Model::Base
    extend Edgeway::Model::Macros
  end

  class Todo < ApplicationModel
    attribute :title, :string
    attribute :done, :boolean, default: false
    validates :title, presence: true
  end

  class ApplicationController < Edgeway::Controller::Base
    before_action :log_in
    rescue_from Edgeway::RecordNotFound, with: :not_found

    def log_in
      headers["X-Log"] = "in"
    end

    def not_found(error)
      render json: { "error" => "gone: #{error.message}" }, status: :not_found
    end
  end

  class TodosController < ApplicationController
    before_action :set_todo, only: [:show, :update, :destroy]
    before_action :deny, only: [:destroy]
    rescue_from Edgeway::ParameterMissing, with: :missing

    def index = render json: Todo.order(:id).limit(params.key?("limit") ? params["limit"] : "50")

    def show = render json: @todo

    def create
      todo = Todo.create!(todo_params)
      render json: todo, status: :created
    end

    def update
      @todo.update!(todo_params)
      render json: @todo
    end

    def destroy
      @todo.destroy
      head :no_content
    end

    def echo = render json: { "title" => params["todo[title]"], "id" => params["id"] }

    def boom
      raise "secret detail"
    end

    private

    def set_todo
      @todo = Todo.find(params["id"])
    end

    def deny
      render json: { "error" => "denied" }, status: 403 if params["deny"] == "1"
    end

    def todo_params = params.require(:todo).permit(:title, :done)

    def missing(error)
      render json: { "error" => "bad: #{error.message}" }, status: :bad_request
    end
  end

  module Admin
    class TodosController < ApplicationController
      def index = render json: [{ "admin" => "yes" }]
    end
  end

  # Reachable by a route name, but not a controller.
  class DecoyController
    def index = "decoy"
  end

  class AppError < Edgeway::Error; end
  class ChildError < AppError; end
  class PlainError < StandardError; end
  class SubPlainError < PlainError; end

  class ThingsController < ApplicationController
    rescue_from AppError, with: :app_error
    rescue_from Edgeway::UnknownColumn, with: :swallow
    rescue_from PlainError, with: :plain

    def child = raise(ChildError, "child failed")

    def plain_child = raise(SubPlainError, "plain failed")

    def quiet = raise(Edgeway::UnknownColumn, "unknown column: x")

    def typo = render(json: {}, status: :creatd)

    def nested
      render json: { "todo" => Todo.new(title: "n"), "list" => [Todo.new(title: "a"), [Todo.new(title: "b")]], "n" => 1 }
    end

    def header_in = render json: { "x" => request.header("X-Test"), "none" => request.header("X-None") }

    def inject
      headers["X-Name"] = params["name"]
      render json: {}
    end

    def bad_header_name
      headers["Bad Name"] = "v"
      render json: {}
    end

    def form = render json: { "title" => params["todo[title]"], "plain" => params["plain"] }

    private

    def app_error(error)
      render json: { "error" => "app: #{error.message}" }, status: :unprocessable_entity
    end

    def swallow(_error)
    end

    def plain(error)
      render json: { "error" => "plain: #{error.class}: #{error.message}" }, status: :conflict
    end
  end

  class OverridingController < ApplicationController
    rescue_from Edgeway::RecordNotFound, with: :specific
    rescue_from Edgeway::Error, with: :general

    def missing_record = raise(Edgeway::RecordNotFound, "no such record")

    def general(_error)
      render json: { "handler" => "general" }, status: :internal_server_error
    end

    def specific(_error)
      render json: { "handler" => "specific" }, status: :forbidden
    end
  end

  class DownController < ApplicationController
    def show = raise(Edgeway::DatabaseUnavailable, "d1: Network connection lost")
  end

  class BusyController < ApplicationController
    rescue_from Edgeway::DatabaseUnavailable, with: :busy

    def show = raise(Edgeway::DatabaseUnavailable, "d1: D1 DB is overloaded")

    def busy(_error)
      render json: { "error" => "busy" }, status: :too_many_requests
    end
  end

  class TakenController < ApplicationController
    rescue_from Edgeway::RecordNotUnique, with: :taken

    def create = raise(Edgeway::RecordNotUnique, "UNIQUE constraint failed: things.name")

    def taken(_error)
      render json: { "error" => "name taken" }, status: :unprocessable_entity
    end
  end

  class MassController < ApplicationController
    def unpermitted = render(json: Todo.create!(params), status: :created)

    def required = render(json: Todo.create!(params.require(:todo)), status: :created)

    def raw_update
      todo = Todo.find(params["id"])
      todo.update!(params)
      render json: todo
    end

    def permitted = render(json: Todo.create!(params.require(:todo).permit(:title)), status: :created)
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

  LOG_HEADER = ["X-Log", "in"]
  JSON_HEADER = ["Content-Type", "application/json"]
  NOSNIFF_HEADER = ["X-Content-Type-Options", "nosniff"]
  
  LOGGED_JSON_HEADERS = [LOG_HEADER, JSON_HEADER]
  ERROR_HEADERS = [JSON_HEADER, NOSNIFF_HEADER]

  INTERNAL_ERROR_BODY = "{\"error\":\"internal error\"}\n"
    TODO_A_BODY = "{\"id\":1,\"title\":\"a\",\"done\":false}\n"

  DUPLICATE_TODO = "{\"todo\":{\"title\":\"dup\"}}"
  FORM_TYPE = "application/x-www-form-urlencoded"

  def setup
    @original_logger = Edgeway.logger
    @original_test_header = ENV["HTTP_X_TEST"]
    @log = LogCollector.new
    Edgeway.logger = @log
    @database = Edgeway::DB::MemoryAdapter.new
    Edgeway::Model.connection = @database
    draw_routes
  end

  def teardown
    Edgeway.application.routes.list.clear
    Edgeway.logger = @original_logger
    Edgeway::Model.disconnect(Edgeway::Model::PRIMARY)
    restore_test_header
  end

  def restore_test_header
    if @original_test_header.nil?
      ENV.delete("HTTP_X_TEST")
    else
      ENV["HTTP_X_TEST"] = @original_test_header
    end
  end

  def draw_routes
    Edgeway.application.routes.list.clear
    # Mapper.new is the only way to set a module prefix without changing the paths.
    mapper = Edgeway::Routing::Mapper.new(Edgeway.application.routes, "", "controller_test/")
    draw_todo_routes(mapper)
    draw_mass_assignment_and_admin_routes(mapper)
    draw_things_routes(mapper)
    draw_failure_routes(mapper)
  end

  def draw_todo_routes(mapper)
    mapper.resources :todos, only: [:index, :show, :create, :update, :destroy]
    mapper.get "/echo/:id", to: "todos#echo"
    mapper.post "/echo/:id", to: "todos#echo"
    mapper.get "/boom", to: "todos#boom"
  end

  def draw_mass_assignment_and_admin_routes(mapper)
    mapper.post "/mass/raw", to: "mass#unpermitted"
    mapper.post "/mass/required", to: "mass#required"
    mapper.post "/mass/raw_update/:id", to: "mass#raw_update"
    mapper.post "/mass/permitted", to: "mass#permitted"
    mapper.namespace :admin do |admin|
      admin.resources :todos, only: [:index]
    end
  end

  def draw_things_routes(mapper)
    mapper.get "/things/child", to: "things#child"
    mapper.get "/things/plain_child", to: "things#plain_child"
    mapper.get "/things/quiet", to: "things#quiet"
    mapper.get "/things/typo", to: "things#typo"
    mapper.get "/things/nested", to: "things#nested"
    mapper.get "/things/header", to: "things#header_in"
    mapper.get "/things/inject", to: "things#inject"
    mapper.get "/things/bad_header_name", to: "things#bad_header_name"
    mapper.post "/things/form", to: "things#form"
    mapper.get "/things/private", to: "things#app_error"
    mapper.get "/things/render", to: "things#render"
    mapper.get "/things/missing", to: "things#missing"
  end

  def draw_failure_routes(mapper)
    mapper.post "/taken", to: "taken#create"
    mapper.get "/down", to: "down#show"
    mapper.get "/busy", to: "busy#show"
    mapper.get "/overriding/record", to: "overriding#missing_record"
    mapper.get "/ghost", to: "ghost#index"
    mapper.get "/decoy", to: "decoy#index"
  end

  def send_request(verb, path, query = "", body = "", type = "")
    content_type = type.empty? && !body.empty? ? "application/json" : type
    Edgeway.application.call(Edgeway::HTTP::Request.new(verb, path, query, content_type, body))
  end

  def get(path, query = "") = send_request("GET", path, query)

  def post_json(path, body) = send_request("POST", path, "", body)

  def queue_todo(id, title)
    @database.queue([{ "id" => id, "title" => title, "done" => 0 }])
  end

  def queue_todo_a = queue_todo(1, "a")

  def statements(verb)
    @database.log.select { |line| line.start_with?(verb) }
  end

  def assert_response(response, status, headers, body)
    assert_equal status, response.status
    assert_equal headers, response.headers.to_a
    assert_equal body, response.body
  end

  def assert_logged(lines)
    assert_equal lines, @log.lines
  end

  def assert_not_logged
    assert_equal [], @log.lines
  end

  def assert_error_response(response, status, body)
    assert_response response, status, ERROR_HEADERS, body
  end

  def assert_internal_error(response, log_line)
    assert_error_response response, 500, INTERNAL_ERROR_BODY
    assert_logged [log_line]
  end

  def assert_not_found(response, log_line)
    assert_error_response response, 404, "{\"error\":\"not found\"}\n"
    assert_logged [log_line]
  end

  def assert_bad_request(response, message)
    assert_error_response response, 400, "{\"error\":\"#{message}\"}\n"
    assert_not_logged
  end

  def assert_routed(verb, path, controller_path, action)
    route, _params = Edgeway.application.routes.recognize(verb, path)
    assert_equal controller_path, route.controller_path
    assert_equal action, route.action
  end

  def assert_constraint_failure(message, error_class)
    @database.fail_next("D1_ERROR: #{message}: SQLITE_CONSTRAINT", "INSERT")
    response = post_json("/todos", DUPLICATE_TODO)
    assert_internal_error response, "error Edgeway::#{error_class}: D1_ERROR: #{message}: SQLITE_CONSTRAINT status=500"
  end

  def assert_header_value_rejected(query)
    response = get("/things/inject", query)
    assert_internal_error response, "error Edgeway::InvalidHeader: bad value for header X-Name status=500"
  end

  def assert_forbidden_attributes(response)
    assert_internal_error response, "error Edgeway::ForbiddenAttributes: ControllerTest::Todo: params must go through permit status=500"
    assert_equal [], statements("INSERT")
    assert_equal [], statements("UPDATE")
  end

  def test_index_lists_the_records
    @database.queue([{ "id" => 1, "title" => "a", "done" => 0 }, { "id" => 1, "title" => "a", "done" => 0 }])
    response = get("/todos")
    assert_response response, 200, LOGGED_JSON_HEADERS,
                    "[{\"id\":1,\"title\":\"a\",\"done\":false},{\"id\":1,\"title\":\"a\",\"done\":false}]\n"
    assert_not_logged
  end

  def test_show_renders_the_record
    queue_todo_a
    assert_response get("/todos/1"), 200, LOGGED_JSON_HEADERS, TODO_A_BODY
    assert_not_logged
  end

  def test_show_of_a_missing_record_is_answered_by_the_rescue_from_handler
    @database.queue([])
    response = get("/todos/2")
    assert_response response, 404, LOGGED_JSON_HEADERS, "{\"error\":\"gone: todos 2 not found\"}\n"
    assert_not_logged
  end

  def test_show_is_not_held_back_by_the_destroy_only_callback
    queue_todo_a
    assert_response get("/todos/1", "deny=1"), 200, LOGGED_JSON_HEADERS, TODO_A_BODY
  end

  def test_update_writes_the_changed_values
    queue_todo_a
    queue_todo(1, "z")
    response = send_request("PATCH", "/todos/1", "", "{\"todo\":{\"title\":\"z\"}}")
    assert_response response, 200, LOGGED_JSON_HEADERS, "{\"id\":1,\"title\":\"z\",\"done\":false}\n"
    assert_equal ["UPDATE todos SET title = ?, done = ? WHERE id = ? | [\"z\",0,1]"], statements("UPDATE")
    assert_not_logged
  end

  def test_destroy_deletes_the_record
    queue_todo_a
    response = send_request("DELETE", "/todos/1")
    assert_response response, 204, [LOG_HEADER], ""
    assert_equal 1, statements("DELETE").size
    assert_not_logged
  end

  def test_destroy_denied_by_the_callback_deletes_nothing
    queue_todo_a
    response = send_request("DELETE", "/todos/1", "deny=1")
    assert_response response, 403, LOGGED_JSON_HEADERS, "{\"error\":\"denied\"}\n"
    assert_equal [], statements("DELETE")
    assert_equal 1, statements("SELECT").size
  end

  def test_create_renders_the_new_record
    queue_todo(7, "n")
    response = post_json("/todos", "{\"todo\":{\"title\":\"n\"}}")
    assert_response response, 201, LOGGED_JSON_HEADERS, "{\"id\":7,\"title\":\"n\",\"done\":false}\n"
    assert_equal ["INSERT INTO todos (title, done) VALUES (?, ?) RETURNING id, title, done | [\"n\",0]"], statements("INSERT")
  end

  def test_create_wraps_unscoped_json_into_the_controller_scope
    queue_todo(8, "w")
    response = post_json("/todos", "{\"title\":\"w\"}")
    assert_response response, 201, LOGGED_JSON_HEADERS, "{\"id\":8,\"title\":\"w\",\"done\":false}\n"
    assert_equal ["INSERT INTO todos (title, done) VALUES (?, ?) RETURNING id, title, done | [\"w\",0]"], statements("INSERT")
  end

  def test_create_without_the_required_param_is_answered_by_the_rescue_from_handler
    response = post_json("/todos", "{}")
    assert_response response, 400, LOGGED_JSON_HEADERS,
                    "{\"error\":\"bad: param is missing or the value is empty: todo\"}\n"
    assert_equal [], statements("INSERT")
    assert_not_logged
  end

  def test_create_with_an_invalid_record_is_422_without_the_callback_header
    response = post_json("/todos", "{\"todo\":{\"title\":\"  \"}}")
    assert_error_response response, 422, "{\"errors\":[\"title can't be blank\"]}\n"
    assert_equal [], statements("INSERT")
    assert_not_logged
  end

  def test_create_with_a_malformed_json_body_is_400
    response = post_json("/todos", "{bad")
    assert_bad_request response, "bad JSON body"
    assert_equal [], statements("INSERT")
  end

  def test_params_are_read_from_the_path_when_there_is_no_body
    response = get("/echo/5")
    assert_response response, 200, LOGGED_JSON_HEADERS, "{\"title\":null,\"id\":\"5\"}\n"
  end

  def test_path_params_win_over_the_body
    response = post_json("/echo/5", "{\"todo\":{\"title\":\"t\"},\"id\":\"9\"}")
    assert_response response, 200, LOGGED_JSON_HEADERS, "{\"title\":\"t\",\"id\":\"5\"}\n"
  end

  def test_an_unexpected_error_is_500_and_its_detail_stays_in_the_log
    response = get("/boom")
    assert_internal_error response, "error RuntimeError: secret detail status=500"
  end

  def test_a_failure_after_a_success_and_a_success_after_the_failure_on_the_same_app
    queue_todo_a
    assert_response get("/todos/1"), 200, LOGGED_JSON_HEADERS, TODO_A_BODY
    assert_not_logged
    assert_internal_error get("/boom"), "error RuntimeError: secret detail status=500"
    queue_todo_a
    assert_response get("/todos/1"), 200, LOGGED_JSON_HEADERS, TODO_A_BODY
    assert_equal 1, @log.lines.size
  end

  def test_an_unknown_path_is_404
    assert_not_found get("/nope"), "info no route for GET /nope status=404"
  end

  def test_a_path_with_no_route_for_any_verb_is_404
    response = send_request("DELETE", "/health")
    assert_not_found response, "info no route for DELETE /health status=404"
  end

  def test_a_known_path_with_another_verb_is_404
    response = send_request("DELETE", "/echo/5")
    assert_not_found response, "info no route for DELETE /echo/5 status=404"
  end

  def test_a_namespaced_route_reaches_the_nested_controller
    assert_routed "GET", "/admin/todos", "controller_test/admin/todos", "index"
    assert_response get("/admin/todos"), 200, LOGGED_JSON_HEADERS, "[{\"admin\":\"yes\"}]\n"
  end

  def test_a_route_to_a_missing_constant_is_404
    assert_routed "GET", "/ghost", "controller_test/ghost", "index"
    assert_raise(NameError) { Object.const_get("ControllerTest::GhostController") }
    response = get("/ghost")
    assert_not_found response, "info no controller for controller_test/ghost status=404"
  end

  def test_a_route_to_a_class_that_is_not_a_controller_is_404
    assert_routed "GET", "/decoy", "controller_test/decoy", "index"
    assert_equal "decoy", ControllerTest::DecoyController.new.index
    response = get("/decoy")
    assert_not_found response, "info no controller for controller_test/decoy status=404"
  end

  def test_rescue_from_uses_the_handler_of_the_parent_error
    response = get("/things/child")
    assert_response response, 422, LOGGED_JSON_HEADERS, "{\"error\":\"app: child failed\"}\n"
    assert_not_logged
  end

  def test_rescue_from_uses_the_handler_of_the_parent_of_a_plain_error
    response = get("/things/plain_child")
    assert_response response, 409, LOGGED_JSON_HEADERS,
                    "{\"error\":\"plain: ControllerTest::SubPlainError: plain failed\"}\n"
    assert_not_logged
  end

  def test_a_handler_declared_later_wins_over_a_more_specific_earlier_one
    response = get("/overriding/record")
    assert_response response, 500, LOGGED_JSON_HEADERS, "{\"handler\":\"general\"}\n"
    assert_not_logged
  end

  def test_a_handler_that_renders_nothing_answers_204
    assert_response get("/things/quiet"), 204, [LOG_HEADER], ""
    assert_not_logged
  end

  def test_an_unknown_status_symbol_is_500
    response = get("/things/typo")
    assert_internal_error response, "error ArgumentError: unknown status: :creatd status=500"
  end

  def test_models_inside_hashes_and_arrays_are_rendered
    response = get("/things/nested")
    assert_response response, 200, LOGGED_JSON_HEADERS,
                    "{\"todo\":{\"id\":null,\"title\":\"n\",\"done\":false}," \
                    "\"list\":[{\"id\":null,\"title\":\"a\",\"done\":false},[{\"id\":null,\"title\":\"b\",\"done\":false}]]," \
                    "\"n\":1}\n"
  end

  def test_request_header_reads_the_cgi_variable
    ENV["HTTP_X_TEST"] = "abc"
    response = get("/things/header")
    assert_response response, 200, LOGGED_JSON_HEADERS, "{\"x\":\"abc\",\"none\":\"\"}\n"
  end

  def test_a_header_value_without_a_newline_is_sent
    response = get("/things/inject", "name=ok")
    assert_response response, 200, [LOG_HEADER, ["X-Name", "ok"], JSON_HEADER], "{}\n"
  end

  def test_a_newline_in_a_header_value_is_500_and_the_value_stays_out_of_the_body
    assert_header_value_rejected "name=a%0D%0ASet-Cookie:%20x=1"
  end

  def test_a_lone_line_feed_in_a_header_value_is_500
    assert_header_value_rejected "name=a%0Ab"
  end

  def test_a_lone_carriage_return_in_a_header_value_is_500
    assert_header_value_rejected "name=a%0Db"
  end

  def test_a_nul_in_a_header_value_is_500
    assert_header_value_rejected "name=a%00b"
  end

  def test_a_bad_header_name_is_500
    response = get("/things/bad_header_name")
    assert_internal_error response, "error Edgeway::InvalidHeader: bad header name: \"Bad Name\" status=500"
  end

  def test_a_form_body_is_parsed_and_wins_over_the_query
    response = send_request("POST", "/things/form", "plain=q", "todo%5Btitle%5D=a+b&plain=f", "#{FORM_TYPE}; charset=utf-8")
    assert_response response, 200, LOGGED_JSON_HEADERS, "{\"title\":\"a b\",\"plain\":\"f\"}\n"
  end

  def test_head_runs_the_get_route
    queue_todo_a
    response = send_request("HEAD", "/todos/1")
    assert_response response, 200, LOGGED_JSON_HEADERS, TODO_A_BODY
  end

  def test_an_action_that_is_not_defined_is_404
    assert_routed "GET", "/things/missing", "controller_test/things", "missing"
    assert_not_found get("/things/missing"), "info no route for GET /things/missing status=404"
  end

  def test_a_private_method_is_not_an_action
    assert_routed "GET", "/things/private", "controller_test/things", "app_error"
    assert_not_found get("/things/private"), "info no route for GET /things/private status=404"
  end

  def test_a_public_method_of_base_is_not_an_action
    assert_routed "GET", "/things/render", "controller_test/things", "render"
    assert_not_found get("/things/render"), "info no route for GET /things/render status=404"
  end

  def test_a_query_that_decodes_to_invalid_utf8_is_400
    response = get("/echo/1", "q=%ff")
    assert_bad_request response, "query string is not valid UTF-8"
  end

  def test_an_encoded_replacement_character_in_the_query_is_accepted
    response = get("/echo/1", "q=%EF%BF%BD")
    assert_response response, 200, LOGGED_JSON_HEADERS, "{\"title\":null,\"id\":\"1\"}\n"
  end

  def test_a_form_body_that_decodes_to_invalid_utf8_is_400
    response = send_request("POST", "/echo/1", "", "todo%5Btitle%5D=%ff", FORM_TYPE)
    assert_bad_request response, "form body is not valid UTF-8"
  end

  def test_an_invalid_utf8_json_body_is_400
    response = post_json("/echo/1", "{\"a\":\"\xff\"}")
    assert_bad_request response, "body is not valid UTF-8"
  end

  def test_an_id_outside_32_bits_is_not_found
    @database.queue([])
    response = get("/todos/4294967297")
    assert_response response, 404, LOGGED_JSON_HEADERS, "{\"error\":\"gone: todos 4294967297 not found\"}\n"
    assert_not_logged
  end

  def test_a_limit_outside_32_bits_is_400
    response = get("/todos", "limit=99999999999")
    assert_bad_request response, "bad limit: 99999999999"
    assert_equal [], statements("SELECT")
  end

  def test_a_unique_violation_is_409_and_the_table_stays_in_the_log
    @database.fail_next("D1_ERROR: UNIQUE constraint failed: todos.title: SQLITE_CONSTRAINT", "INSERT")
    response = post_json("/todos", DUPLICATE_TODO)
    assert_error_response response, 409, "{\"error\":\"record not unique\"}\n"
    assert_logged ["info D1_ERROR: UNIQUE constraint failed: todos.title: SQLITE_CONSTRAINT status=409"]
  end

  def test_another_database_failure_is_500
    @database.fail_next("D1_ERROR: no such table: todos: SQLITE_ERROR", "INSERT")
    response = post_json("/todos", DUPLICATE_TODO)
    assert_internal_error response, "error Edgeway::DatabaseError: D1_ERROR: no such table: todos: SQLITE_ERROR status=500"
  end

  def test_rescue_from_record_not_unique_wins_over_the_default
    response = send_request("POST", "/taken")
    assert_response response, 422, LOGGED_JSON_HEADERS, "{\"error\":\"name taken\"}\n"
    assert_not_logged
  end

  def test_a_not_null_violation_is_500
    assert_constraint_failure "NOT NULL constraint failed: todos.title", "NotNullViolation"
  end

  def test_a_foreign_key_violation_is_500
    assert_constraint_failure "FOREIGN KEY constraint failed", "InvalidForeignKey"
  end

  def test_a_check_violation_is_500
    assert_constraint_failure "CHECK constraint failed: stars", "CheckViolation"
  end

  def test_an_unavailable_database_is_503_with_retry_after
    response = get("/down")
    assert_response response, 503, [JSON_HEADER, NOSNIFF_HEADER, ["Retry-After", "1"]],
                    "{\"error\":\"database unavailable\"}\n"
    assert_logged ["error d1: Network connection lost status=503"]
  end

  def test_rescue_from_database_unavailable_wins_over_the_default
    response = get("/busy")
    assert_response response, 429, LOGGED_JSON_HEADERS, "{\"error\":\"busy\"}\n"
    assert_not_logged
  end

  def test_raw_params_given_to_create_are_500
    response = post_json("/mass/raw", "{\"title\":\"x\"}")
    assert_forbidden_attributes response
  end

  def test_required_params_without_permit_given_to_create_are_500
    response = post_json("/mass/required", "{\"todo\":{\"title\":\"x\"}}")
    assert_forbidden_attributes response
  end

  def test_raw_params_given_to_update_are_500
    queue_todo_a
    response = post_json("/mass/raw_update/1", "{\"title\":\"x\"}")
    assert_forbidden_attributes response
  end

  def test_permitted_params_given_to_create_are_accepted
    queue_todo(9, "p")
    response = post_json("/mass/permitted", "{\"todo\":{\"title\":\"p\"}}")
    assert_response response, 201, LOGGED_JSON_HEADERS, "{\"id\":9,\"title\":\"p\",\"done\":false}\n"
    assert_equal ["INSERT INTO todos (title, done) VALUES (?, ?) RETURNING id, title, done | [\"p\",0]"], statements("INSERT")
    assert_not_logged
  end
end
