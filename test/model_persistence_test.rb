require "spinel_test/unit"
require "edgeway"
require "edgeway/db/memory"

class ModelPersistenceTest < SpinelTest::Unit::TestCase
  class ApplicationModel < Edgeway::Model::Base
    extend Edgeway::Model::Macros
  end

  class Todo < ApplicationModel
    attribute :title, :string
    attribute :done, :boolean, default: false
    attribute :priority, :string, default: "normal"
    attribute :position, :integer
    timestamps
    validates :title, presence: true, length: { maximum: 10 }
    validates :priority, inclusion: { in: ["low", "normal", "high"] }
    validates :position, numericality: { only_integer: true }
  end

  FROZEN_TIME = "2026-01-02T03:04:05.000Z"
  TODO_COLUMNS = "id, title, done, priority, position, created_at, updated_at"
  INSERT_TODO = "INSERT INTO todos (title, done, priority, position, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)"
  SELECT_TODOS = "SELECT #{TODO_COLUMNS} FROM todos"
  DELETE_REFUSAL = "delete_all doesn't support limit/offset"

  def setup
    @database = Edgeway::DB::MemoryAdapter.new
    Edgeway::Model.connection = @database
    Edgeway::Model.freeze_time(FROZEN_TIME)
  end

  def teardown
    Edgeway::Model.freeze_time(nil)
    Edgeway::Model.disconnect(Edgeway::Model::PRIMARY)
  end

  def queue_persisted_row(id)
    @database.queue([{ "id" => id, "title" => "new", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
  end

  def created_todo
    queue_persisted_row(9)
    todo = Todo.create!(title: "new", position: "1")
    @database.log.clear
    todo
  end

  def refusal_of(relation)
    error = assert_raise(ArgumentError) { relation.delete_all }
    error.message
  end

  def test_create_inserts_with_returning_and_the_frozen_timestamps
    queue_persisted_row(9)
    todo = Todo.create!(title: "new", position: "1")
    assert_equal "9", todo.id.inspect
    assert_equal "true", todo.persisted?.inspect
    assert_equal ["#{INSERT_TODO} RETURNING #{TODO_COLUMNS} | [\"new\",0,\"normal\",1,\"#{FROZEN_TIME}\",\"#{FROZEN_TIME}\"]"], @database.log
  end

  def test_create_of_an_invalid_record_is_not_persisted_and_sends_nothing
    todo = Todo.create(title: "  ", priority: "urgent", position: "x")
    assert_equal "false", todo.persisted?.inspect
    assert_equal '["title can\'t be blank", "priority is not included in the list", "position is not a number"]', todo.errors.inspect
    assert_equal [], @database.log
  end

  def test_valid_collects_the_length_error
    todo = Todo.new(title: "12345678901", position: 1)
    todo.valid?
    assert_equal '["title is too long (maximum is 10 characters)"]', todo.errors.inspect
  end

  def test_create_bang_of_an_invalid_record_raises_record_invalid_and_sends_nothing
    error = assert_raise(Edgeway::RecordInvalid) { Todo.create!(title: "") }
    assert_equal "validation failed: title can't be blank", error.message
    assert_equal [], @database.log
  end

  def test_update_writes_every_column_and_bumps_updated_at
    todo = created_todo
    todo.update!(done: "true", title: "changed")
    assert_equal ["UPDATE todos SET title = ?, done = ?, priority = ?, position = ?, created_at = ?, updated_at = ? WHERE id = ? | [\"changed\",1,\"normal\",1,\"c\",\"#{FROZEN_TIME}\",9]"], @database.log
    assert_equal "true", todo.done.inspect
    assert_equal "\"c\"", todo.created_at.inspect
    assert_equal "\"#{FROZEN_TIME}\"", todo.updated_at.inspect
  end

  def test_update_of_an_invalid_value_returns_false_and_sends_nothing
    todo = created_todo
    assert_equal "false", todo.update(title: "").inspect
    assert_equal [], @database.log
  end

  def test_destroy_deletes_by_id_and_the_record_is_no_longer_persisted
    todo = created_todo
    assert_equal "true", todo.destroy.inspect
    assert_equal ["DELETE FROM todos WHERE id = ? | [9]"], @database.log
    assert_equal "false", todo.persisted?.inspect
  end

  def test_create_without_returning_loads_the_row_the_select_finds_by_last_insert_id
    @database.returning = false
    @database.queue([{ "id" => 7, "title" => "z", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
    todo = Todo.create!(title: "z", position: 1)
    assert_equal "7", todo.id.inspect
    assert_equal "\"c\"", todo.created_at.inspect
    assert_equal "\"u\"", todo.updated_at.inspect
    assert_equal ["#{INSERT_TODO} | [\"z\",0,\"normal\",1,\"#{FROZEN_TIME}\",\"#{FROZEN_TIME}\"]", "#{SELECT_TODOS} WHERE id = ? | [1]"], @database.log
  end

  def test_create_without_returning_follows_each_last_insert_id
    @database.returning = false
    queue_persisted_row(7)
    Todo.create!(title: "z", position: 1)
    @database.log.clear
    queue_persisted_row(8)
    second = Todo.create!(title: "y", position: 1)
    assert_equal "8", second.id.inspect
    assert_equal ["#{INSERT_TODO} | [\"y\",0,\"normal\",1,\"#{FROZEN_TIME}\",\"#{FROZEN_TIME}\"]", "#{SELECT_TODOS} WHERE id = ? | [2]"], @database.log
  end

  def test_delete_all_sends_one_delete_and_answers_the_number_of_rows
    assert_equal "1", Todo.delete_all.inspect
    assert_equal ["DELETE FROM todos | []"], @database.log
  end

  def test_delete_all_keeps_the_conditions
    assert_equal "1", Todo.where(done: true, position: nil).delete_all.inspect
    assert_equal ["DELETE FROM todos WHERE done = ? AND position IS NULL | [1]"], @database.log
  end

  def test_delete_all_answers_the_changes_of_the_database_and_ignores_the_order
    @database.changes = 4
    assert_equal "4", Todo.where(priority: "low").order(:id).delete_all.inspect
    assert_equal ["DELETE FROM todos WHERE priority = ? | [\"low\"]"], @database.log
  end

  def test_delete_all_refuses_a_limit_and_sends_nothing
    assert_equal DELETE_REFUSAL, refusal_of(Todo.limit(2))
    assert_equal [], @database.log
  end

  def test_delete_all_refuses_an_offset_and_sends_nothing
    assert_equal DELETE_REFUSAL, refusal_of(Todo.where(done: true).offset(1))
    assert_equal [], @database.log
  end

  def test_destroy_all_selects_then_deletes_each_row_and_answers_the_records
    @database.queue([{ "id" => 1, "title" => "a" }, { "id" => 2, "title" => "b" }])
    gone = Todo.where(done: true).destroy_all
    assert_equal "[1, 2]", gone.map(&:id).inspect
    assert_equal "[false, false]", gone.map(&:persisted?).inspect
    assert_equal ["#{SELECT_TODOS} WHERE done = ? | [1]", "DELETE FROM todos WHERE id = ? | [1]", "DELETE FROM todos WHERE id = ? | [2]"], @database.log
  end

  def test_destroy_all_of_no_rows_only_selects
    assert_equal "[]", Todo.destroy_all.inspect
    assert_equal ["#{SELECT_TODOS} | []"], @database.log
  end
end
