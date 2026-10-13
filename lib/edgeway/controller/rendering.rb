module Edgeway
  module Controller
    module Rendering
      STATUS_CODES = {
        "ok" => 200, "created" => 201, "accepted" => 202, "no_content" => 204,
        "moved_permanently" => 301, "found" => 302, "not_modified" => 304,
        "bad_request" => 400, "unauthorized" => 401, "forbidden" => 403, "not_found" => 404,
        "method_not_allowed" => 405, "conflict" => 409, "unprocessable_entity" => 422,
        "too_many_requests" => 429, "internal_server_error" => 500, "not_implemented" => 501,
        "service_unavailable" => 503
      }

      def self.json_response(status, json_text)
        HTTP::Response.json(status, json_text)
      end

      def self.status_code(status)
        return status if status.is_a?(Integer)
        code = STATUS_CODES[status.to_s]
        raise ArgumentError, "unknown status: #{status.inspect}" if code.nil?
        code
      end

      def self.json_value(obj)
        if obj.is_a?(Model::Relation)
          obj.to_a.map { |m| m.as_json }
        elsif obj.is_a?(Model::Base)
          obj.as_json
        elsif obj.is_a?(HTTP::Parameters)
          obj.to_h
        elsif obj.is_a?(Array)
          obj.map { |x| json_value(x) }
        elsif obj.is_a?(Hash)
          h = {}
          obj.each { |k, v| h[k] = json_value(v) }
          h
        else
          obj
        end
      end

      def render(json:, status: 200)
        @status = Rendering.status_code(status)
        @headers["Content-Type"] = "application/json"
        @response_body = JSON.generate(Rendering.json_value(json)) + "\n"
        @performed = true
      end

      def head(status)
        @status = Rendering.status_code(status)
        @response_body = ""
        @performed = true
      end

      def performed? = @performed

      def to_response
        response = HTTP::Response.new(@status, @response_body)
        @headers.each { |k, v| response.headers[k] = v }
        response.check_headers
        response
      end
    end
  end
end
