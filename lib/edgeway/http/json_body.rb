module Edgeway
  module HTTP
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
