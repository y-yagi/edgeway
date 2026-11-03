require "edgeway"
require "edgeway/http/auth/stub"
require "edgeway/rate_limit/stub_limiter"
require "edgeway/service/cloudflare/rate_limiter"

class RecordingLogger < Edgeway::Logger
  attr_reader :lines

  def initialize
    @lines = []
  end

  def warn(message, fields = {})
    @lines << "warn #{message} #{JSON.generate(fields)}"
  end

  def info(message, fields = {})
    @lines << "info #{message} #{JSON.generate(fields)}"
  end

  def error(message, fields = {})
    @lines << "error #{message} #{JSON.generate(fields)}"
  end
end

class FakeRateLimitTransport < Edgeway::Cloudflare::RateLimitTransport
  attr_reader :calls

  def initialize(answer)
    @answer = answer
    @calls = []
  end

  def check(binding_name, key)
    @calls << "#{binding_name} #{key}"
    @answer
  end
end

class ApplicationController < Edgeway::Controller::Base
  private

  def rate_limit_key = "tenant-#{request.header("X-Tenant")}"
end

class PostsController < ApplicationController
  rate_limit "WRITE_LIMITER", only: [:create]

  def index = render(json: { "ok" => "index" })
  def create = render(json: { "ok" => "create" })
end

class ReportsController < ApplicationController
  rate_limit "READ_LIMITER", by: :rate_limit_key, retry_after: 30, except: [:show]
  rate_limit "BURST_LIMITER", name: "reports", retry_after: 5

  def index = render(json: { "ok" => "index" })
  def show = render(json: { "ok" => "show" })
end

class ArchivesController < ReportsController
  def index = render(json: { "ok" => "archive" })
end

class AccountsController < ApplicationController
  before_action :authenticate!
  rate_limit "ACCOUNT_LIMITER"

  def show = render(json: { "ok" => "show" })
end

class CustomController < ApplicationController
  rate_limit "CUSTOM_LIMITER", retry_after: 9

  rescue_from Edgeway::TooManyRequests, with: :slow_down

  def index = render(json: { "ok" => "index" })

  def slow_down(error)
    render json: { "slow" => error.retry_after }, status: 503
  end
end

class HaltedController < ApplicationController
  before_action :refuse
  rate_limit "HALTED_LIMITER"

  def index = render(json: { "ok" => "index" })

  private

  def refuse = render(json: { "refused" => true }, status: 403)
end

class ChildAuthController < PostsController
  before_action :authenticate!

  def index = render(json: { "ok" => "child" })
end

class AccountKeyController < ApplicationController
  rate_limit "ACCOUNT_KEY_LIMITER", by: :account_id
  rate_limit "NOTHING_LIMITER", by: :nothing

  def index = render(json: { "ok" => "index" })

  private

  def account_id = 42
  def nothing = nil
end

class PublicByController < ApplicationController
  rate_limit "PUBLIC_BY_LIMITER", by: :tenant_key

  def index = render(json: { "ok" => "index" })
  def tenant_key = "t1"
end

class PublicByChildController < PublicByController
end

class OpenController < ApplicationController
  def index = render(json: { "ok" => "open" })
end

Edgeway.application.routes.draw do |r|
  r.get "/posts", to: "posts#index"
  r.post "/posts", to: "posts#create"
  r.get "/reports", to: "reports#index"
  r.get "/reports/1", to: "reports#show"
  r.get "/archives", to: "archives#index"
  r.get "/account", to: "accounts#show"
  r.get "/custom", to: "custom#index"
  r.get "/open", to: "open#index"
  r.get "/public_by", to: "public_by#index"
  r.get "/public_by/tenant_key", to: "public_by#tenant_key"
  r.get "/public_by_child/tenant_key", to: "public_by_child#tenant_key"
  r.get "/halted", to: "halted#index"
  r.get "/child", to: "child_auth#index"
  r.get "/account_key", to: "account_key#index"
end

verifier = Edgeway::Auth::StubVerifier.new
Edgeway::Auth.verifier = verifier
ENV["JWT_ISSUER"] = "https://idp.example/"
ENV["JWT_AUDIENCE"] = "api"
verifier.allow("good", { "sub" => "u1", "exp" => Time.now.to_i + 600, "iss" => "https://idp.example/", "aud" => "api" })

limiter = Edgeway::RateLimit::StubLimiter.new
Edgeway::Controller.rate_limiter = limiter
logger = RecordingLogger.new
Edgeway.logger = logger

