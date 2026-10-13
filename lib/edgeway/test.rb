# Integration-test helper: `require "edgeway/test"` in test/test_helper.rb.
# Needs spinel_test-unit (a development dependency of the app, not of edgeway)
# and tmp/test_app.rb, which `edgeway test` rewrites on every run (and which
# is git-ignored): Spinel resolves require
# at compile time, so the app's files are listed there (in Build's order)
# rather than found at run time. Unlike build/main.rb it never calls
# Edgeway::Server.run. Run the tests with `edgeway test`, not spinel_test-unit
# directly: a missing or stale tmp/test_app.rb only shows up as Spinel's own
# "cannot find tmp/test_app" (the message cannot be customised at compile time).
require "spinel_test/unit"
require "edgeway"
require "edgeway/db/memory"
require "edgeway/db/sqlite"
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

  class IntegrationTest < SpinelTest::Unit::TestCase
    # A fresh in-memory SQLite database per test (SQLiteAdapter), with the
    # app's db/migrations applied in file name order: requests really read and
    # write rows, so a test can check what was stored (Todo.find, db.select_all)
    # and read db.log for the SQL. Edgeway's own tests use MemoryAdapter
    # instead, which stores nothing.
    attr_reader :db, :response

    def setup
      @db = Edgeway::DB::SQLiteAdapter.new(":memory:")
      @db.apply_migrations(File.join(Edgeway::TEST_APP_ROOT, "db/migrations"))
      Edgeway::Model.connection = @db
      @response = nil
      @json = nil
    end

    def teardown
      @db.close
    end

    def get(path, json: nil, headers: {}) = request("GET", path, json, headers)
    def delete(path, json: nil, headers: {}) = request("DELETE", path, json, headers)
    def post(path, json: nil, headers: {}) = request("POST", path, json, headers)
    def put(path, json: nil, headers: {}) = request("PUT", path, json, headers)
    def patch(path, json: nil, headers: {}) = request("PATCH", path, json, headers)

    # The body parsed as JSON.
    def json
      @json = JSON.parse(@response.body) if @json.nil?
      @json
    end

    def assert_response(status)
      assert_equal status, @response.status
    end

    private

    def request(verb, target, json, headers)
      path = target
      query = ""
      q = target.index("?")
      unless q.nil?
        path = target[0, q]
        query = target[q + 1, target.length]
      end
      body = json.nil? ? "" : JSON.generate(json)
      content_type = json.nil? ? "" : "application/json"
      headers.each { |k, v| ENV["HTTP_" + k.upcase.gsub("-", "_")] = v }
      begin
        res = Edgeway.application.call(Edgeway::HTTP::Request.new(verb, path, query, content_type, body))
      ensure
        headers.each { |k, _v| ENV.delete("HTTP_" + k.upcase.gsub("-", "_")) }
      end
      @json = nil
      @response = Edgeway::TestResponse.new(res.status, res.body, res.headers)
      @response
    end
  end
end
