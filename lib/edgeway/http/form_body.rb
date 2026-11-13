module Edgeway
  module HTTP
    class FormBody
      attr_reader :pairs

      def initialize(text)
        @valid_utf8 = true
        pieces = text.split("&", -1)
        pieces.pop if !pieces.empty? && pieces.last.empty?
        @pairs = pieces.map { |piece| decode_pair(piece) }
      end

      def valid_utf8?
        @valid_utf8
      end

      private

      def decode_pair(piece)
        key, _, value = piece.partition("=")
        [decode_component(key), decode_component(value)]
      end

      def decode_component(component)
        decoded = component.b.tr("+", " ").gsub(/%([0-9A-Fa-f]{2})/) { $1.hex.chr }.force_encoding("UTF-8")
        @valid_utf8 = false unless decoded.valid_encoding?
        decoded.scrub
      end
    end
  end
end
