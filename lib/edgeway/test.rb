# Test helper (Edgeway::UnitTest for models, Edgeway::IntegrationTest for requests): `require "edgeway/test"` in test/test_helper.rb.
# Needs spinel_test-unit (a development dependency of the app, not of edgeway)
# and tmp/test_app.rb, which `edgeway test` rewrites on every run (and which
# is git-ignored): Spinel resolves require
# at compile time, so the app's files are listed there (in Build's order)
# rather than found at run time, and so is the database the tests use
# (Edgeway::TestDatabases). Unlike build/main.rb it never calls
# Edgeway::Server.run. Run the tests with `edgeway test`, not spinel_test-unit
# directly: a missing or stale tmp/test_app.rb only shows up as Spinel's own
# "cannot find tmp/test_app" (the message cannot be customised at compile time).
require "spinel_test/unit"
require "edgeway"
require "edgeway/http/stub_transport"
require "edgeway/rate_limit/stub_limiter"
require "tmp/test_app"

module Edgeway
  # What a test sees of the answer.
  class TestResponse
    attr_reader :status, :body, :headers

    def initialize(status, body, headers)
      @status = status
      @body = body
      @headers = headers
    end
  end

  # What a model test needs: a fresh database per test (Edgeway::TestDatabases,
  # chosen by `edgeway test` from config/database.yml), with the app's
  # db/migrations applied in file name order, so a test can check what was
  # stored (Todo.find, db.select_all) and read db.log for the SQL. A database
  # under databases: in config/database.yml gets its own, with
  # db/NAME/migrations, read with db(:name). Edgeway's own tests use
  # MemoryAdapter instead, which stores nothing. Edgeway.cache is a NullStore in
  # every test, whatever config/cache.yml says; a test that checks caching sets
  # `Edgeway.cache = Edgeway::Cache::MemoryStore.new` itself. The rate limiter
  # allows every request and records the checks (stub_rate_limit,
  # rate_limit_checks).
  class UnitTest < SpinelTest::Unit::TestCase
    def setup
      @databases = {}
      @http = Edgeway::HTTP::StubTransport.new
      Edgeway::HTTP.client = @http
      Edgeway.cache = Edgeway::Cache::NullStore.new
      @rate_limiter = Edgeway::RateLimit::StubLimiter.new
      Edgeway::Controller.rate_limiter = @rate_limiter
      Edgeway::TestDatabases.reset
      open_database(Edgeway::Model::PRIMARY)
      Edgeway::TEST_DATABASES.each { |name| open_database(name) }
    end

    def teardown
      @databases.each do |name, database|
        database.close
        Edgeway::Model.disconnect(name)
      end
    end

    def db(name = Edgeway::Model::PRIMARY) = @databases.fetch(name.to_s)

    def stub_http(verb, url, status: 200, body: "", headers: {})
      @http.stub(verb, url, status, body, headers)
    end

    def stub_http_error(verb, url, message = "connection failed", timeout: false)
      @http.stub_error(verb, url, message, timeout)
    end

    def http_requests = @http.requests

    def stub_rate_limit(binding_name, exceeded: true)
      @rate_limiter.stub(binding_name, exceeded)
    end

    def rate_limit_checks = @rate_limiter.checks

    private

    def open_database(name)
      database = Edgeway::TestDatabases.open(name)
      Edgeway::Model.connect(name, database)
      @databases[name] = database
    end
  end

  # A UnitTest that also sends requests to the app (get, post, ...) and reads
  # the answer (response, json, assert_response).
  class IntegrationTest < UnitTest
    attr_reader :response

    def setup
      super
      @response = nil
      @json = nil
    end

    def get(path, json: nil, headers: {}, remote_addr: "") = request("GET", path, json, headers, remote_addr)
    def delete(path, json: nil, headers: {}, remote_addr: "") = request("DELETE", path, json, headers, remote_addr)
    def post(path, json: nil, headers: {}, remote_addr: "") = request("POST", path, json, headers, remote_addr)
    def put(path, json: nil, headers: {}, remote_addr: "") = request("PUT", path, json, headers, remote_addr)
    def patch(path, json: nil, headers: {}, remote_addr: "") = request("PATCH", path, json, headers, remote_addr)

    # The body parsed as JSON.
    def json
      @json = JSON.parse(@response.body) if @json.nil?
      @json
    end

    def assert_response(status)
      assert_equal status, @response.status
    end

    private

    def request(verb, target, json, headers, remote_addr)
      path = target
      query = ""
      q = target.index("?")
      unless q.nil?
        path = target[0, q]
        query = target[q + 1, target.length]
      end
      body = json.nil? ? "" : JSON.generate(json)
      content_type = json.nil? ? "" : "application/json"
      res = call_application(Edgeway::HTTP::Request.new(verb, path, query, content_type, body), headers, remote_addr)
      @json = nil
      @response = Edgeway::TestResponse.new(res.status, res.body, res.headers)
      @response
    end

    def call_application(http_request, headers, remote_addr)
      previous_addr = ENV["REMOTE_ADDR"]
      headers.each { |k, v| ENV["HTTP_" + k.upcase.gsub("-", "_")] = v }
      ENV["REMOTE_ADDR"] = remote_addr
      begin
        Edgeway.application.call(http_request)
      ensure
        headers.each { |k, _v| ENV.delete("HTTP_" + k.upcase.gsub("-", "_")) }
        restore_remote_addr(previous_addr)
      end
    end

    def restore_remote_addr(previous_addr)
      if previous_addr.nil?
        ENV.delete("REMOTE_ADDR")
      else
        ENV["REMOTE_ADDR"] = previous_addr
      end
    end
  end
end