def call(verb, path, headers = {})
  headers.each { |name, value| ENV["HTTP_" + name.upcase.gsub("-", "_")] = value }
  res = Edgeway.application.call(Edgeway::HTTP::Request.new(verb, path, "", "", ""))
  headers.each { |name, _value| ENV.delete("HTTP_" + name.upcase.gsub("-", "_")) }
  retry_after = res.headers["Retry-After"]
  puts "#{verb} #{path} -> #{res.status} #{res.body.strip}#{retry_after ? " (Retry-After: #{retry_after})" : ""}"
end

def print_checks(limiter)
  limiter.checks.each { |pair| puts "  checked #{pair[0]} #{pair[1]}" }
  limiter.checks.clear
end

def refused
  yield
  puts "accepted"
rescue ArgumentError => e
  puts "ArgumentError: #{e.message}"
end

ENV["REMOTE_ADDR"] = "203.0.113.7"

puts "-- the default limiter allows everything"
Edgeway::Controller.rate_limiter = Edgeway::RateLimit::NullLimiter.new
call("GET", "/open")
call("POST", "/posts")
Edgeway::Controller.rate_limiter = limiter

puts "-- only and except"
call("GET", "/posts")
call("POST", "/posts")
print_checks(limiter)
call("GET", "/reports/1")
print_checks(limiter)

puts "-- the key is per controller, and by: picks the rest"
call("GET", "/reports", { "X-Tenant" => "t1" })
print_checks(limiter)
call("GET", "/archives", { "X-Tenant" => "t1" })
print_checks(limiter)

puts "-- the default key of an authenticated request"
call("GET", "/account", { "Authorization" => "Bearer good" })
print_checks(limiter)
call("GET", "/account")
print_checks(limiter)

puts "-- an empty client address, a by: answering an Integer and nil"
ENV["REMOTE_ADDR"] = ""
call("POST", "/posts")
print_checks(limiter)
ENV["REMOTE_ADDR"] = "203.0.113.7"
call("GET", "/account_key")
print_checks(limiter)

puts "-- order: a before_action that renders comes first"
call("GET", "/halted")
print_checks(limiter)

puts "-- order: a parent's rate_limit runs before the child's authenticate!"
call("GET", "/child")
print_checks(limiter)
call("GET", "/child", { "Authorization" => "Bearer good" })
print_checks(limiter)

puts "-- IPv6 clients are keyed by their /64"
["2001:db8:1:2:aaaa:bbbb:cccc:dddd", "2001:0DB8:0001:0002::1", "2001:db8:1:2::", "::1", "::", "1::", "::ffff:192.0.2.1",
 "::ffff:c000:201", "0:0:0:0:0:ffff:192.0.2.1", "0000:0000:0000:0000:0000:FFFF:C000:0201", "::FFFF:192.000.002.001",
 "::ffff:192.0.2", "::ffff:192.0.2.256", "::fffe:192.0.2.1", "1::ffff:c000:201", "::1:ffff:c000:201", "64:ff9b::192.0.2.1",
 "fe80::1%eth0", "2001:db8::1:2:3", "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", "12345::1", "g::1",
 "1:2:3:4:5:6:7::", "198.51.100.9", "not-an-address:"].each do |address|
  puts "#{address} -> #{Edgeway::Controller::RateLimiting.address_key(address)}"
end
ENV["REMOTE_ADDR"] = "2001:db8:1:2:ffff:ffff:ffff:ffff"
call("POST", "/posts")
print_checks(limiter)
ENV["REMOTE_ADDR"] = "203.0.113.7"

puts "-- the client address"
ENV.delete("REMOTE_ADDR")
p Edgeway::HTTP::Request.new("GET", "/", "", "", "").remote_addr
ENV["REMOTE_ADDR"] = "198.51.100.4"
p Edgeway::HTTP::Request.new("GET", "/", "", "", "").remote_addr
ENV["REMOTE_ADDR"] = "203.0.113.7"

puts "-- exceeded"
limiter.stub("WRITE_LIMITER", true)
call("GET", "/posts")
call("POST", "/posts")
limiter.stub("WRITE_LIMITER", false)
call("POST", "/posts")
limiter.stub("READ_LIMITER", true)
call("GET", "/reports", { "X-Tenant" => "t1" })
call("GET", "/reports/1")
limiter.stub("READ_LIMITER", false)
limiter.stub("BURST_LIMITER", true)
call("GET", "/reports", { "X-Tenant" => "t1" })
print_checks(limiter)
limiter.stub("BURST_LIMITER", false)

puts "-- rescue_from"
limiter.stub("CUSTOM_LIMITER", true)
call("GET", "/custom")
limiter.stub("CUSTOM_LIMITER", false)

puts "-- the log has no key"
logger.lines.clear
limiter.stub("WRITE_LIMITER", true)
call("POST", "/posts")
puts logger.lines
limiter.stub("WRITE_LIMITER", false)
limiter.checks.clear

puts "-- a by: method is not an action"
call("GET", "/public_by")
print_checks(limiter)
call("GET", "/public_by/tenant_key")
call("GET", "/public_by_child/tenant_key")
request = Edgeway::HTTP::Request.new("GET", "/", "", "", "")
p PublicByController.new(request).action?("tenant_key")
p PublicByChildController.new(request).action?("tenant_key")
p PublicByController.new(request).action?("index")
p PostsController.new(request).action?("tenant_key")

puts "-- TooManyRequests"
p Edgeway::TooManyRequests.new.retry_after
p Edgeway::TooManyRequests.new("slow", nil).retry_after
p Edgeway::TooManyRequests.new("slow", 7).retry_after
p Edgeway::TooManyRequests.new("slow", "10").retry_after
p Edgeway::TooManyRequests.new("slow", -1).retry_after
p Edgeway::TooManyRequests.new("slow", 1.5).retry_after
puts Edgeway.application.rescue_default(Edgeway::TooManyRequests.new("slow", nil)).status

puts "-- macro arguments"
refused { PostsController.rate_limit(:WRITE_LIMITER) }
refused { PostsController.rate_limit("") }
refused { PostsController.rate_limit("A", by: "key") }
refused { PostsController.rate_limit("A", name: :scope) }
refused { PostsController.rate_limit("A", retry_after: 0) }
refused { PostsController.rate_limit("A", retry_after: 1.5) }
refused { PostsController.rate_limit("A", retry_after: "5") }

puts "-- the base limiter"
begin
  Edgeway::RateLimit::Limiter.new.exceeded?("A", "k")
rescue Edgeway::Error => e
  puts e.message
end

puts "-- the stub limiter"
stub = Edgeway::RateLimit::StubLimiter.new
p stub.exceeded?("A", "k")
stub.stub("A", true)
p stub.exceeded?("A", "k")
p stub.exceeded?("B", "k")
stub.stub("A", false)
p stub.exceeded?("A", "k")
p stub.checks.length

puts "-- the transport limiter"
def ask(answer)
  transport = FakeRateLimitTransport.new(answer)
  limiter = Edgeway::Cloudflare::RateLimiter.new(transport: transport)
  puts "#{limiter.exceeded?("API_LIMITER", "user:1")} #{transport.calls.join(",")}"
end

ask("{\"success\":true}")
ask("{\"success\":false}")
logger.lines.clear
ask("{\"error\":\"invalid key: 1\"}")
ask("{}")
begin
  ask("{\"misconfigured\":\"no rate limit binding API_LIMITER\"}")
rescue Edgeway::Error => e
  puts "#{e.class}: #{e.message}"
end
puts Edgeway.application.rescue_default(Edgeway::ConfigurationError.new("rate limit: no rate limit binding API_LIMITER")).status

puts "-- the binding gets a digest of the key"
class KeyRecordingTransport < Edgeway::Cloudflare::RateLimitTransport
  attr_reader :keys

  def initialize
    @keys = []
  end

  def check(binding_name, key)
    @keys << key
    "{\"success\":true}"
  end
end
recorder = KeyRecordingTransport.new
digesting = Edgeway::Cloudflare::RateLimiter.new(transport: recorder)
invalid_one = "key".b + [0xff].pack("C")
invalid_two = "key".b + [0xfe].pack("C")
["user:1", invalid_one, invalid_two, "abc\0x1", "abc\0x2", "日本"].each { |key| digesting.exceeded?("API_LIMITER", key) }
puts recorder.keys
p recorder.keys.map { |key| key.length }.uniq
p recorder.keys.uniq.length
p recorder.keys[0] == Digest::SHA256.hexdigest("user:1")
puts logger.lines
begin
  Edgeway::Cloudflare::RateLimitTransport.new.check("A", "k")
rescue Edgeway::Error => e
  puts e.message
end
