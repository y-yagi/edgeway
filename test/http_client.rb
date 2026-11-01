require "edgeway"
require "edgeway/http/stub_transport"

transport = Edgeway::HTTP::StubTransport.new
Edgeway::HTTP.client = transport

transport.stub(:get, "https://api.example/items", 200, "{\"items\":[1,2]}", { "Content-Type" => "application/json", "X-Id" => "7" })
transport.stub("POST", "https://api.example/items", 201, "created", {})
transport.stub(:get, "https://api.example/missing", 404, "no", {})
transport.stub(:get, "https://api.example/moved", 302, "", { "Location" => "https://api.example/items" })
transport.stub(:get, "https://api.example/text", 200, "café 日本", {})
transport.stub_error(:get, "https://api.example/down", "connection refused", false)
transport.stub_error(:get, "https://api.example/slow", "request timed out", true)

response = Edgeway::HTTP.get("https://api.example/items")
p response.status
p response.success?
p response.headers
p response.body
p response.json["items"]

created = Edgeway::HTTP.post("https://api.example/items", body: "{\"name\":\"a\"}", headers: { "Authorization" => "Bearer t" })
p created.status
p created.body

missing = Edgeway::HTTP.get("https://api.example/missing")
p missing.status
p missing.success?

moved = Edgeway::HTTP.get("https://api.example/moved")
p moved.status
p moved.success?
p moved.headers["location"]

text = Edgeway::HTTP.get("https://api.example/text")
p text.body
p text.body.length

begin
  Edgeway::HTTP.get("https://api.example/down")
rescue Edgeway::HTTP::Error => e
  puts "#{e.class}: #{e.message}"
end

begin
  Edgeway::HTTP.get("https://api.example/slow", timeout: 2)
rescue Edgeway::HTTP::Error => e
  puts "#{e.class}: #{e.message}"
  p e.is_a?(Edgeway::HTTP::Timeout)
  p e.is_a?(Edgeway::Error)
end

begin
  Edgeway::HTTP.get("https://api.example/unknown")
rescue Edgeway::HTTP::UnstubbedRequest => e
  puts "#{e.class}: #{e.message}"
end

[0, -1, 0.0004, 301, 5_000_000].each do |bad|
  begin
    Edgeway::HTTP.delete("https://api.example/items", timeout: bad)
  rescue ArgumentError => e
    puts "#{bad}: #{e.message}"
  end
end
transport.stub(:delete, "https://api.example/items", 204, "", {})
Edgeway::HTTP.delete("https://api.example/items", timeout: 300)
Edgeway::HTTP.delete("https://api.example/items", timeout: 0.001)
puts transport.requests.last(2).map { |sent| sent["timeout_ms"] }

transport.requests.each do |sent|
  puts "#{sent["method"]} #{sent["url"]} #{sent["body"].inspect} #{sent["headers"].inspect} #{sent["timeout_ms"]}"
end

transport.stub(:put, "https://api.example/items", 200, "", {})
transport.stub(:patch, "https://api.example/items", 200, "", {})
Edgeway::HTTP.put("https://api.example/items", body: "x", timeout: 3)
Edgeway::HTTP.patch("https://api.example/items")
puts transport.requests.last(2).map { |sent| "#{sent["method"]} #{sent["body"].inspect} #{sent["timeout_ms"]}" }

Edgeway::HTTP.client = Edgeway::HTTP::Transport.new
begin
  Edgeway::HTTP.get("https://api.example/items")
rescue Edgeway::HTTP::Error => e
  puts e.message
end

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

Edgeway.application.routes.draw do |r|
  r.get "/partner", to: "partners#show"
  r.get "/partner/slow", to: "partners#slow"
  r.get "/partner/items", to: "partners#items"
end

Edgeway::HTTP.client = transport
["/partner", "/partner/slow", "/partner/items"].each do |path|
  reply = Edgeway.application.call(Edgeway::HTTP::Request.new("GET", path, "", "", ""))
  puts "#{path} -> #{reply.status} #{reply.body.strip}"
end
