module Edgeway
  module HTTP
    class Request
      attr_reader :method, :path, :query_string, :content_type, :body, :params, :body_params

      def self.from_env
        new(ENV["REQUEST_METHOD"] || "GET", ENV["PATH_INFO"] || "/", ENV["QUERY_STRING"] || "",
            ENV["CONTENT_TYPE"] || "", STDIN.read || "")
      end

      def initialize(method, path, query_string, content_type, body)
        @method = method
        @path = path
        @query_string = query_string
        @content_type = content_type
        @body = body
        @params = Parameters.new({})
        @body_params = {}
        @json_body = nil
      end

      def header(name)
        ENV["HTTP_" + name.upcase.gsub("-", "_")] || ""
      end

      # The client address the platform reports, "" when unknown.
      def remote_addr
        ENV["REMOTE_ADDR"] || ""
      end

      def json?
        @content_type.start_with?("application/json")
      end

      def form?
        @content_type.start_with?("application/x-www-form-urlencoded")
      end

      def json_body
        @json_body
      end

      def read_body
        read_query
        return if @body.empty?
        raise BadRequest, "body is not valid UTF-8" unless @body.valid_encoding?
        if json?
          read_json
        elsif form?
          read_form
        end
      end

      def add_path_params(path_params)
        path_params.each { |k, v| @params[k] = v }
      end

      private

      def read_query
        return if @query_string.empty?
        decode_pairs(@query_string, "query string").each { |k, v| @params[k] = v }
      end

      def read_form
        add_body_params(decode_pairs(@body, "form body"))
      end

      def decode_pairs(text, what)
        raise BadRequest, "#{what} is not valid UTF-8" unless text.valid_encoding?
        form = FormBody.new(text)
        raise BadRequest, "#{what} is not valid UTF-8" unless form.valid_utf8?
        form.pairs
      end

      def read_json
        json = JSONBody.new(@body)
        @json_body = json.value
        add_body_params(json.params)
      end

      def add_body_params(pairs)
        pairs.each do |k, v|
          @params[k] = v
          @body_params[k] = v
        end
      end
    end
  end
end
