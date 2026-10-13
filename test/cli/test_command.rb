# edgeway test's generated loader (tmp/test_app.rb), without invoking Spinel.
# CRuby only.
require "tmpdir"
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

begin
  Dir.mktmpdir { |root| Edgeway::CLI::Test.new(root).write_test_app }
rescue Edgeway::CLI::Error => e
  puts e.message.sub(/ in .*/, "")
end
