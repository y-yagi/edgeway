# edgeway generate: the files it writes for a model and a controller, the
# migration numbering, and its errors. CRuby only.
require "tmpdir"
require "stringio"
require "fileutils"
require_relative "../../lib/edgeway/cli"

def gen(root, *args)
  out = StringIO.new
  $stdout = out
  Dir.chdir(root) { Edgeway::CLI::Generate.run(args) }
  out.string
ensure
  $stdout = STDOUT
end

def show(root, rel)
  puts "-- #{rel}"
  puts File.read(File.join(root, rel))
end

Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, "config"))
  File.write(File.join(root, "config/routes.rb"), "")

  puts gen(root, "model", "Todo", "title:string", "done:boolean", "priority:integer", "due:datetime")
  show(root, "app/models/todo.rb")
  show(root, "db/migrations/0001_create_todos.sql")
  show(root, "test/models/todo_test.rb")

  puts gen(root, "model", "blog_post")
  puts Dir.children(File.join(root, "db/migrations")).sort

  puts gen(root, "controller", "Todos", "index", "show", "archive")
  show(root, "app/controllers/todos_controller.rb")
  show(root, "test/controllers/todos_test.rb")
  puts gen(root, "controller", "Tags")
  show(root, "app/controllers/tags_controller.rb")
end

puts "--"
[
  ["model", "Todo"], # not in an app
  ["widget", "Todo"],
  ["model"]
].each do |args|
  Dir.mktmpdir do |dir|
    gen(dir, *args)
  rescue Edgeway::CLI::Error => e
    puts e.message.lines.first.sub(File.realpath(dir), "DIR").sub(dir, "DIR")
  end
end

Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, "config"))
  File.write(File.join(root, "config/routes.rb"), "")
  gen(root, "model", "Todo")
  [["model", "Todo"], ["model", "Bad", "x:blob"], ["controller", "Todos", "Bad-Action"]].each do |args|
    gen(root, *args)
  rescue Edgeway::CLI::Error => e
    puts e.message
  end
end
