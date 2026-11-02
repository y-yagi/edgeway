require "json"
require_relative "../../cache/store"

module Edgeway
  module Cloudflare
    class KVTransport
      def get(binding_name, key)
        raise Edgeway::Error, "#{self.class.name} does not get"
      end

      def put(binding_name, key, text, expires_in_seconds)
        raise Edgeway::Error, "#{self.class.name} does not put"
      end

      def delete(binding_name, key)
        raise Edgeway::Error, "#{self.class.name} does not delete"
      end
    end

    class KVStore < Cache::Store
      def initialize(binding:, namespace: nil, expires_in: nil, transport:)
        super(namespace: namespace, expires_in: expires_in)
        @binding_name = binding
        @transport = transport
      end

      def read_text(key)
        check_key(key)
        answer = parse_answer("get", @transport.get(@binding_name, key))
        answer.nil? ? nil : answer["value"]
      end

      def write_text(key, text, expires_in_seconds)
        check_key(key)
        !parse_answer("put", @transport.put(@binding_name, key, text, expires_in_seconds)).nil?
      end

      def delete_text(key)
        check_key(key)
        !parse_answer("delete", @transport.delete(@binding_name, key)).nil?
      end

      private

      def check_key(key)
        raise ArgumentError, "cache key can't be . or .." if key == "." || key == ".."
      end

      def parse_answer(operation, json)
        answer = JSON.parse(json)
        return answer unless answer.key?("error")

        Edgeway.logger.warn("cache operation failed", { "operation" => operation, "binding" => @binding_name, "error" => answer["error"] })
        nil
      end
    end
  end
end
