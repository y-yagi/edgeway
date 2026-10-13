require "edgeway"
require "edgeway/db/memory"

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

  def not_found(e)
    render json: { "error" => "gone: #{e.message}" }, status: :not_found
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

  def missing(e)
    render json: { "error" => "bad: #{e.message}" }, status: :bad_request
  end
end

module Admin
  class TodosController < ApplicationController
    def index = render json: [{ "admin" => "yes" }]
  end
end

# a constant that is not a controller is not reachable by a route
class DecoyController
  def index = "decoy"
end

# An app's own error under Edgeway::Error: the handler of its parent applies.
class AppError < Edgeway::Error; end
class ChildError < AppError; end
# One outside Edgeway::Error: its parent's handler applies too.
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

  def nested = render json: { "todo" => Todo.new(title: "n"), "list" => [Todo.new(title: "a"), [Todo.new(title: "b")]], "n" => 1 }

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

  def app_error(e)
    render json: { "error" => "app: #{e.message}" }, status: :unprocessable_entity
  end

  def swallow(_e)
  end

  def plain(e)
    render json: { "error" => "plain: #{e.class}: #{e.message}" }, status: :conflict
  end
end

# A controller that answers RecordNotUnique itself.
class TakenController < ApplicationController
  rescue_from Edgeway::RecordNotUnique, with: :taken

  def create = raise(Edgeway::RecordNotUnique, "UNIQUE constraint failed: things.name")

  def taken(e)
    render json: { "error" => "name taken" }, status: :unprocessable_entity
  end
end

# Raw params (or params.require without permit) given to a model: a 500 with
# the fixed body; .permit works.
class MassController < ApplicationController
  def raw = render(json: Todo.create!(params), status: :created)

  def required = render(json: Todo.create!(params.require(:todo)), status: :created)

  def raw_update
    todo = Todo.find(params["id"])
    todo.update!(params)
    render json: todo
  end

  def permitted = render(json: Todo.create!(params.require(:todo).permit(:title)), status: :created)
end

# What is logged, kept in memory.
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

class Draw
  def self.run
    Edgeway.application.routes.draw do |r|
      r.resources :todos, only: [:index, :show, :create, :update, :destroy]
      r.get "/echo/:id", to: "todos#echo"
      r.post "/echo/:id", to: "todos#echo"
      r.get "/boom", to: "todos#boom"
      r.get "/things/child", to: "things#child"
      r.get "/things/plain_child", to: "things#plain_child"
      r.get "/things/quiet", to: "things#quiet"
      r.get "/things/typo", to: "things#typo"
      r.get "/things/nested", to: "things#nested"
      r.get "/things/header", to: "things#header_in"
      r.get "/things/inject", to: "things#inject"
      r.get "/things/bad_header_name", to: "things#bad_header_name"
      r.post "/things/form", to: "things#form"
      r.post "/taken", to: "taken#create"
      r.post "/mass/raw", to: "mass#raw"
      r.post "/mass/required", to: "mass#required"
      r.post "/mass/raw_update/:id", to: "mass#raw_update"
      r.post "/mass/permitted", to: "mass#permitted"
      r.get "/things/private", to: "things#app_error"
      r.get "/things/render", to: "things#render"
      r.get "/things/missing", to: "things#missing"
      r.namespace :admin do |a|
        a.resources :todos, only: [:index]
      end
      r.get "/ghost", to: "ghost#index"
      r.get "/decoy", to: "decoy#index"
    end
  end
end
Draw.run

db = Edgeway::DB::MemoryAdapter.new
Edgeway::Model.connection = db
Edgeway::Model.freeze_time("2026-01-02T03:04:05Z")

def call(verb, path, query = "", body = "", type = nil)
  type = body.empty? ? "" : "application/json" if type.nil?
  res = Edgeway.application.call(Edgeway::HTTP::Request.new(verb, path, query, type, body))
  puts "#{verb} #{path} -> #{res.status} #{res.headers.inspect} #{res.body.strip}"
end

