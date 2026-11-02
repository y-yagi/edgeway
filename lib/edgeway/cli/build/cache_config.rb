# frozen_string_literal: true

require_relative "../../cache/limits"

module Edgeway
  module CLI
    class Build
      class CacheConfig
        STORES = {
          "kv" => "edgeway/service/cloudflare/kv",
          "memory" => nil,
          "null" => nil
        }.freeze
        KEYS = %w[store binding namespace expires_in].freeze

        attr_reader :store, :binding_name, :namespace, :expires_in

        def self.load(root, env)
          path = File.join(root, "config", "cache.yml")
          return new("null") unless File.exist?(path)

          sections = YAML.safe_load_file(path) || {}
          raise Error, "config/cache.yml must be a Hash of environments" unless sections.is_a?(Hash)

          section = sections[env]
          return new("null") if section.nil?
          raise Error, "config/cache.yml: #{env} must be a Hash" unless section.is_a?(Hash)

          from_section(section, env)
        end

        def self.from_section(section, env)
          unknown = section.keys.map(&:to_s) - KEYS
          raise Error, "config/cache.yml: unknown #{unknown.join(", ")} in #{env} (one of #{KEYS.join(", ")})" unless unknown.empty?

          new(store_name(section), binding_name: section["binding"], namespace: section["namespace"],
                               expires_in: section["expires_in"], env: env)
        end

        def self.store_name(section)
          section.key?("store") && section["store"].nil? ? "null" : section["store"]
        end

        def initialize(store, binding_name: nil, namespace: nil, expires_in: nil, env: "development")
          @env = env
          @store = checked_store(store)
          @binding_name = checked_binding(binding_name)
          @namespace = checked_namespace(namespace)
          @expires_in = checked_expires_in(expires_in)
        end

        def backend_file = STORES.fetch(@store)

        def store_expression
          case @store
          when "kv" then kv_expression
          when "memory" then "Edgeway::Cache::MemoryStore.new(#{store_options})"
          else "Edgeway::Cache::NullStore.new"
          end
        end

        private

        def store_options = "namespace: #{@namespace.inspect}, expires_in: #{@expires_in.inspect}"

        def kv_expression
          "Edgeway::Cloudflare::KVStore.new(binding: #{@binding_name.inspect}, #{store_options}, " \
            "transport: Edgeway::Cloudflare::KVImportTransport.new)"
        end

        def checked_store(store)
          return store if STORES.key?(store)

          raise Error, "config/cache.yml: store in #{@env} must be one of #{STORES.keys.join(", ")} (got #{store.inspect})"
        end

        def checked_binding(binding_name)
          return checked_unused_binding(binding_name) unless @store == "kv"
          raise Error, "config/cache.yml: binding: in #{@env} must be a String" unless binding_name.nil? || binding_name.is_a?(String)
          return binding_name unless binding_name.nil? || binding_name.empty?

          raise Error, "config/cache.yml: #{@env} has store: kv but no binding: (the name of a [[kv_namespaces]] binding in wrangler.toml)"
        end

        def checked_unused_binding(binding_name)
          raise Error, "config/cache.yml: binding: is only for store: kv (in #{@env})" unless binding_name.nil?

          nil
        end

        def checked_namespace(namespace)
          return nil if namespace.nil?
          raise Error, "config/cache.yml: namespace in #{@env} must be a non-empty String" unless namespace.is_a?(String) && !namespace.empty?
          return namespace if namespace.valid_encoding? && !namespace.include?("\0")

          raise Error, "config/cache.yml: namespace in #{@env} must be valid UTF-8 without a NUL byte"
        end

        def checked_expires_in(seconds)
          return nil if seconds.nil?
          return seconds if seconds.is_a?(Integer) && seconds.between?(1, Edgeway::Cache::MAX_EXPIRES_IN)

          raise Error, "config/cache.yml: expires_in in #{@env} must be a whole number of seconds, 1 to #{Edgeway::Cache::MAX_EXPIRES_IN}"
        end
      end
    end
  end
end
