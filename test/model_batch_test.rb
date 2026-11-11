require_relative "test_helper"

class ModelBatchTest < DatabaseTestCase
  class ApplicationModel < Edgeway::Model::Base
    extend Edgeway::Model::Macros
  end

  class Todo < ApplicationModel
    attribute :title, :string
    attribute :done, :boolean, default: false
    attribute :priority, :string, default: "normal"
    attribute :position, :integer
    timestamps
  end

  class Group < ApplicationModel
    attribute :name, :string
    has_many :members, dependent: :destroy
  end

  class Member < ApplicationModel
    attribute :name, :string
    belongs_to :group
    has_many :notes, dependent: :destroy
  end

  class Note < ApplicationModel
    attribute :body, :string
    belongs_to :member
  end

  class Team < ApplicationModel
    attribute :name, :string
    has_many :tasks, dependent: :delete_all
  end

  class Task < ApplicationModel
    attribute :title, :string
    belongs_to :team
  end

  SELECT_UNDONE_TODOS = "SELECT id, title, done, priority, position, created_at, updated_at FROM todos WHERE done = ? | [0]"
  DELETE_DONE_TODOS = "DELETE FROM todos WHERE done = ? | [1]"
  DELETE_TASKS_OF_TEAM_3 = "DELETE FROM tasks WHERE team_id = ? | [3]"
  DELETE_TEAM_3 = "DELETE FROM teams WHERE id = ? | [3]"
  UNIQUE_FAILED = "D1_ERROR: UNIQUE constraint failed: todos.title: SQLITE_CONSTRAINT"

  def setup
    super
    Edgeway::Model.freeze_time("2026-01-02T03:04:05.000Z")
  end

  def teardown
    Edgeway::Model.freeze_time(nil)
    super
  end

  def persisted_todo
    Todo.instantiate({ "id" => 1, "title" => "p", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" })
  end

  def update_todo_sql(title)
    "UPDATE todos SET title = ?, done = ?, priority = ?, position = ?, created_at = ?, updated_at = ? WHERE id = ? | [\"#{title}\",0,\"normal\",1,\"c\",\"2026-01-02T03:04:05.000Z\",1]"
  end

  def persisted_team
    Team.instantiate({ "id" => 3, "name" => "t" })
  end

  def test_writes_are_queued_and_sent_as_one_batch_while_reads_run_at_once
    @database.queue([{ "id" => 8, "title" => "x" }])
    todo = persisted_todo
    batching_in_block = false
    results = Edgeway::Model.batch do
      todo.update!(title: "batched")
      Todo.where(done: true).delete_all
      batching_in_block = Edgeway::Model.batching?
      Todo.where(done: false).destroy_all
    end
    assert_equal true, batching_in_block
    assert_equal false, Edgeway::Model.batching?
    assert_equal '[{"changes" => 1, "last_insert_id" => 1}, {"changes" => 1, "last_insert_id" => 2}, {"changes" => 1, "last_insert_id" => 3}]', results.inspect
    expected = [
      SELECT_UNDONE_TODOS,
      "BATCH 3",
      update_todo_sql("batched"),
      DELETE_DONE_TODOS,
      "DELETE FROM todos WHERE id = ? | [8]",
    ]
    assert_equal expected, @database.log
  end

  def test_nothing_is_sent_until_the_block_ends
    todo = persisted_todo
    logged_in_block = -1
    Edgeway::Model.batch do
      todo.update!(title: "later")
      logged_in_block = @database.log.size
    end
    assert_equal 0, logged_in_block
    assert_equal ["BATCH 1", update_todo_sql("later")], @database.log
  end

  def test_an_empty_batch_sends_nothing
    results = Edgeway::Model.batch { 1 + 1 }
    assert_equal "[]", results.inspect
    assert_equal [], @database.log
  end

  def test_a_block_that_raises_sends_nothing_and_resets_the_queue
    todo = persisted_todo
    error = assert_raise(RuntimeError) do
      Edgeway::Model.batch do
        todo.update!(title: "lost")
        raise "boom"
      end
    end
    assert_equal "boom", error.message
    assert_equal false, Edgeway::Model.batching?
    assert_equal [], @database.log
    todo.update!(title: "plain")
    assert_equal [update_todo_sql("plain")], @database.log
  end

  def test_a_nested_batch_joins_the_outer_one
    todo = persisted_todo
    results = Edgeway::Model.batch do
      todo.update!(title: "outer")
      Edgeway::Model.batch { Todo.where(done: true).delete_all }
      todo.update!(title: "after")
    end
    assert_equal 3, results.size
    assert_equal ["BATCH 3", update_todo_sql("outer"), DELETE_DONE_TODOS, update_todo_sql("after")], @database.log
  end

  def test_a_create_is_refused_inside_a_batch_before_any_sql
    todo = persisted_todo
    error = assert_raise(ArgumentError) do
      Edgeway::Model.batch do
        todo.update!(title: "queued")
        Todo.create!(title: "new", position: 1)
      end
    end
    assert_equal "create isn't supported inside Model.batch", error.message
    assert_equal false, Edgeway::Model.batching?
    assert_equal [], @database.log
  end

  def test_a_failure_when_the_batch_is_sent_resets_the_state_so_the_next_batch_works
    @database.fail_next(UNIQUE_FAILED, "DELETE")
    todo = persisted_todo
    error = assert_raise(Edgeway::RecordNotUnique) do
      Edgeway::Model.batch do
        todo.update!(title: "dup")
        Todo.where(done: true).delete_all
      end
    end
    assert_equal UNIQUE_FAILED, error.message
    assert_equal false, Edgeway::Model.batching?
    assert_equal ["BATCH 2", update_todo_sql("dup"), DELETE_DONE_TODOS], @database.log

    @database.log.clear
    results = Edgeway::Model.batch { Todo.where(done: true).delete_all }
    assert_equal 1, results.size
    assert_equal ["BATCH 1", DELETE_DONE_TODOS], @database.log
  end

  def test_destroy_with_dependents_is_one_batch_of_the_childrens_deletes_then_the_parents
    @database.queue([{ "id" => 11, "name" => "m1", "group_id" => 7 }])
    @database.queue([{ "id" => 21, "body" => "n", "member_id" => 11 }])
    group = Group.instantiate({ "id" => 7, "name" => "g" })
    assert_equal true, group.destroy
    assert_equal false, group.persisted?
    expected = [
      "SELECT id, name, group_id FROM members WHERE group_id = ? | [7]",
      "SELECT id, body, member_id FROM notes WHERE member_id = ? | [11]",
      "BATCH 3",
      "DELETE FROM notes WHERE id = ? | [21]",
      "DELETE FROM members WHERE id = ? | [11]",
      "DELETE FROM groups WHERE id = ? | [7]",
    ]
    assert_equal expected, @database.log
  end

  def test_a_failing_batch_leaves_the_parent_persisted
    @database.fail_next("D1_ERROR: boom", "DELETE FROM teams")
    team = persisted_team
    error = assert_raise(Edgeway::DatabaseError) { team.destroy }
    assert_equal "D1_ERROR: boom", error.message
    assert_equal true, team.persisted?
    assert_equal ["BATCH 2", DELETE_TASKS_OF_TEAM_3, DELETE_TEAM_3], @database.log
  end
end
