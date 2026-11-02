require_relative "store"

module Edgeway
  module Cache
    class NullStore < Store
      def read_text(key) = nil

      def write_text(key, text, expires_in_seconds) = true

      def delete_text(key) = true
    end
  end
end
