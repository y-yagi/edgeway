module Edgeway
  # The base of Edgeway's errors.
  class Error < StandardError; end

  # A request that can't be read (bad JSON, invalid UTF-8 in the query or a
  # form body): 400.
  class BadRequest < Error; end

  # params.require(:x) found nothing: 400.
  class ParameterMissing < BadRequest; end

  # Unpermitted Parameters given to a model (Todo.create!(params) without
  # permit): 500, with the details only in the log, since it is a bug in the
  # app.
  class ForbiddenAttributes < Error; end

  # No route for the method and path: 404.
  class RoutingError < Error; end

  # The request has no credentials (no Authorization: Bearer token): 401 with
  # "WWW-Authenticate: Bearer". The default answer has a fixed body; the
  # message is for the log.
  class Unauthorized < Error; end

  # The token is not accepted (bad signature, expired, wrong issuer or
  # audience...): 401 with "WWW-Authenticate: Bearer error=\"invalid_token\"".
  # The message says why, for the log: the default answer has a fixed body
  # ({"error":"invalid token"}) and the challenge no description.
  class InvalidToken < Unauthorized; end

  # A record that doesn't exist: 404.
  class RecordNotFound < Error; end

  # An unknown column or attribute named in a query: 400.
  class UnknownColumn < BadRequest; end

  # The app is set up wrongly (no database connection and so on): 500.
  class ConfigurationError < Error; end

  # A response header with a bad name or a CR/LF in its value: 500, with the
  # details only in the log.
  class InvalidHeader < Error; end

  # render named a template that was not compiled from app/views: 500, with
  # the name only in the log, since it is a bug in the app.
  class MissingTemplate < Error; end

  # A failure in the database adapter: 500.
  class DatabaseError < Error; end

  # A write the database refused for a UNIQUE (or PRIMARY KEY) constraint: 409
  # with a fixed body. The message names the table and columns, so it goes to
  # the log only.
  class RecordNotUnique < DatabaseError; end

  # A record that failed its validations: 422 with {"errors": [...]}.
  class RecordInvalid < Error
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super("validation failed: #{errors.join(", ")}")
    end
  end
end
