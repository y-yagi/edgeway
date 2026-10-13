# A protected endpoint: the request needs "Authorization: Bearer <JWT>". The
# token is checked as config says (wrangler.toml [vars], .dev.vars).
class MeController < ApplicationController
  before_action :authenticate!

  def show = render json: current_claims
end
