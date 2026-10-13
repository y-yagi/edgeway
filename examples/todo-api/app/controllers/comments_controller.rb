# The comments of a todo: /todos/:todo_id/comments.
class CommentsController < ApplicationController
  before_action :set_todo

  def index = render json: @todo.comments.order(:id)

  def create
    comment = @todo.comments.create!(params.require(:comment).permit(:body))
    render json: comment, status: :created
  end

  def destroy
    @todo.comments.find(params["id"]).destroy
    head :no_content
  end

  private

  def set_todo
    @todo = Todo.find(params["todo_id"])
  end
end
