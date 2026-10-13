class HealthController < ApplicationController
  def show = render json: { "status" => "ok" }

  # Fails on purpose: the response must be a bare 500, with the details in
  # the log only.
  def boom
    raise "secret detail"
  end
end
