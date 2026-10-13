class TodosController < ApplicationController
  before_action :set_todo, only: [:show, :update, :destroy]

  # GET /todos?done=true&order=title&dir=desc. X-Total-Count: all the todos
  # that match, beyond the 50 answered.
  def index
    todos = Todo.order(params.fetch("order", "id"), params.fetch("dir", "asc"))
    todos = todos.where("done" => params["done"]) if params.key?("done")
    headers["X-Total-Count"] = todos.count.to_s
    render json: todos.limit(50)
  end

  def show = render json: @todo

  def create
    todo = Todo.create!(todo_params)
    render json: todo, status: :created
  end

  def update
    @todo.update!(todo_params)
    render json: @todo
  end

  def destroy
    @todo.destroy
    head :no_content
  end

  private

  def set_todo
    @todo = Todo.find(params["id"])
  end

  def todo_params = params.require(:todo).permit(:title, :done, :priority)
end
