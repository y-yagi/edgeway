# NOTE: the todos/tags/comments endpoints in this example are intentionally
# public (only MeController uses `before_action :authenticate!`). Real apps
# should `before_action :authenticate!` and scope data by current_claims["sub"]:
#
#   # add an owner_uid string attribute/column to Todo
#   Todo.where("owner_uid" => current_claims["sub"])        # reads
#   Todo.create!(params.require(:todo).permit(:title).to_h.merge("owner_uid" => current_claims["sub"]))  # create
#
class ApplicationController < Edgeway::Controller::Base
  rescue_from Edgeway::RecordNotFound, with: :not_found

  private

  def not_found(e)
    render json: { "error" => "not found" }, status: :not_found
  end
end
