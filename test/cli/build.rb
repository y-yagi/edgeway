# edgeway build's main.rb: the order of the requires and the connection line,
# without invoking Spinel. CRuby only (the CLI is not part of the wasm).
require "tmpdir"
require "fileutils"
require_relative "../../lib/edgeway/cli"

def write(root, path, text = "")
  full = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(full))
  File.write(full, text)
end

def main_for(root, env, database_yml)
  write(root, "config/database.yml", database_yml)
  config = Edgeway::CLI::Build::AppConfig.load(root, env)
  FileUtils.mkdir_p(File.join(root, "build"))
  Edgeway::CLI::Build.new(root, env).send(:write_main, config)
  File.read(File.join(root, "build/main.rb"))
end

Dir.mktmpdir do |root|
  %w[app/models/todo app/models/application_model app/models/concerns/taggable
     app/controllers/todos_controller app/controllers/application_controller app/controllers/admin/stats_controller
     app/services/zip app/services/application_service app/jobs/job
     config/routes].each { |f| write(root, "#{f}.rb") }
  write(root, "app/models/notes.txt")
  yml = "development:\n  adapter: d1\n  binding: MYDB\ntest:\n  adapter: memory\n"
  puts main_for(root, "development", yml)
  puts "--"
  puts main_for(root, "test", yml)
end

puts "--"
# a path that needs quoting stays one string in the generated Ruby
Dir.mktmpdir do |root|
  write(root, 'app/models/we"ird #{x}.rb')
  write(root, "config/routes.rb")
  out = main_for(root, "test", "test:\n  adapter: memory\n")
  puts out.lines.grep(/weird|we/)
  line = out.lines.find { |l| l.include?("ird") }
  puts eval(line.sub("require_relative ", "")) # the string it holds
end

puts "--"
# app/views: build/views.rb is written and required after the controllers,
# before the routes
Dir.mktmpdir do |root|
  write(root, "app/controllers/todos_controller.rb")
  write(root, "app/views/todos/index.html.erb", "<%= 1 %>")
  write(root, "config/routes.rb")
  out = main_for(root, "test", "test:\n  adapter: memory\n")
  puts out.lines.grep(/require_relative/)
  puts File.exist?(File.join(root, "build/views.rb"))
end

# a views directory with no controller fails the build
Dir.mktmpdir do |root|
  write(root, "app/views/ghosts/index.html.erb", "x")
  write(root, "config/routes.rb")
  begin
    main_for(root, "test", "test:\n  adapter: memory\n")
  rescue Edgeway::CLI::Error => e
    puts e.message
  end
end

begin
  Dir.mktmpdir { |root| Edgeway::CLI::Build.new(root, "test").run }
rescue Edgeway::CLI::Error => e
  puts e.message.sub(/ in .*/, "")
end
