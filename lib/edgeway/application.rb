module Edgeway
  # The app's entry point: Edgeway.application.call(request) -> response.
  # How a request gets in and the response out (CGI, later a reactor) is the
  # job of Edgeway::Server.
  class Application
    attr_reader :routes

    def initialize
      @routes = Routing::RouteSet.new
    end

    def call(request)
      request.read_body
      route, path_params = @routes.recognize(request.method, request.path)
      # Path parameters last: they win over the body's and the query's.
      request.add_path_params(path_params)
      Controller::Dispatcher.dispatch(route, request)
    rescue RecordInvalid => e
      # The error's own list (errors) is the body.
      Controller::Rendering.json_response(422, JSON.generate({ "errors" => e.errors }))
    rescue => e
      rescue_default(e)
    end

    # What a request answers when no controller handled the error.
    def rescue_default(e)
      if e.is_a?(BadRequest)
        message(400, e.message)
      elsif e.is_a?(InvalidToken)
        # The reason (e.message) goes to the log only; the client gets a fixed
        # body and challenge, so a probe learns nothing from the wording.
        Edgeway.logger.info "401 #{e.message}"
        unauthorized("invalid token", 'Bearer error="invalid_token"')
      elsif e.is_a?(Unauthorized)
        Edgeway.logger.info "401 #{e.message}"
        unauthorized("authentication required", "Bearer")
      elsif e.is_a?(RecordNotUnique)
        # The message names the table and columns: the log only.
        Edgeway.logger.info "409 #{e.message}"
        message(409, "record not unique")
      elsif e.is_a?(RoutingError) || e.is_a?(RecordNotFound)
        # The message can hold the path or an id from the request: the log only.
        Edgeway.logger.info "404 #{e.message}"
        message(404, "not found")
      else
        # The details go to the log (stderr), never to the client.
        Edgeway.logger.error "#{e.class}: #{e.message}"
        message(500, "internal error")
      end
    end

    private

    def unauthorized(text, challenge)
      response = message(401, text)
      response.headers["WWW-Authenticate"] = challenge
      response
    end

    def message(status, text)
      Controller::Rendering.json_response(status, JSON.generate({ "error" => text }))
    end
  end

  def self.application
    @application ||= Application.new
  end
end
