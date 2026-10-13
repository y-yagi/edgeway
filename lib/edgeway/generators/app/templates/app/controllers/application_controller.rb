class ApplicationController < Edgeway::Controller::Base
  rescue_from Edgeway::RecordNotFound, with: :not_found

  private

  def not_found(e)
    render json: { "error" => "not found" }, status: :not_found
  end
end
