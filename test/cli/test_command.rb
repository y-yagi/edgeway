# edgeway test's generated loader (tmp/test_app.rb), and an `edgeway test` run
# on a generated app (that one needs Spinel and spinel_test-unit).
require "tmpdir"
require "open3"
require "fileutils"
require_relative "../../lib/edgeway/cli"

def write(root, path)
  full = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(full))
  File.write(full, "")
end

Dir.mktmpdir do |root|
  %w[app/models/todo app/models/application_model app/controllers/todos_controller config/routes].each { |f| write(root, f + ".rb") }
  Edgeway::CLI::Test.new(root).write_test_app
  puts File.read(File.join(root, "tmp/test_app.rb")).sub(root, "ROOT")
  puts "build/ untouched: #{!Dir.exist?(File.join(root, "build"))}"
  puts "--"
  write(root, "app/services/zip.rb") # a new file is picked up on the next run
  Edgeway::CLI::Test.new(root).write_test_app
  puts File.read(File.join(root, "tmp/test_app.rb")).lines.grep(/services/)
end

puts "--"
# app/views: tmp/views.rb, required after the controllers
Dir.mktmpdir do |root|
  %w[app/controllers/todos_controller config/routes].each { |f| write(root, f + ".rb") }
  FileUtils.mkdir_p(File.join(root, "app/views/todos"))
  File.write(File.join(root, "app/views/todos/index.html.erb"), "hi")
  Edgeway::CLI::Test.new(root).write_test_app
  puts File.read(File.join(root, "tmp/test_app.rb")).lines.grep(/require_relative/)
  puts File.read(File.join(root, "tmp/views.rb")).lines.grep(/def |class /)
end

begin
  Dir.mktmpdir { |root| Edgeway::CLI::Test.new(root).write_test_app }
rescue Edgeway::CLI::Error => e
  puts e.message.sub(/ in .*/, "")
end

begin
  Edgeway::CLI::Test.run(["--ruby"])
rescue Edgeway::CLI::Error => e
  puts e.message
end

puts "--"
Dir.mktmpdir do |root|
  write(root, "config/routes.rb")
  File.write(File.join(root, "config/database.yml"), <<~YML)
    development:
      adapter: d1
      databases:
        analytics:
          binding: ANALYTICS
    production:
      adapter: d1
      databases:
        analytics:
          binding: ANALYTICS
        audit_log:
          binding: AUDIT
    test:
      adapter: memory
  YML
  Edgeway::CLI::Test.new(root).write_test_app
  puts File.read(File.join(root, "tmp/test_app.rb")).lines.grep(/TEST_DATABASES/)
  File.write(File.join(root, "config/database.yml"), "test:\n  adapter: memory\n  databases:\n    analytics: {}\n")
  begin
    Edgeway::CLI::Test.new(root).write_test_app
  rescue Edgeway::CLI::Error => e
    puts e.message
  end
end

puts "--"
# test: adapter: d1 -> wasm on a local D1: another loader and runtime
Dir.mktmpdir do |root|
  write(root, "config/routes.rb")
  File.write(File.join(root, "config/database.yml"), <<~YML)
    test:
      adapter: d1
      binding: MAIN
      databases:
        analytics:
          binding: ANALYTICS
  YML
  database = Edgeway::CLI::Build::DatabaseConfig.new(root)
  puts database.section?("test"), database.section?("production")
  puts Edgeway::CLI::CloudflareTest.handles?(database)
  test = Edgeway::CLI::CloudflareTest.new(root)
  test.write_test_app
  puts File.read(File.join(root, "tmp/test_app.rb")).lines.first(9)
  test.send(:write_runtime)
  runtime = File.join(root, "tmp/edgeway")
  puts File.read(File.join(runtime, "config.js")).sub(root, "ROOT").gsub(root, "ROOT")
  puts Dir.children(runtime).sort.grep(/cloudflare-test|package/)
end

puts "--"
# IntegrationTest's remote_addr: and headers: in an app run by `edgeway test`
# (memory database, so no wrangler; needs Spinel and spinel_test-unit).
ECHO_CONTROLLER = <<~RUBY
  class EchoController < Edgeway::Controller::Base
    def show = render json: { "remote_addr" => request.remote_addr, "token" => request.header("X-Token") }
  end
RUBY

ECHO_TEST = <<~RUBY
  require "test_helper"

  class EchoTest < Edgeway::IntegrationTest
    def test_remote_addr_is_for_one_request
      get "/echo", remote_addr: "203.0.113.7"
      assert_equal "203.0.113.7", json["remote_addr"]
      get "/echo"
      assert_equal "", json["remote_addr"]
      assert_nil ENV["REMOTE_ADDR"]
    end

    def test_remote_addr_is_restored
      ENV["REMOTE_ADDR"] = "192.0.2.1"
      get "/echo", remote_addr: "203.0.113.7"
      assert_equal "192.0.2.1", ENV["REMOTE_ADDR"]
      ENV.delete("REMOTE_ADDR")
    end

    def test_header_is_for_one_request
      get "/echo", headers: { "X-Token" => "abc" }
      assert_equal "abc", json["token"]
      get "/echo"
      assert_equal "", json["token"]
      assert_nil ENV["HTTP_X_TOKEN"]
    end

    def test_header_set_before_is_restored
      ENV["HTTP_X_TOKEN"] = "before"
      get "/echo", headers: { "X-Token" => "abc" }
      assert_equal "before", ENV["HTTP_X_TOKEN"]
      ENV.delete("HTTP_X_TOKEN")
    end
  end
RUBY

def write_file(root, path, content)
  write(root, path)
  File.write(File.join(root, path), content)
end

def run_echo_tests(root)
  write_file(root, "app/controllers/echo_controller.rb", ECHO_CONTROLLER)
  write_file(root, "config/routes.rb", %(Edgeway.application.routes.draw { |r| r.get "/echo", to: "echo#show" }\n))
  write_file(root, "config/database.yml", "test:\n  adapter: memory\n")
  write_file(root, "test/test_helper.rb", %(require "edgeway/test"\n))
  write_file(root, "test/echo_test.rb", ECHO_TEST)
  exe = File.expand_path("../../exe/edgeway", __dir__)
  out, _status = Open3.capture2e("ruby", "-I", File.expand_path("../../lib", __dir__), exe, "test", chdir: root)
  out.lines.last.to_s.strip
end

if Edgeway::CLI::Toolchain.spinel && Edgeway::CLI::Toolchain.find_on_path("spinel_test-unit")
  Dir.mktmpdir { |root| puts run_echo_tests(root) }
else
  puts "skipped: no Spinel or spinel_test-unit"
end
