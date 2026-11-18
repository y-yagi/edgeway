require "edgeway"

# Answers canned rows and records nothing: MemoryAdapter appends every SQL to
# a log that would grow with the iteration count and skew the timings.
class CannedAdapter < Edgeway::DB::Adapter
  LIST_SIZE = 50

  def select_all(sql, binds)
    check_binds(binds)
    return [todo_row(1)] if sql.start_with?("INSERT") || !binds.empty?

    Array.new(LIST_SIZE) { |index| todo_row(index + 1) }
  end

  private

  def todo_row(id)
    { "id" => id, "title" => "Todo number #{id}", "done" => id % 2,
      "created_at" => "2026-01-01T00:00:00Z", "updated_at" => "2026-01-02T00:00:00Z" }
  end
end

class ApplicationModel < Edgeway::Model::Base
  extend Edgeway::Model::Macros
end

class Todo < ApplicationModel
  attribute :title, :string
  attribute :done, :boolean, default: false
  timestamps
  has_many :comments
  validates :title, presence: true, length: { maximum: 200 }
end

class Comment < ApplicationModel
  attribute :body, :string
  belongs_to :todo
end

class TodosController < Edgeway::Controller::Base
  def index = render json: Todo.order(:id).limit(50)

  def show = render json: Todo.find(params["id"])

  def create
    todo = Todo.create!(params.require(:todo).permit(:title, :done))
    render json: todo, status: :created
  end

  # Written by hand what `edgeway build` generates: a send with a computed
  # name would make Spinel keep every method reachable and skew the types.
  def _run_action(action)
    case action
    when "index" then self.index
    when "show" then self.show
    when "create" then self.create
    end
  end
end

module Edgeway
  module Controller
    module Dispatcher
      def self.instantiate(name, request)
        case name
        when "TodosController" then TodosController.new(request)
        end
      end
    end
  end
end

Edgeway.application.routes.draw do |r|
  r.resources :todos, only: [:index, :show, :create]
end

class Scenario
  attr_reader :name, :status, :method, :path, :content_type, :payload

  def initialize(name, status, method, path, content_type, payload)
    @name = name
    @status = status
    @method = method
    @path = path
    @content_type = content_type
    @payload = payload
  end
end

class RequestBenchmark
  DEFAULT_ITERATIONS = 5000
  WARMUP_ITERATIONS = 100
  ROUNDS = 5
  CREATE_BODY = '{"todo":{"title":"Write the benchmark","done":false}}'

  def initialize(iterations)
    @iterations = iterations
    @scenarios = [
      Scenario.new("GET /todos", 200, "GET", "/todos", "", ""),
      Scenario.new("GET /todos/1", 200, "GET", "/todos/1", "", ""),
      Scenario.new("POST /todos", 201, "POST", "/todos", "application/json", CREATE_BODY),
      Scenario.new("GET /missing", 404, "GET", "/missing", "", "")
    ]
  end

  def run
    check_responses
    puts "best of #{ROUNDS} rounds, #{@iterations} iterations each"
    @scenarios.each { |scenario| report(scenario) }
  end

  private

  def handle(scenario)
    request = Edgeway::HTTP::Request.new(scenario.method, scenario.path, "", scenario.content_type, scenario.payload)
    Edgeway.application.call(request).to_cgi
  end

  def check_responses
    @scenarios.each do |scenario|
      cgi = handle(scenario)
      next if cgi.start_with?("Status: #{scenario.status}\n")

      fail_check(scenario, "did not answer #{scenario.status}", cgi)
    end
    list = handle(@scenarios[0])
    records = list.scan('"title"').size
    fail_check(@scenarios[0], "answered #{records} records, not #{CannedAdapter::LIST_SIZE}", list) if records != CannedAdapter::LIST_SIZE
  end

  def fail_check(scenario, problem, cgi)
    puts "benchmark scenario #{scenario.name} #{problem}:"
    puts cgi
    exit 1
  end

  def report(scenario)
    WARMUP_ITERATIONS.times { handle(scenario) }
    best = Array.new(ROUNDS) { time_round(scenario) }.min
    puts "#{scenario.name.ljust(14)} #{format("%10.2f", best)} us/request"
  end

  def time_round(scenario)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @iterations.times { handle(scenario) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    elapsed * 1_000_000.0 / @iterations
  end
end

# Only errors are logged: the 404 scenario would otherwise print each request.
ENV["LOG_LEVEL"] = "error"
Edgeway::Model.connection = CannedAdapter.new
iterations = ARGV.empty? ? RequestBenchmark::DEFAULT_ITERATIONS : ARGV[0].to_i
if iterations < 1
  puts "usage: request.rb [ITERATIONS]  (a positive number of requests per round)"
  exit 1
end
RequestBenchmark.new(iterations).run
