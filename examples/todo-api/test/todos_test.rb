require "edgeway/test"
require "test_helper"

# Runs against a real in-memory SQLite database with db/migrations applied
# (see Edgeway::IntegrationTest#setup); every test starts from empty tables.
class TodosTest < Edgeway::IntegrationTest
  def test_index_lists_persisted_todos
    Todo.create!(title: "a")
    Todo.create!(title: "b", priority: "high")
    get "/todos"
    assert_response 200
    assert_equal 2, json.size
    assert_equal "a", json[0]["title"]
    assert_equal "high", json[1]["priority"]
    assert_equal "2", response.headers["X-Total-Count"]
  end

  def test_index_filters_by_done
    Todo.create!(title: "open")
    Todo.create!(title: "closed", done: true)
    get "/todos?done=true"
    assert_equal ["closed"], json.map { |t| t["title"] }
    get "/todos?order=title&dir=desc"
    assert_equal ["open", "closed"], json.map { |t| t["title"] }
  end

  def test_create_persists_the_row
    post "/todos", json: { "todo" => { "title" => "a" } }
    assert_response 201
    assert_equal "a", json["title"]
    assert_equal "normal", json["priority"]
    todo = Todo.find(json["id"])
    assert_equal "a", todo.title
    assert_equal false, todo.done
    assert_equal 1, Todo.count
    assert_equal 1, db.select_all("SELECT COUNT(*) AS n FROM todos", [])[0]["n"]
  end

  def test_show
    todo = Todo.create!(title: "a")
    get "/todos/#{todo.id}"
    assert_response 200
    assert_equal todo.id, json["id"]
  end

  def test_update_persists_the_change
    todo = Todo.create!(title: "a")
    put "/todos/#{todo.id}", json: { "todo" => { "title" => "b", "done" => true } }
    assert_response 200
    assert_equal "b", json["title"]
    fresh = Todo.find(todo.id)
    assert_equal "b", fresh.title
    assert_equal true, fresh.done
  end

  def test_destroy_removes_the_row_and_its_comments
    todo = Todo.create!(title: "a")
    Comment.create!(todo_id: todo.id, body: "c")
    delete "/todos/#{todo.id}"
    assert_response 204
    assert_equal 0, Todo.count
    assert_equal 0, Comment.count
    get "/todos/#{todo.id}"
    assert_response 404
  end

  def test_create_validation_422
    post "/todos", json: { "todo" => { "title" => "" } }
    assert_response 422
    assert_includes json["errors"].to_s, "title"
    assert_equal 0, Todo.count
  end

  def test_show_not_found_404
    get "/todos/99"
    assert_response 404
  end

  def test_duplicate_tag_409
    post "/tags", json: { "tag" => { "name" => "work" } }
    assert_response 201
    post "/tags", json: { "tag" => { "name" => "work" } }
    assert_response 409
    assert_equal 1, Tag.count
  end

  def test_rename_pair_is_all_or_nothing
    a = Tag.create!(name: "a")
    b = Tag.create!(name: "b")
    Tag.create!(name: "taken")
    patch "/tags/rename_pair", json: { "rename" => { "first_id" => a.id, "first_name" => "a2", "second_id" => b.id, "second_name" => "taken" } }
    assert_response 409
    assert_equal "a", Tag.find(a.id).name
    assert_equal "b", Tag.find(b.id).name
  end

  def test_each_test_starts_empty
    assert_equal 0, Todo.count
  end
end
