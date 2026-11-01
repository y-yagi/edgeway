require_relative "client"

module Edgeway
  module HTTP
    class UnstubbedRequest < Edgeway::Error; end

    class StubTransport < Transport
      attr_reader :requests

      def initialize
        @answers = {}
        @requests = []
      end

      def stub(verb, url, status, body, headers)
        lowered = {}
        headers.each { |name, value| lowered[name.to_s.downcase] = value.to_s }
        @answers[key(verb, url)] = JSON.generate({ "status" => status, "headers" => lowered, "body_base64" => [body].pack("m0") })
      end

      def stub_error(verb, url, message, timeout)
        answer = { "error" => message }
        answer["timeout"] = true if timeout
        @answers[key(verb, url)] = JSON.generate(answer)
      end

      def request(payload)
        sent = JSON.parse(payload)
        @requests << sent
        @answers[key(sent["method"], sent["url"])] || raise(UnstubbedRequest, "no stub for #{sent["method"]} #{sent["url"]} (add stub_http to the test)")
      end

      private

      def key(verb, url) = "#{verb.to_s.upcase} #{url}"
    end
  end
end
