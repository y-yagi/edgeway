module Edgeway
  module HTTP
    class Request
      REPLACEMENT = "\uFFFD"

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

      # decode_www_form never raises on bad bytes: it turns those that aren't
      # UTF-8 (%ff) into U+FFFD. That is only right when the client sent a
      # U+FFFD itself, so otherwise one in the result is a BadRequest.
      def decode_pairs(text, what)
        raise BadRequest, "#{what} is not valid UTF-8" unless text.valid_encoding?
        pairs = decode_www_form(text)
        sent = text.include?(REPLACEMENT) || text.downcase.include?("%ef%bf%bd")
        unless sent
          pairs.each do |k, v|
            raise BadRequest, "#{what} is not valid UTF-8" if k.include?(REPLACEMENT) || v.include?(REPLACEMENT)
          end
        end
        pairs
      end

      # URI.decode_www_form, written out so that Edgeway doesn't require
      # "uri": a send with a computed name (Dispatcher) reaches uri's
      # find_proxy(env = ENV), which Spinel refuses since its Strings are
      # shared by reference (matz/spinel 44119ab30). Same answers as uri's,
      # ArgumentError for a non-ASCII input included.
      def decode_www_form(text)
        raise ArgumentError, "the input of URI.decode_www_form must be ASCII only string" unless text.ascii_only?
        return [] if text.empty?
        pieces = text.split("&", -1)
        pieces.pop if pieces.last.empty?
        pieces.map do |piece|
          key, _sep, val = piece.partition("=")
          [unescape_www(key), unescape_www(val)]
        end
      end

      def unescape_www(s)
        s.b.gsub(/\+|%\h\h/) { |m| m == "+" ? " " : m[1, 2].hex.chr }.force_encoding(Encoding::UTF_8).scrub
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
