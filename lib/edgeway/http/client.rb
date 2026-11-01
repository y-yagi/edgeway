module Edgeway
  module HTTP
    DEFAULT_TIMEOUT = 10
    MAX_TIMEOUT = 300

    class ClientResponse
      attr_reader :status, :headers, :body

      def initialize(status, headers, body)
        @status = status
        @headers = headers
        @body = body
      end

      def success? = @status >= 200 && @status < 300

      def json = JSON.parse(@body)
    end

    class Transport
      def request(payload)
        JSON.generate({ "error" => "no HTTP transport is set" })
      end
    end

    @client = Transport.new

    def self.client = @client

    def self.client=(client)
      @client = client
    end

    def self.get(url, headers: {}, timeout: DEFAULT_TIMEOUT)
      send_request("GET", url, "", headers, timeout)
    end

    def self.delete(url, headers: {}, timeout: DEFAULT_TIMEOUT)
      send_request("DELETE", url, "", headers, timeout)
    end

    def self.post(url, body: "", headers: {}, timeout: DEFAULT_TIMEOUT)
      send_request("POST", url, body, headers, timeout)
    end

    def self.put(url, body: "", headers: {}, timeout: DEFAULT_TIMEOUT)
      send_request("PUT", url, body, headers, timeout)
    end

    def self.patch(url, body: "", headers: {}, timeout: DEFAULT_TIMEOUT)
      send_request("PATCH", url, body, headers, timeout)
    end

    def self.send_request(verb, url, body, headers, timeout)
      timeout_ms = timeout_milliseconds(timeout)
      payload = JSON.generate({
        "method" => verb, "url" => url, "headers" => headers, "body" => body,
        "timeout_ms" => timeout_ms
      })
      parse_answer(client.request(payload))
    end

    def self.timeout_milliseconds(timeout)
      milliseconds = timeout > MAX_TIMEOUT ? 0 : (timeout * 1000).to_i
      raise ArgumentError, "timeout must be 0.001 to #{MAX_TIMEOUT} seconds" if milliseconds < 1

      milliseconds
    end

    def self.parse_answer(text)
      answer = JSON.parse(text)
      raise Timeout, answer["error"] if answer.key?("timeout")
      raise Error, answer["error"] if answer.key?("error")

      body = answer["body_base64"].unpack1("m0")
      body.force_encoding("UTF-8")
      ClientResponse.new(answer["status"], answer["headers"], body)
    end
  end
end
