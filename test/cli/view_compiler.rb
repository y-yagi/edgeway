# edgeway's ERB -> Ruby: the code generated from app/views. CRuby only.
require "tmpdir"
require "fileutils"
require_relative "../../lib/edgeway/cli"

def write(root, path, text = "")
  full = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(full))
  File.write(full, text)
end

Dir.mktmpdir do |root|
  %w[application todos admin/posts].each { |c| write(root, "app/controllers/#{c}_controller.rb") }
  write(root, "app/views/layouts/application.html.erb", "<html>\n<body><%= @flash %>\n<%= yield %>\n</body>\n</html>\n")
  write(root, "app/views/todos/index.html.erb", <<~'ERB')
    <%# a comment %>
    <ul>
    <% @todos.each do |t| -%>
      <li class="<%= t.klass %>"><%= t.title %> <%== t.badge %></li>
    <% end -%>
    </ul>
    "quoted" #{not_interpolated} \ back <%% literal
  ERB
  write(root, "app/views/todos/show.html.erb", "<h1><%= @todo.title %></h1>")
  write(root, "app/views/admin/posts/index.html.erb", "posts")
  write(root, "app/views/todos/show.json.erb", "ignored")
  puts Edgeway::CLI::Build::ViewCompiler.new(root).compile
end

# <%- drops the indentation, one -%> drops one line break (even a CRLF), a
# comment in an output tag doesn't swallow the closing paren, <%== yield %>
# is the page too, and the trailing line numbers are those of the template
Dir.mktmpdir do |root|
  %w[application todos].each { |c| write(root, "app/controllers/#{c}_controller.rb") }
  write(root, "app/views/layouts/application.html.erb", "<%==   yield   %>|<%=yield%>\n")
  write(root, "app/views/todos/index.html.erb",
        "a\n  <%- if @x -%>\r\n\nb <%= @x # note\n%>\n  <%- end -%>\n<%== @y # raw %>\nlast <%= z %>")
  puts Edgeway::CLI::Build::ViewCompiler.new(root).compile
end

puts "--"
Dir.mktmpdir do |root|
  puts Edgeway::CLI::Build::ViewCompiler.new(root).compile.inspect
end

# a views directory without a controller, a template outside a directory,
# a bad name and an unclosed tag are errors
[
  ["app/views/ghosts/index.html.erb", "x", []],
  ["app/views/index.html.erb", "x", []],
  ["app/views/todos/Bad-Name.html.erb", "x", %w[todos]],
  ["app/views/todos/index.html.erb", "a\n<%= x", %w[todos]],
  ["app/views/todos/index.html.erb", "a\n\n<%= yield %>", %w[todos]],
  ["app/views/todos/index.html.erb", "a\n\n<%== yield %>", %w[todos]]
].each do |path, text, controllers|
  Dir.mktmpdir do |root|
    controllers.each { |c| write(root, "app/controllers/#{c}_controller.rb") }
    write(root, path, text)
    begin
      Edgeway::CLI::Build::ViewCompiler.new(root).compile
    rescue Edgeway::CLI::Error => e
      puts e.message
    end
  end
end
