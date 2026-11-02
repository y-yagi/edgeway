require_relative "limits"

module Edgeway
  module Cache
    MAX_KEY_BYTES = 512
    KEY_DIGEST_LENGTH = 64

    def self.utf8?(text) = text.dup.force_encoding("UTF-8").valid_encoding?

    class Store
      def initialize(namespace: nil, expires_in: nil)
        @namespace = namespace.nil? ? "" : namespace.dup.force_encoding("UTF-8")
        @default_expires_in = expires_in.nil? ? 0 : checked_expires_in(expires_in)
      end

      def read(key)
        entry = lookup(key)
        entry.nil? ? nil : entry["v"]
      end

      def exist?(key) = !lookup(key).nil?

      def write(key, value, expires_in: nil)
        seconds = expires_in_seconds(expires_in)
        check_cacheable(value)
        write_text(expand_key(key), envelope(value, seconds), seconds)
      end

      def fetch(key, expires_in: nil, force: false, skip_nil: false)
        unless block_given?
          raise ArgumentError, "missing block" if force

          return read(key)
        end

        unless force
          entry = lookup(key)
          return entry["v"] unless entry.nil?
        end
        value = yield
        write(key, value, expires_in: expires_in) unless skip_nil && value.nil?
        value
      end

      def delete(key) = delete_text(expand_key(key))

      def read_text(key)
        raise Edgeway::Error, "#{self.class.name} does not read"
      end

      def write_text(key, text, expires_in_seconds)
        raise Edgeway::Error, "#{self.class.name} does not write"
      end

      def delete_text(key)
        raise Edgeway::Error, "#{self.class.name} does not delete"
      end

      private

      def current_time = Time.now.to_i

      def lookup(key)
        text = read_text(expand_key(key))
        return nil if text.nil?

        entry = parse_entry(text)
        return nil if entry.nil? || expired?(entry)

        entry
      end

      def parse_entry(text)
        entry = JSON.parse(text)
        entry.is_a?(Hash) && entry.key?("v") ? entry : nil
      rescue JSON::ParserError
        nil
      end

      def expired?(entry)
        entry["e"].is_a?(Integer) && Integer(entry["e"]) <= current_time
      end

      def envelope(value, seconds)
        entry = { "v" => value }
        entry["e"] = current_time + seconds if seconds > 0
        JSON.generate(entry)
      end

      def expires_in_seconds(expires_in)
        expires_in.nil? ? @default_expires_in : checked_expires_in(expires_in)
      end

      def checked_expires_in(seconds)
        unless seconds.is_a?(Integer) && Integer(seconds) > 0 && Integer(seconds) <= MAX_EXPIRES_IN
          raise ArgumentError, "expires_in must be a whole number of seconds, 1 to #{MAX_EXPIRES_IN}"
        end

        seconds
      end

      def check_cacheable(value)
        if value.is_a?(String)
          check_text(value)
        elsif value.is_a?(Array)
          value.each { |item| check_cacheable(item) }
        elsif value.is_a?(Hash)
          check_hash(value)
        elsif value.is_a?(Float)
          raise ArgumentError, "a Float to cache must be finite" unless Float(value).finite?
        elsif !json_scalar?(value)
          raise ArgumentError, "#{value.class.name} can't be cached (String, Integer, Float, true, false, nil, Array and Hash can)"
        end
      end

      def check_text(text)
        raise ArgumentError, "a String to cache must be valid UTF-8 (a binary String is not)" unless Cache.utf8?(text)
      end

      def check_hash(hash)
        names = {}
        hash.each do |name, item|
          unless name.is_a?(String) || name.is_a?(Symbol)
            raise ArgumentError, "a Hash to cache needs String or Symbol keys (got #{name.class.name})"
          end
          raise ArgumentError, "a Hash to cache has the same key twice (as a String and a Symbol)" if names.key?(name.to_s)

          names[name.to_s] = true
          check_cacheable(name.to_s)
          check_cacheable(item)
        end
      end

      def json_scalar?(value) = value.nil? || value == true || value == false || value.is_a?(Integer)

      def expand_key(key)
        text = key_text(key)
        raise ArgumentError, "cache key can't be blank" if text.empty?

        text = "#{@namespace}:#{text}" unless @namespace.empty?
        check_key_text(text)
        text.bytesize > MAX_KEY_BYTES ? shortened(text) : text
      end

      def check_key_text(text)
        raise ArgumentError, "cache key must be valid UTF-8" unless Cache.utf8?(text)
        raise ArgumentError, "cache key can't contain a NUL byte" if text.include?("\0")
      end

      def key_text(key)
        if key.is_a?(Edgeway::Model::Base)
          model_key(key)
        elsif key.is_a?(Array)
          key.map { |part| key_text(part) }.join("/")
        elsif key.is_a?(String)
          utf8_key_part(key)
        elsif key.is_a?(Symbol) || key.is_a?(Integer)
          key.to_s
        else
          raise ArgumentError, "a cache key is a String, Symbol, Integer, model or an Array of them (got #{key.class.name})"
        end
      end

      def utf8_key_part(part)
        raise ArgumentError, "cache key must be valid UTF-8" unless Cache.utf8?(part)

        part.dup.force_encoding("UTF-8")
      end

      def model_key(model)
        updated_at = model.as_json["updated_at"].to_s
        raise ArgumentError, "#{model.class.name} has no updated_at (add timestamps)" if updated_at.empty?

        "#{model.class.table_name}/#{model.id}-#{updated_at}"
      end

      def shortened(text)
        prefix_bytes = MAX_KEY_BYTES - KEY_DIGEST_LENGTH - 1
        prefix = +""
        text.each_char do |character|
          break if prefix.bytesize + character.bytesize > prefix_bytes

          prefix << character
        end
        "#{prefix}:#{Digest::SHA256.hexdigest(text)}"
      end
    end
  end
end
