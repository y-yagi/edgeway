module Edgeway
  module HTTP
    # A JSON request body. value is what it parses to; params are its scalars
    # as String parameters, as a form body would give them: a top-level key as
    # "key" and a key of a Hash one level down as "outer[key]" (null is "").
    # Arrays and deeper Hashes are only in value.
    class JSONBody
      attr_reader :value, :params

      def initialize(text)
        @value = parse(text)
        @params = {}
        flatten if @value.is_a?(Hash)
      end

      private

      def parse(text)
        JSON.parse(text)
      rescue JSON::ParserError
        raise BadRequest, "bad JSON body"
      end

      def flatten
        @value.each do |k, v|
          if v.is_a?(Hash)
            v.each do |k2, v2|
              put("#{k}[#{k2}]", v2) unless v2.is_a?(Hash) || v2.is_a?(Array)
            end
          elsif !v.is_a?(Array)
            put(k.to_s, v)
          end
        end
      end

      def put(key, value)
        @params[key] = value.nil? ? "" : value.to_s
      end
    end
  end
end
