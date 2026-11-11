require_relative "test_helper"

class ModelParametersTest < DatabaseTestCase
  class ApplicationModel < Edgeway::Model::Base
    extend Edgeway::Model::Macros
  end

  class Todo < ApplicationModel
    attribute :title, :string
    attribute :done, :boolean, default: false
    attribute :position, :integer
  end

  REFUSED = "ModelParametersTest::Todo: params must go through permit"

  def unpermitted_parameters
    Edgeway::HTTP::Parameters.new({ "title" => "t", "position" => "1" })
  end

  def scoped_parameters
    Edgeway::HTTP::Parameters.new({ "todo[title]" => "t", "todo[position]" => "1", "todo[done]" => "1" })
  end

  def test_new_refuses_parameters_that_did_not_go_through_permit
    error = assert_raise(Edgeway::ForbiddenAttributes) { Todo.new(unpermitted_parameters) }
    assert_equal REFUSED, error.message
  end

  def test_update_refuses_parameters_that_did_not_go_through_permit
    todo = Todo.new(title: "a", position: 1)
    error = assert_raise(Edgeway::ForbiddenAttributes) { todo.update(unpermitted_parameters) }
    assert_equal REFUSED, error.message
    assert_equal "a", todo.title
    assert_equal [], @database.log
  end

  def test_create_refuses_parameters_that_did_not_go_through_permit_before_any_sql
    error = assert_raise(Edgeway::ForbiddenAttributes) { Todo.create!(unpermitted_parameters) }
    assert_equal REFUSED, error.message
    assert_equal [], @database.log
  end

  def test_require_alone_is_not_permitted
    error = assert_raise(Edgeway::ForbiddenAttributes) { Todo.new(scoped_parameters.require(:todo)) }
    assert_equal REFUSED, error.message
  end

  def test_permit_assigns_only_the_permitted_keys
    todo = Todo.new(scoped_parameters.require(:todo).permit(:title, :position))
    assert_equal '["t", 1, false]', [todo.title, todo.position, todo.done].inspect
  end

  def test_a_plain_hash_needs_no_permit_and_takes_string_or_symbol_keys
    todo = Todo.new("title" => "s", :position => 2)
    assert_equal '["s", 2]', [todo.title, todo.position].inspect
  end
end
