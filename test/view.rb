# Views: Edgeway::View.escape, and render of templates, layout and html:.
# The _view_*/_render_view/_render_layout methods are written by hand, as
# `edgeway build` generates them from app/views (see test/cli/view_compiler.rb).
require "edgeway"

puts Edgeway::View.escape("<a href=\"x\">Tom & 'Jerry'</a>")
puts Edgeway::View.escape(nil).inspect
puts Edgeway::View.escape(42)
puts Edgeway::View.escape("plain")
puts Edgeway::View.escape("&&<<>>\"\"''")

class ApplicationController < Edgeway::Controller::Base
  def _render_layout(content)
    out = +""
    out << "<main>" << content << "</main>"
    out
  end
end

class PostsController < ApplicationController
  def index
    @posts = ["a<b", "c&d"]
  end

  def show
    @title = "T"
    render
  end

  def named
    @posts = ["n"]
    render("index")
  end

  def index_bare
    @posts = ["b"]
    render "index", layout: false
  end

  def plain = render(html: "<p>hi</p>", status: :created)

  def raw = render(html: "<p>raw</p>", layout: false)

  def bad = render(:nope)

  def gone
  end

  def _view_posts_index
    out = +""
    out << "<ul>\n"
    @posts.each do |p|
      out << "<li>" << Edgeway::View.escape(p) << "</li>\n"
    end
    out << "</ul>\n"
    out
  end

  def _view_posts_show
    out = +""
    out << "<h1>" << Edgeway::View.escape(@title) << "</h1>"
    out
  end

  def _render_view(action)
    case action
    when "index" then _view_posts_index
    when "show" then _view_posts_show
    else super
    end
  end
end

# a controller with templates of its own still renders the inherited ones
class BaseController < ApplicationController
  def _view_base_shared = "<i>shared</i>"

  def _render_view(action)
    case action
    when "shared" then _view_base_shared
    else super
    end
  end
end

class NotesController < BaseController
  rescue_from Edgeway::MissingTemplate, with: :no_page

  def no_page(_e) = head(:not_found)

  def shared = render(layout: false)
  def mine = render(layout: false)
  def nope = render(layout: false)

  def _view_notes_mine = "<b>mine</b>"

  def _render_view(action)
    case action
    when "mine" then _view_notes_mine
    else super
    end
  end
end

# a controller with no templates
class PlainController < ApplicationController
  def hello = render(json: { "a" => 1 })
  def null = render(json: nil)
  def empty = render(html: nil, layout: false)
  def nothing
  end
end

Edgeway.application.routes.draw do |r|
  r.get "/posts", to: "posts#index"
  r.get "/posts/show", to: "posts#show"
  r.get "/posts/named", to: "posts#named"
  r.get "/posts/bare", to: "posts#index_bare"
  r.get "/posts/plain", to: "posts#plain"
  r.get "/posts/raw", to: "posts#raw"
  r.get "/posts/bad", to: "posts#bad"
  r.get "/posts/gone", to: "posts#gone"
  r.get "/posts/_view_posts_index", to: "posts#_view_posts_index"
  r.get "/posts/_render_view", to: "posts#_render_view"
  r.get "/notes/shared", to: "notes#shared"
  r.get "/notes/mine", to: "notes#mine"
  r.get "/notes/nope", to: "notes#nope"
  r.get "/plain", to: "plain#hello"
  r.get "/plain/null", to: "plain#null"
  r.get "/plain/empty", to: "plain#empty"
  r.get "/plain/nothing", to: "plain#nothing"
end

def call(path)
  res = Edgeway.application.call(Edgeway::HTTP::Request.new("GET", path, "", "", ""))
  puts "GET #{path} -> #{res.status} #{res.headers.inspect} #{res.body.inspect}"
end

# the action sets @posts and renders nothing: its template is rendered
call("/posts")
call("/posts/show")
call("/posts/named")
call("/posts/bare")
call("/posts/plain")
call("/posts/raw")
# a template that doesn't exist: a 500 with the fixed body
call("/posts/bad")
# no template for an action that renders nothing: 204
call("/posts/gone")
# the generated methods are not actions
call("/posts/_view_posts_index")
call("/posts/_render_view")
# an inherited template, the controller's own, and neither
call("/notes/shared")
call("/notes/mine")
# a missing template leaves no html headers on what a handler answers
call("/notes/nope")
# json is as before; no templates at all
call("/plain")
# an explicit nil is a value: json: nil is null, html: nil an empty body
call("/plain/null")
call("/plain/empty")
call("/plain/nothing")
