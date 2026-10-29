require "edgeway"
require "edgeway/db/memory"

class HealthController < Edgeway::Controller::Base
  def show = render json: { "status" => "ok", "q" => params["q"] }

  def leak
    headers["X-Name"] = params["name"]
    render json: {}
  end
end

Edgeway.application.routes.draw do |r|
  r.get "/health", to: "health#show"
  r.get "/leak", to: "health#leak"
end

# Server.run reads the CGI environment and prints the CGI response
def run(path, query = "")
  ENV["REQUEST_METHOD"] = "GET"
  ENV["PATH_INFO"] = path
  ENV["QUERY_STRING"] = query
  Edgeway::Server.run
end

run("/health", "q=a%20b")
puts "--"
run("/nope")
puts "--"
# a bad header value: a 500 whose body says nothing about it
run("/leak", "name=ok")
puts "--"
run("/leak", "name=x%0D%0ASet-Cookie:%20a=1")
puts "--"

# Response#to_cgi
res = Edgeway::HTTP::Response.new(201, "{}\n")
res.headers["Content-Type"] = "application/json"
res.headers["X-Count"] = 3
print res.to_cgi
puts "--"

["X Name", "X:Name", "X-Name\n", "", "Näme"].each do |name|
  bad = Edgeway::HTTP::Response.new(200, "")
  bad.headers[name] = "v"
  begin
    bad.to_cgi
    puts "accepted #{name.inspect}"
  rescue Edgeway::InvalidHeader => e
    puts e.message
  end
end
["a\nStatus: 302", "a\rb", "a\0b"].each do |value|
  bad = Edgeway::HTTP::Response.new(200, "")
  bad.headers["X-Name"] = value
  begin
    bad.to_cgi
    puts "accepted #{value.inspect}"
  rescue Edgeway::InvalidHeader => e
    puts e.message
  end
end

class StatsLogger
  def info(message)
    puts "info #{message}"
  end

  def error(message)
    puts "error #{message}"
  end
end
Edgeway.logger = StatsLogger.new
stats_db = Edgeway::DB::MemoryAdapter.new
Edgeway::Model.connection = stats_db
run("/health")
stats_db.record_meta(JSON.parse('{"rows_read":3,"rows_written":1,"duration":2,"served_by_region":"WEUR","served_by_primary":true}'))
run("/health")
analytics_stats_db = Edgeway::DB::MemoryAdapter.new
Edgeway::Model.connect(:analytics, analytics_stats_db)
run("/health")
analytics_stats_db.record_meta(JSON.parse('{"rows_read":5,"rows_written":0,"duration":1.5,"served_by_region":"WEUR","served_by_primary":true}'))
run("/health")
