module Edgeway
  module HTTP
    class Response
      # The characters of an HTTP token (RFC 9110), which is what a header
      # name is.
      TOKEN = /\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/

      attr_accessor :status, :body
      attr_reader :headers

      def initialize(status = 200, body = "")
        @status = status
        @headers = {}
        @body = body
      end

      def self.json(status, json_text)
        response = new(status, json_text + "\n")
        response.headers["Content-Type"] = "application/json"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response
      end

      # Raises InvalidHeader unless every header name is an HTTP token and no
      # value holds CR, LF or NUL: js/cgi.js reads each line of to_cgi as a
      # header, so a newline in a value would let a client add headers, a
      # second Status or the body (headers["X-Name"] = params["name"]).
      def check_headers
        @headers.each do |k, v|
          raise InvalidHeader, "bad header name: #{k.to_s.inspect}" unless TOKEN.match?(k.to_s)
          text = v.to_s
          if text.include?("\n") || text.include?("\r") || text.include?("\0")
            raise InvalidHeader, "bad value for header #{k}"
          end
        end
      end

      def to_cgi
        check_headers
        out = "Status: #{@status}\n"
        @headers.each { |k, v| out += "#{k}: #{v}\n" }
        out + "\n" + @body
      end
    end
  end
end