row = { "id" => 1, "title" => "a", "done" => 0 }
db.queue([row, row])
call("GET", "/todos")
db.queue([row])
call("GET", "/todos/1")
db.queue([])
call("GET", "/todos/2")
db.queue([row])
call("GET", "/todos/1", "deny=1")
db.queue([row])
call("DELETE", "/todos/1")
db.queue([row])
call("DELETE", "/todos/1", "deny=1")
db.queue([{ "id" => 7, "title" => "n", "done" => 0 }])
call("POST", "/todos", "", '{"todo":{"title":"n"}}')
db.queue([{ "id" => 8, "title" => "w", "done" => 0 }])
call("POST", "/todos", "", '{"title":"w"}')
call("POST", "/todos", "", '{}')
call("POST", "/todos", "", '{"todo":{"title":"  "}}')
call("POST", "/todos", "", '{bad')
call("GET", "/echo/5", "", "")
call("POST", "/echo/5", "", '{"todo":{"title":"t"},"id":"9"}')
call("GET", "/boom")
call("GET", "/nope")
call("DELETE", "/health")
call("GET", "/admin/todos")
# no such controller, and a class that is not a controller: 404
call("GET", "/ghost")
call("GET", "/decoy")

# rescue_from: the parent's handler for a subclass, and a handler that renders nothing
call("GET", "/things/child")
call("GET", "/things/plain_child")
call("GET", "/things/quiet")
# a status typo is an error (500), not a quiet 500 with a body
call("GET", "/things/typo")
# models inside a Hash and nested Arrays
call("GET", "/things/nested")
# Request#header: the CGI variable HTTP_X_TEST
ENV["HTTP_X_TEST"] = "abc"
call("GET", "/things/header")
# a newline in a header value, or a bad header name, is a 500 and the details stay out of the body
call("GET", "/things/inject", "name=ok")
call("GET", "/things/inject", "name=a%0D%0ASet-Cookie:%20x=1")
call("GET", "/things/bad_header_name")
# a form body
call("POST", "/things/form", "plain=q", "todo%5Btitle%5D=a+b&plain=f", "application/x-www-form-urlencoded; charset=utf-8")
# HEAD runs the GET route
db.queue([row])
call("HEAD", "/todos/1")
# an action that isn't defined, a private method and one of Base's own: 404
call("GET", "/things/missing")
call("GET", "/things/private")
call("GET", "/things/render")
# bad %-encoding or UTF-8 is a 400 (decode_www_form would turn %ff into U+FFFD)
call("GET", "/echo/1", "q=%ff")
call("GET", "/echo/1", "q=%EF%BF%BD")
call("POST", "/echo/1", "", "todo%5Btitle%5D=%ff", "application/x-www-form-urlencoded")
call("POST", "/echo/1", "", "{\"a\":\"\xff\"}")
# integers outside 32 bits: a 404 for an id, a 400 for a limit
db.queue([])
call("GET", "/todos/4294967297")
call("GET", "/todos", "limit=99999999999")

# a UNIQUE violation from the database is a 409 with a fixed body; the table
# and columns (the message) are only in the log
capture = CaptureLogger.new
Edgeway.logger = capture
db.fail_next("D1_ERROR: UNIQUE constraint failed: todos.title: SQLITE_CONSTRAINT", "INSERT")
call("POST", "/todos", "", '{"todo":{"title":"dup"}}')
puts capture.take
# any other database failure stays a 500
db.fail_next("D1_ERROR: no such table: todos: SQLITE_ERROR", "INSERT")
call("POST", "/todos", "", '{"todo":{"title":"dup"}}')
puts capture.take
# rescue_from RecordNotUnique wins over the default
call("POST", "/taken")
puts capture.take

# raw params (or require without permit) given to create!/update! are a bug in
# the app: a 500 with the fixed body, the details only in the log; permit works
call("POST", "/mass/raw", "", '{"title":"x"}')
puts capture.take
call("POST", "/mass/required", "", '{"todo":{"title":"x"}}')
puts capture.take
db.queue([row])
call("POST", "/mass/raw_update/1", "", '{"title":"x"}')
puts capture.take
db.queue([{ "id" => 9, "title" => "p", "done" => 0 }])
call("POST", "/mass/permitted", "", '{"todo":{"title":"p"}}')
puts capture.take
