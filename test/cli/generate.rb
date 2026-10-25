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

# scaffold: files, the route added to a realistic routes.rb, no fields, rerun
ROUTES = <<~RUBY
  Edgeway.application.routes.draw do |r|
    r.get "/health", to: "health#show"
    r.root to: "health#show"
  end
RUBY

Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, "config"))
  File.write(File.join(root, "config/routes.rb"), ROUTES)

  puts gen(root, "scaffold", "Todo", "title:string", "done:boolean", "priority:integer", "score:float", "due:datetime")
  %w[app/models/todo.rb db/migrations/0001_create_todos.sql test/models/todo_test.rb
     app/controllers/todos_controller.rb test/controllers/todos_test.rb config/routes.rb].each { |f| show(root, f) }

  puts gen(root, "scaffold", "Tag")
  %w[app/controllers/tags_controller.rb test/controllers/tags_test.rb config/routes.rb].each { |f| show(root, f) }

  # a rerun stops at the migration of the first run, nothing is written
  begin
    gen(root, "scaffold", "Tag")
  rescue Edgeway::CLI::Error => e
    puts e.message
  end
  begin
    gen(root, "model", "Tag")
  rescue Edgeway::CLI::Error => e
    puts e.message
  end
  puts Dir.children(File.join(root, "db/migrations")).sort

  # a plural name is singularized
  puts gen(root, "scaffold", "Posts", "title:string")
  show(root, "app/controllers/posts_controller.rb")
end

# a name ending in "us" takes "es" in the plural
Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, "config"))
  File.write(File.join(root, "config/routes.rb"), "Edgeway.application.routes.draw do |r|\nend\n")
  puts gen(root, "scaffold", "Status", "title:string")
  puts Dir.children(File.join(root, "db/migrations")).sort
  show(root, "app/models/status.rb")
  show(root, "app/controllers/statuses_controller.rb")
  show(root, "config/routes.rb")
end

# a route that is already there is not added twice, whatever its form
[
  "r.resources :tags",
  "r.resources :tags, only: [:index]",
  "r.resources(:tags)",
  "r.resources   :tags",
  "r.resources :tags do |t|\n    t.get \"/x\", to: \"tags#x\"\n  end"
].each do |route|
  Dir.mktmpdir do |root|
    FileUtils.mkdir_p(File.join(root, "config"))
    routes = "Edgeway.application.routes.draw do |r|\n  #{route}\nend\n"
    File.write(File.join(root, "config/routes.rb"), routes)
    puts gen(root, "scaffold", "Tag").lines.grep(/identical|route/)
    puts File.read(File.join(root, "config/routes.rb")) == routes
  end
end

# the route goes last (after "/todos/search"), at the draw line's indentation + 2;
# `do  |r|`, `do | r |` and CRLF are matched, and CRLF is kept
{
  "nested" => "module App\n  Edgeway.application.routes.draw do  | r |\n    r.get \"/todos/search\", to: \"todos#search\"\n    # end\n  end\nend\n",
  "crlf" => "Edgeway.application.routes.draw do |r|\r\n  r.root to: \"health#show\"\r\nend\r\n",
  "no end" => "Edgeway.application.routes.draw do |r|\n  r.root to: \"health#show\"\n"
}.each do |name, routes|
  Dir.mktmpdir do |root|
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config/routes.rb"), routes)
    puts "-- #{name}"
    puts gen(root, "scaffold", "Todo").lines.grep(/route|Add|r\.res/)
    puts File.read(File.join(root, "config/routes.rb")).inspect
  end
end
# no `draw do |x|`: routes.rb is left alone and the reason and the hint are printed
Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, "config"))
  File.write(File.join(root, "config/routes.rb"), "# custom\n")
  puts gen(root, "scaffold", "Note")
  puts File.read(File.join(root, "config/routes.rb"))
end

# a file in the way: nothing is written, routes.rb is untouched
Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, "config"))
  File.write(File.join(root, "config/routes.rb"), ROUTES)
  FileUtils.mkdir_p(File.join(root, "app/controllers"))
  File.write(File.join(root, "app/controllers/todos_controller.rb"), "")
  begin
    gen(root, "scaffold", "Todo")
  rescue Edgeway::CLI::Error => e
    puts e.message
  end
  puts Dir.glob("**/*", base: root).select { |f| File.file?(File.join(root, f)) }.sort
  puts File.read(File.join(root, "config/routes.rb")) == ROUTES
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
