require "spinel_test/unit"
require "edgeway"

class RoutingTest < SpinelTest::Unit::TestCase
  def app_routes
    route_set = Edgeway::Routing::RouteSet.new
    route_set.draw do |routes|
      routes.resources :todos, only: [:index, :show, :create, :update, :destroy] do |todos|
        todos.resources :comments, only: [:index, :create, :destroy]
      end
      routes.namespace :admin do |admin|
        admin.resources :todos, only: [:index]
        admin.get "/stats", to: "stats#show"
      end
      routes.get "/health", to: "health#show"
      routes.root to: "health#show"
    end
    route_set
  end

  def nested_routes
    route_set = Edgeway::Routing::RouteSet.new
    route_set.draw do |routes|
      routes.namespace :admin do |admin|
        admin.resources :todos, only: [:index, :show] do |todos|
          todos.resources :comments, only: [:index] do |comments|
            comments.resources :replies, only: [:show]
          end
        end
      end
      routes.resources :posts, except: [:destroy, :update] do |posts|
        posts.resources :tags, only: [:index]
      end
      routes.resources :categories, only: [:index] do |categories|
        categories.resources :items, only: [:index]
      end
    end
    route_set
  end

  def listing(routes)
    routes.list.map { |route| "#{route.verb} #{route.pattern} #{route.controller_class_name}##{route.action}" }
  end

  def test_lists_app_routes_in_definition_order
    expected = [
      "GET /todos TodosController#index",
      "POST /todos TodosController#create",
      "GET /todos/:id TodosController#show",
      "PATCH /todos/:id TodosController#update",
      "PUT /todos/:id TodosController#update",
      "DELETE /todos/:id TodosController#destroy",
      "GET /todos/:todo_id/comments CommentsController#index",
      "POST /todos/:todo_id/comments CommentsController#create",
      "DELETE /todos/:todo_id/comments/:id CommentsController#destroy",
      "GET /admin/todos Admin::TodosController#index",
      "GET /admin/stats Admin::StatsController#show",
      "GET /health HealthController#show",
      "GET / HealthController#show"
    ]
    assert_equal expected, listing(app_routes)
  end

  def test_recognizes_nested_resource_collection
    route, params = app_routes.recognize("GET", "/todos/5/comments")
    assert_equal "CommentsController", route.controller_class_name
    assert_equal "index", route.action
    assert_equal "5", params["todo_id"]
  end

  def test_recognizes_nested_resource_member
    route, params = app_routes.recognize("DELETE", "/todos/5/comments/9")
    assert_equal "destroy", route.action
    assert_equal "5", params["todo_id"]
    assert_equal "9", params["id"]
  end

  def test_recognizes_namespaced_route
    route, _ = app_routes.recognize("GET", "/admin/stats")
    assert_equal "Admin::StatsController", route.controller_class_name
  end

  def test_recognizes_root
    route, _ = app_routes.recognize("GET", "/")
    assert_equal "/", route.pattern
  end

  def test_unknown_verb_for_a_path_is_a_routing_error
    error = assert_raise(Edgeway::RoutingError) { app_routes.recognize("DELETE", "/health") }
    assert_equal "no route for DELETE /health", error.message
  end

  def test_lists_namespace_around_nested_resources_at_any_depth
    expected = [
      "GET /admin/todos Admin::TodosController#index",
      "GET /admin/todos/:id Admin::TodosController#show",
      "GET /admin/todos/:todo_id/comments Admin::CommentsController#index",
      "GET /admin/todos/:todo_id/comments/:comment_id/replies/:id Admin::RepliesController#show",
      "GET /posts PostsController#index",
      "POST /posts PostsController#create",
      "GET /posts/:id PostsController#show",
      "GET /posts/:post_id/tags TagsController#index",
      "GET /categories CategoriesController#index",
      "GET /categories/:category_id/items ItemsController#index"
    ]
    assert_equal expected, listing(nested_routes)
  end

  def test_recognizes_deeply_nested_route_inside_namespace
    route, params = nested_routes.recognize("GET", "/admin/todos/5/comments/6/replies/7")
    assert_equal "Admin::RepliesController", route.controller_class_name
    assert_equal "5", params["todo_id"]
    assert_equal "6", params["comment_id"]
    assert_equal "7", params["id"]
  end

  def test_recognizes_nested_route_outside_namespace
    route, params = nested_routes.recognize("GET", "/categories/2/items")
    assert_equal "ItemsController", route.controller_class_name
    assert_equal "2", params["category_id"]
  end

  def test_only_rejects_unknown_action
    error = assert_raise(ArgumentError) do
      Edgeway::Routing::RouteSet.new.draw { |routes| routes.resources :pages, only: [:new] }
    end
    assert_equal "unknown action for resources :pages: new", error.message
  end

  def test_except_rejects_unknown_action
    error = assert_raise(ArgumentError) do
      Edgeway::Routing::RouteSet.new.draw { |routes| routes.resources :pages, except: [:edit] }
    end
    assert_equal "unknown action for resources :pages: edit", error.message
  end

  def test_head_is_answered_by_get_route
    route, _ = app_routes.recognize("HEAD", "/health")
    assert_equal "GET", route.verb
    assert_equal "show", route.action
  end

  def test_head_does_not_match_delete_route
    error = assert_raise(Edgeway::RoutingError) { app_routes.recognize("HEAD", "/todos/5/comments/9") }
    assert_equal "no route for HEAD /todos/5/comments/9", error.message
  end
end
