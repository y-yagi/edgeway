# frozen_string_literal: true

module Edgeway
  module CLI
    # config/database.yml for one environment:
    #
    #   production:
    #     adapter: d1
    #     binding: DB
    #   test:
    #     adapter: memory
    class AppConfig
      # adapter: => the file build/main.rb requires for it.
      ADAPTERS = {
        "d1" => "edgeway/service/cloudflare/d1",
        "memory" => "edgeway/db/memory"
      }.freeze

      attr_reader :env, :adapter, :binding_name

      def self.load(root, env)
        path = File.join(root, "config", "database.yml")
        raise Error, "no config/database.yml in #{root} (is this an Edgeway app?)" unless File.exist?(path)

        section = (YAML.safe_load_file(path) || {})[env]
        raise Error, "config/database.yml has no #{env} section" unless section.is_a?(Hash)

        new(env, section["adapter"].to_s, (section["binding"] || "DB").to_s)
      end

      def initialize(env, adapter, binding_name)
        raise Error, "unknown database adapter #{adapter.inspect} (one of #{ADAPTERS.keys.join(", ")})" unless ADAPTERS.key?(adapter)

        @env = env
        @adapter = adapter
        @binding_name = binding_name
      end

      def adapter_file = ADAPTERS.fetch(@adapter)
    end
  end
end
