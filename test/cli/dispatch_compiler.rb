# edgeway's routes -> Ruby: the dispatch code generated from config/routes.rb. CRuby only.
require "tmpdir"
require "fileutils"
require_relative "../../lib/edgeway/cli"

def write(root, path, text = "")
  full = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(full))
  File.write(full, text)
end

def compile(root, routes, controllers, library_lines = [])
  write(root, "config/routes.rb", "Edgeway.application.routes.draw do |r|\n#{routes}\nend\n")
  controllers.each { |path, text| write(root, "app/controllers/#{path}_controller.rb", text) }
  Edgeway::CLI::Build::DispatchCompiler.new(root, ['require "edgeway"', *library_lines]).compile
end

def failure(root, routes, controllers, library_lines = [])
  compile(root, routes, controllers, library_lines)
rescue Edgeway::CLI::Error => e
  e.message
end

application = <<~RUBY
  class ApplicationController < Edgeway::Controller::Base
    def inherited_action = render(json: {})

    private

    def hidden = nil
  end
RUBY
todos = <<~RUBY
  class TodosController < ApplicationController
    before_action :check

    def index = render(json: [])
    def show = render(json: {})

    private

    def check = nil
  end
RUBY
posts = <<~RUBY
  module Admin
    class PostsController < ApplicationController
      def index = render(json: [])
    end
  end
RUBY
controllers = { "application" => application, "todos" => todos, "admin/posts" => posts }

Dir.mktmpdir do |root|
  routes = <<~RUBY
    r.resources :todos, only: [:index, :show]
    r.get "/todos/again", to: "todos#index"
    r.get "/admin", to: "admin/posts#index"
    r.get "/inherited", to: "todos#inherited_action"
  RUBY
  puts compile(root, routes, controllers)
end

puts "--"
Dir.mktmpdir do |root|
  p compile(root, "", controllers)
end

puts "--"
{
  "an undefined action" => 'r.get "/todos/nope", to: "todos#nope"',
  "an undefined controller" => 'r.get "/ghosts", to: "ghosts#index"',
  "a private method" => 'r.get "/todos/check", to: "todos#check"',
  "a private method of the parent" => 'r.get "/todos/hidden", to: "todos#hidden"',
  "a method of Base" => 'r.get "/todos/render", to: "todos#render"',
  "the generated method" => 'r.get "/todos/run", to: "todos#_run_action"',
  "a class that is not a controller" => 'r.get "/strings", to: "strings#index"',
  "a module" => 'r.get "/helpers", to: "helpers#index"',
  "a name that is not a method name" => 'r.get "/todos/odd", to: "todos#odd-name"'
}.each do |label, route|
  Dir.mktmpdir do |root|
    puts "#{label}:", failure(root, route, controllers.merge("strings" => "class StringsController\n  def index = nil\nend\n", "helpers" => "module HelpersController\nend\n"))
  end
end

puts "--"
Dir.mktmpdir do |root|
  puts failure(root, 'r.get "/a", to: "todos#nope"' + "\n" + 'r.get "/b", to: "ghosts#index"', controllers)
end

puts "--"
Dir.mktmpdir do |root|
  puts failure(root, 'r.get "/a", to: "todos#index"', controllers.merge("todos" => "raise 'boom'")).lines[0..1].join.sub(root, "ROOT")
end

puts "--"
special = "class SpecialController < Edgeway::Controller::Base\n  def action = nil\n  def then = nil\n  def end = nil\n  def publish! = nil\n  def ready? = nil\nend\n"
Dir.mktmpdir do |root|
  routes = %w[action then end publish! ready?].map { |name| %(r.get "/#{name.delete("!?")}", to: "special##{name}") }.join("\n")
  puts compile(root, routes, { "special" => special }).lines.grep(/when/)
end

puts "--"
Dir.mktmpdir do |root|
  puts compile(root, 'r.get "/a", to: "todos#index"', controllers.merge("todos" => "puts 'loading'\n" + todos)).lines.grep(/when/)
end

Dir.mktmpdir do |root|
  puts compile(root, 'r.get "/a", to: "todos#index"', controllers.merge("todos" => "exit 0"))
rescue Edgeway::CLI::Error => e
  puts e.message.lines.first
end

puts "--"
library = ['require "edgeway/db/memory"', 'require "edgeway/service/jwt"']
adapter_user = "ADAPTER = Edgeway::DB::MemoryAdapter\n" + todos
Dir.mktmpdir do |root|
  puts compile(root, 'r.get "/a", to: "todos#index"', controllers.merge("todos" => adapter_user), library).lines.grep(/when/)
end
