require "edgeway"
require "edgeway/db/memory"

class ApplicationModel < Edgeway::Model::Base
  extend Edgeway::Model::Macros
end

class Note < ApplicationModel
  attribute :title, :string
  timestamps
end

def note_at(id, updated_at)
  Note.instantiate({ "id" => id, "title" => "t", "created_at" => "2026-01-01T00:00:00.000Z", "updated_at" => updated_at })
end

class Plain < ApplicationModel
  attribute :title, :string
end

class ApplicationController < Edgeway::Controller::Base
end

class PagesController < ApplicationController
  def show
    note = note_at(5, "2026-11-01T09:05:03.123Z")
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
    render json: { "ok" => true } if stale?(etag: [note_at(1, "a"), note_at(2, "b")])
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

Edgeway.application.routes.draw do |r|
  r.get "/show", to: "pages#show"
  r.get "/etag_only", to: "pages#etag_only"
  r.get "/modified_only", to: "pages#modified_only"
  r.get "/shared", to: "pages#shared"
  r.get "/preset", to: "pages#preset"
  r.get "/returns", to: "pages#returns"
  r.get "/list", to: "pages#list"
  r.get "/plain_model", to: "pages#plain_model"
  r.get "/relation", to: "pages#relation"
  r.get "/local_time", to: "pages#local_time"
  r.get "/typed", to: "pages#typed"
  r.get "/lowercase_cache_control", to: "pages#lowercase_cache_control"
  r.get "/unvalidated", to: "pages#unvalidated"
  r.post "/create", to: "pages#create"
  r.get "/expiry", to: "pages#expiry"
  r.get "/bad_expiry", to: "pages#bad_expiry"
  r.get "/bad_expiry_type", to: "pages#bad_expiry_type"
  r.get "/store", to: "pages#store"
  r.get "/bad_last_modified", to: "pages#bad_last_modified"
  r.get "/fresh_when", to: "pages#fresh_when"
  r.get "/stale", to: "pages#stale?"
  r.get "/expires_in", to: "pages#expires_in"
  r.get "/no_store", to: "pages#no_store"
end

database = Edgeway::DB::MemoryAdapter.new
Edgeway::Model.connection = database

def request(verb, path, query = "", request_headers = {})
  request_headers.each { |name, value| ENV["HTTP_" + name.upcase.gsub("-", "_")] = value }
  res = Edgeway.application.call(Edgeway::HTTP::Request.new(verb, path, query, "", ""))
  request_headers.each { |name, _value| ENV.delete("HTTP_" + name.upcase.gsub("-", "_")) }
  res
end

def call(verb, path, query = "", request_headers = {})
  res = request(verb, path, query, request_headers)
  puts "#{verb} #{path} #{request_headers.inspect} -> #{res.status} #{res.headers.inspect} #{res.body.strip.inspect}"
end

def etag_of(path, query = "") = request("GET", path, query).headers["ETag"]

LAST_MODIFIED = "Sun, 01 Nov 2026 09:05:03 GMT"

puts "-- expires_in"
call("GET", "/expiry", "n=0")
call("GET", "/expiry", "n=60&public=1")
call("GET", "/expiry", "n=3600&revalidate=1")
call("GET", "/expiry", "n=3600&public=1&revalidate=1")
call("GET", "/bad_expiry")
call("GET", "/bad_expiry", "n=float")
call("GET", "/bad_expiry_type")
call("GET", "/store")

puts "-- etag"
etag = etag_of("/show")
puts "format: #{etag.match?(/\AW\/"[0-9a-f]{32}"\z/)}"
puts "model is stable: #{etag == etag_of("/show")}"
puts "same string, same etag: #{etag_of("/etag_only", "v=1") == etag_of("/etag_only", "v=1")}"
puts "different string, different etag: #{etag_of("/etag_only", "v=1") != etag_of("/etag_only", "v=2")}"
puts "model differs from its list: #{etag_of("/list") != etag}"
puts "different updated_at, different etag: #{Edgeway::Controller::Caching.etag_for(note_at(5, "2026-11-01T09:05:03.124Z")) != etag}"
puts "different id, different etag: #{Edgeway::Controller::Caching.etag_for(note_at(6, "2026-11-01T09:05:03.123Z")) != etag}"
puts "list is not a flat list: #{Edgeway::Controller::Caching.etag_for([[1, 2], 3]) != Edgeway::Controller::Caching.etag_for([1, 2, 3])}"
puts "list order matters: #{Edgeway::Controller::Caching.etag_for([1, 2]) != Edgeway::Controller::Caching.etag_for([2, 1])}"

puts "-- last_modified"
call("GET", "/modified_only")
call("GET", "/bad_last_modified")
call("GET", "/bad_last_modified", "v=number")

puts "-- cache control"
call("GET", "/shared")
call("GET", "/preset")

puts "-- if-none-match"
call("GET", "/show", "", { "If-None-Match" => etag })
call("GET", "/show", "", { "If-None-Match" => etag.delete_prefix("W/") })
call("GET", "/show", "", { "If-None-Match" => "W/\"other\", #{etag}" })
call("GET", "/show", "", { "If-None-Match" => "*" })
call("GET", "/show", "", { "If-None-Match" => "W/\"other\"" })
call("GET", "/modified_only", "", { "If-None-Match" => "*" })
call("GET", "/show", "", { "If-None-Match" => "W/\"other\"", "If-Modified-Since" => LAST_MODIFIED })
call("HEAD", "/show", "", { "If-None-Match" => etag })

puts "-- if-modified-since"
call("GET", "/modified_only", "", { "If-Modified-Since" => LAST_MODIFIED })
call("GET", "/modified_only", "", { "If-Modified-Since" => "Sun, 01 Nov 2026 09:05:04 GMT" })
call("GET", "/modified_only", "", { "If-Modified-Since" => "Sun, 01 Nov 2026 09:05:02 GMT" })
call("GET", "/modified_only", "", { "If-Modified-Since" => "garbage" })
call("GET", "/show", "", { "If-Modified-Since" => LAST_MODIFIED })
call("GET", "/etag_only", "", { "If-Modified-Since" => LAST_MODIFIED })

puts "-- 304 headers, relation, HEAD, no validators"
call("GET", "/typed", "", { "If-None-Match" => "*" })
call("GET", "/typed")
call("GET", "/lowercase_cache_control")
call("GET", "/plain_model")
call("GET", "/local_time")
call("HEAD", "/show")
call("GET", "/unvalidated", "", { "If-None-Match" => "*" })
relation_rows = [{ "id" => 1, "title" => "a", "created_at" => nil, "updated_at" => "2026-11-01T09:05:03.123Z" },
                 { "id" => 2, "title" => "b", "created_at" => nil, "updated_at" => "2026-11-01T09:06:03.123Z" }]
database.queue(relation_rows)
relation_etag = etag_of("/relation")
puts "relation etag is the list's: #{relation_etag == Edgeway::Controller::Caching.etag_for(relation_rows.map { |row| Note.instantiate(row) })}"
database.queue(relation_rows)
puts "relation etag: #{relation_etag.match?(/\AW\/"[0-9a-f]{32}"\z/)}"
call("GET", "/relation", "", { "If-None-Match" => relation_etag })

puts "-- other methods and return value"
call("POST", "/create", "", { "If-None-Match" => "*" })
call("GET", "/returns")
call("GET", "/returns", "", { "If-None-Match" => "*" })

puts "-- not routable"
call("GET", "/fresh_when")
call("GET", "/stale")
call("GET", "/expires_in")
call("GET", "/no_store")
