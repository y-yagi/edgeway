require_relative "store"

module Edgeway
  module Cache
    class MemoryStore < Store
      def initialize(namespace: nil, expires_in: nil)
        super(namespace: namespace, expires_in: expires_in)
        @texts = {}
      end

      def read_text(key) = @texts[key]

      def write_text(key, text, expires_in_seconds)
        @texts[key] = text
        true
      end

      def delete_text(key)
        @texts.delete(key)
        true
      end
    end
  end
end
