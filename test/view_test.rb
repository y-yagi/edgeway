require "spinel_test/unit"
require "edgeway"

class ViewTest < SpinelTest::Unit::TestCase
  class LayoutController < Edgeway::Controller::Base
    def _render_layout(content)
      out = +""
      out << "<main>" << content << "</main>"
      out
    end
  end

  class FramedController < LayoutController
    def show = render(html: "<p>body</p>".html_safe)

    def _render_layout(content)
      "<div>" + Edgeway::View.escape(raw("<hr>")) + content + "</div>"
    end
  end

  class PostsController < LayoutController
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

    def plain = render(html: "<p>hi</p>".html_safe, status: :created)

    def bare = render(html: "<script>alert(1)</script>", layout: false)

    def marked = render(html: "<b>ok</b>".html_safe, layout: false)
    def wrapped = render(html: raw("<i>ok</i>"), layout: false)
    def raw_in_layout = render(html: raw("<u>ok</u>"))

    def bad = render(:nope)

    def gone
    end

    def _view_view_test_posts_index
      out = +""
      out << "<ul>\n"
      @posts.each do |post|
        out << "<li>" << Edgeway::View.escape(post) << "</li>\n"
      end
      out << "</ul>\n"
      out
    end

    def _view_view_test_posts_show
      out = +""
      out << "<h1>" << Edgeway::View.escape(@title) << "</h1>"
      out
    end

    def _render_view(action)
      case action
      when "index" then _view_view_test_posts_index
      when "show" then _view_view_test_posts_show
      else super
      end
    end
  end

  class BaseController < LayoutController
    def _view_view_test_base_shared = "<i>shared</i>"

    def _render_view(action)
      case action
      when "shared" then _view_view_test_base_shared
      else super
      end
    end
  end

  class NotesController < BaseController
    rescue_from Edgeway::MissingTemplate, with: :no_page

    def no_page(_error) = head(:not_found)

    def shared = render(layout: false)
    def mine = render(layout: false)
    def nope = render(layout: false)

    def _view_view_test_notes_mine = "<b>mine</b>"

    def _render_view(action)
      case action
      when "mine" then _view_view_test_notes_mine
      else super
      end
    end
  end

  class PlainController < LayoutController
    def hello = render(json: { "a" => 1 })
    def null = render(json: nil)
    def empty = render(html: nil, layout: false)
    def nothing
    end
  end

  class LogCollector
    attr_reader :lines

    def initialize
      @lines = []
    end

    def info(message, fields = {})
      @lines << "info #{message} #{JSON.generate(fields)}"
    end

    def error(message, fields = {})
      @lines << "error #{message} #{JSON.generate(fields)}"
    end
  end

  HTML_HEADERS = [["Content-Type", "text/html; charset=utf-8"], ["X-Content-Type-Options", "nosniff"]]
  JSON_ERROR_HEADERS = [["Content-Type", "application/json"], ["X-Content-Type-Options", "nosniff"]]
  JSON_HEADERS = [["Content-Type", "application/json"]]
  NOT_FOUND_BODY = "{\"error\":\"not found\"}\n"

  def setup
    @original_logger = Edgeway.logger
    @log = LogCollector.new
    Edgeway.logger = @log
    draw_routes
  end

  def teardown
    Edgeway.application.routes.list.clear
    Edgeway.logger = @original_logger
  end

  def draw_routes
    routes = Edgeway.application.routes
    routes.list.clear
    routes.draw do |mapper|
      mapper.get "/view_posts", to: "view_test/posts#index"
      mapper.get "/view_posts/show", to: "view_test/posts#show"
      mapper.get "/view_posts/named", to: "view_test/posts#named"
      mapper.get "/view_posts/bare", to: "view_test/posts#index_bare"
      mapper.get "/view_posts/plain", to: "view_test/posts#plain"
      mapper.get "/view_posts/bare_html", to: "view_test/posts#bare"
      mapper.get "/view_posts/marked", to: "view_test/posts#marked"
      mapper.get "/view_posts/wrapped", to: "view_test/posts#wrapped"
      mapper.get "/view_posts/raw_in_layout", to: "view_test/posts#raw_in_layout"
      mapper.get "/view_posts/raw", to: "view_test/posts#raw"
      mapper.get "/view_posts/bad", to: "view_test/posts#bad"
      mapper.get "/view_posts/gone", to: "view_test/posts#gone"
      mapper.get "/view_posts/_view_view_test_posts_index", to: "view_test/posts#_view_view_test_posts_index"
      mapper.get "/view_posts/_render_view", to: "view_test/posts#_render_view"
      mapper.get "/view_framed", to: "view_test/framed#show"
      mapper.get "/view_notes/shared", to: "view_test/notes#shared"
      mapper.get "/view_notes/mine", to: "view_test/notes#mine"
      mapper.get "/view_notes/nope", to: "view_test/notes#nope"
      mapper.get "/view_plain", to: "view_test/plain#hello"
      mapper.get "/view_plain/null", to: "view_test/plain#null"
      mapper.get "/view_plain/empty", to: "view_test/plain#empty"
      mapper.get "/view_plain/nothing", to: "view_test/plain#nothing"
    end
  end

  def get(path)
    Edgeway.application.call(Edgeway::HTTP::Request.new("GET", path, "", "", ""))
  end

  def assert_html(response, status, body)
    assert_equal status, response.status
    assert_equal HTML_HEADERS, response.headers.to_a
    assert_equal body, response.body
  end

  def assert_json(response, body)
    assert_equal 200, response.status
    assert_equal JSON_HEADERS, response.headers.to_a
    assert_equal body, response.body
  end

  def assert_not_found(response)
    assert_equal 404, response.status
    assert_equal JSON_ERROR_HEADERS, response.headers.to_a
    assert_equal NOT_FOUND_BODY, response.body
  end

  def assert_no_content(response)
    assert_equal 204, response.status
    assert_equal [], response.headers.to_a
    assert_equal "", response.body
  end

  def test_escape_replaces_html_special_characters
    assert_equal "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;",
                 Edgeway::View.escape("<a href=\"x\">Tom & 'Jerry'</a>")
  end

  def test_escape_replaces_every_occurrence
    assert_equal "&amp;&amp;&lt;&lt;&gt;&gt;&quot;&quot;&#39;&#39;", Edgeway::View.escape("&&<<>>\"\"''")
  end

  def test_escape_leaves_plain_text_alone
    assert_equal "plain", Edgeway::View.escape("plain")
  end

  def test_escape_turns_nil_into_an_empty_string
    assert_equal "", Edgeway::View.escape(nil)
  end

  def test_escape_converts_an_integer_to_a_string
    assert_equal "42", Edgeway::View.escape(42)
  end

  def test_escape_keeps_html_safe_strings_as_they_are
    assert_equal "<b>", Edgeway::View.escape("<b>".html_safe)
  end

  def test_escape_keeps_safe_html_as_it_is
    assert_equal "<i>", Edgeway::View.escape(Edgeway::View::SafeHTML.new("<i>"))
  end

  def test_html_safe_returns_the_same_text
    assert_equal "<b>", "<b>".html_safe.to_s
  end

  def test_html_safe_is_a_snapshot_of_the_string
    buffer = +"<b>"
    marked_buffer = buffer.html_safe
    buffer << "</b>"
    assert_equal "<b>", marked_buffer.to_s
  end

  def test_safe_html_of_nil_is_an_empty_string
    assert_equal "", Edgeway::View::SafeHTML.new(nil).to_s
  end

  def test_an_action_that_sets_variables_and_renders_nothing_renders_its_template_in_the_layout
    assert_html get("/view_posts"), 200, "<main><ul>\n<li>a&lt;b</li>\n<li>c&amp;d</li>\n</ul>\n</main>"
  end

  def test_render_without_arguments_renders_the_action_template
    assert_html get("/view_posts/show"), 200, "<main><h1>T</h1></main>"
  end

  def test_render_with_a_template_name_renders_that_template
    assert_html get("/view_posts/named"), 200, "<main><ul>\n<li>n</li>\n</ul>\n</main>"
  end

  def test_render_without_layout_skips_the_layout
    assert_html get("/view_posts/bare"), 200, "<ul>\n<li>b</li>\n</ul>\n"
  end

  def test_render_html_uses_the_layout_and_the_given_status
    assert_html get("/view_posts/plain"), 201, "<main><p>hi</p></main>"
  end

  def test_render_html_escapes_a_plain_string
    assert_html get("/view_posts/bare_html"), 200, "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  def test_render_html_keeps_an_html_safe_string
    assert_html get("/view_posts/marked"), 200, "<b>ok</b>"
  end

  def test_render_html_keeps_raw_text
    assert_html get("/view_posts/wrapped"), 200, "<i>ok</i>"
  end

  def test_raw_text_is_not_escaped_by_the_layout
    assert_html get("/view_posts/raw_in_layout"), 200, "<main><u>ok</u></main>"
  end

  def test_raw_is_not_an_action
    assert_not_found get("/view_posts/raw")
  end

  def test_a_layout_can_use_raw_and_escape
    assert_html get("/view_framed"), 200, "<div><hr><p>body</p></div>"
  end

  def test_a_template_that_does_not_exist_is_a_500_with_the_fixed_body
    response = get("/view_posts/bad")
    assert_equal 500, response.status
    assert_equal JSON_ERROR_HEADERS, response.headers.to_a
    assert_equal "{\"error\":\"internal error\"}\n", response.body
    assert_equal ["error Edgeway::MissingTemplate: no template \"nope\" for ViewTest::PostsController {\"status\":500}"], @log.lines
  end

  def test_an_action_that_renders_nothing_without_a_template_is_a_204
    assert_no_content get("/view_posts/gone")
  end

  def test_the_generated_view_method_is_not_an_action
    assert_not_found get("/view_posts/_view_view_test_posts_index")
  end

  def test_the_generated_render_view_method_is_not_an_action
    assert_not_found get("/view_posts/_render_view")
  end

  def test_a_controller_renders_a_template_it_inherits
    assert_html get("/view_notes/shared"), 200, "<i>shared</i>"
  end

  def test_a_controller_renders_its_own_template
    assert_html get("/view_notes/mine"), 200, "<b>mine</b>"
  end

  def test_a_missing_template_leaves_no_html_headers_on_what_a_handler_answers
    response = get("/view_notes/nope")
    assert_equal 404, response.status
    assert_equal [], response.headers.to_a
    assert_equal "", response.body
  end

  def test_render_json_is_unaffected_by_templates
    response = get("/view_plain")
    assert_json response, "{\"a\":1}\n"
  end

  def test_an_explicit_nil_json_is_a_value
    response = get("/view_plain/null")
    assert_json response, "null\n"
  end

  def test_an_explicit_nil_html_is_an_empty_body
    assert_html get("/view_plain/empty"), 200, ""
  end

  def test_a_controller_with_no_templates_answers_204_for_an_action_that_renders_nothing
    assert_no_content get("/view_plain/nothing")
  end
end
