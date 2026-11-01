module Edgeway
  module Controller
    # HTTP caching helpers for actions:
    #
    #   def show
    #     todo = Todo.find(params["id"])
    #     render json: todo if stale?(etag: todo, last_modified: todo.updated_at)
    #   end
    #
    # Only the validators an action names are used; nothing is derived from
    # the response body.
    module Caching
      ETAG_LENGTH = 32

      def expires_in(seconds, public: false, must_revalidate: false)
        raise ArgumentError, "seconds must be a non-negative Integer" unless Caching.duration?(seconds)
        value = "max-age=#{seconds}, #{public ? "public" : "private"}"
        value += ", must-revalidate" if must_revalidate
        @headers["Cache-Control"] = value
        nil
      end

      def no_store
        @headers["Cache-Control"] = "no-store"
        nil
      end

      # Returns true when it answered 304 (the action is done), false
      # otherwise.
      def fresh_when(etag: nil, last_modified: nil, public: false)
        etag_value = etag.nil? ? nil : Caching.etag_for(etag)
        modified_time = Caching.time_for(last_modified)
        @headers["ETag"] = etag_value unless etag_value.nil?
        @headers["Last-Modified"] = modified_time.httpdate unless modified_time.nil?
        set_default_cache_control(public)
        return false unless cacheable_request? && request_fresh?(etag_value, modified_time)
        remove_representation_headers
        head :not_modified
        true
      end

      # fresh_when, answering true when the action should go on to render.
      def stale?(etag: nil, last_modified: nil, public: false)
        !fresh_when(etag: etag, last_modified: last_modified, public: public)
      end

      # Integer() gives Spinel a type for a parameter no call site types.
      def self.duration?(seconds)
        seconds.is_a?(Integer) && Integer(seconds) >= 0
      end

      # Weak, because a proxy may recompress the body and weaken a strong
      # validator on the way.
      def self.etag_for(source)
        digest = Digest::SHA256.hexdigest(etag_source(source))
        "W/\"#{digest[0, ETAG_LENGTH]}\""
      end

      def self.etag_source(source)
        if source.is_a?(Model::Base)
          model_source(source)
        elsif source.is_a?(Model::Relation)
          list_source(source.to_a)
        elsif source.is_a?(Array)
          list_source(source)
        else
          source.to_s
        end
      end

      def self.model_source(model)
        updated_at = model.as_json["updated_at"].to_s
        raise ArgumentError, "#{model.class.name} has no updated_at (add timestamps)" if updated_at.empty?
        "#{model.class.name}/#{model.id}/#{updated_at}"
      end

      def self.list_source(items)
        "[" + items.map { |item| etag_source(item) }.join(",") + "]"
      end

      def self.time_for(value)
        return nil if value.nil?
        return value.getutc if value.is_a?(Time)
        raise ArgumentError, "last_modified must be a Time or an ISO 8601 String" unless value.is_a?(String)
        begin
          Time.iso8601(value).utc
        rescue ArgumentError
          raise ArgumentError, "last_modified is not an ISO 8601 String: #{value.inspect}"
        end
      end

      # The validators match the ones the client sent (RFC 9110 13.1.2,
      # 13.1.3): If-None-Match decides when it is present, and
      # If-Modified-Since is then ignored.
      def self.fresh?(none_match, modified_since, etag, last_modified)
        return etag_listed?(none_match, etag) unless none_match.empty?
        return false if modified_since.empty? || last_modified.nil?
        since = parse_http_date(modified_since)
        !since.nil? && last_modified.to_i <= since.to_i
      end

      def self.etag_listed?(header, etag)
        return false if etag.nil?
        candidates = header.split(",").map { |candidate| candidate.strip }
        return true if candidates.include?("*")
        candidates.any? { |candidate| candidate.delete_prefix("W/") == etag.delete_prefix("W/") }
      end

      def self.parse_http_date(text)
        Time.httpdate(text).utc
      rescue ArgumentError
        nil
      end

      private

      def set_default_cache_control(public)
        return if header_set?("Cache-Control")
        @headers["Cache-Control"] = "max-age=0, #{public ? "public" : "private"}, must-revalidate"
      end

      def header_set?(name)
        @headers.keys.any? { |key| key.downcase == name.downcase }
      end

      def remove_representation_headers
        @headers.delete("Content-Type")
        @headers.delete("X-Content-Type-Options")
      end

      def cacheable_request?
        @request.method == "GET" || @request.method == "HEAD"
      end

      def request_fresh?(etag_value, modified_time)
        Caching.fresh?(@request.header("If-None-Match"), @request.header("If-Modified-Since"), etag_value, modified_time)
      end
    end
  end
end
