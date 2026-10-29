# frozen_string_literal: true

require_relative "database_config"

module Edgeway
  module CLI
    class Build
      class AppConfig
        # adapter: => the file build/main.rb requires for it.
        ADAPTERS = {
          "d1" => "edgeway/service/cloudflare/d1",
          "memory" => "edgeway/db/memory"
        }.freeze

        attr_reader :env, :adapter, :binding_name, :databases, :sessions

        def self.load(root, env)
          config = DatabaseConfig.new(root)
          section = config.section(env)
          databases = config.databases_in(section, env)
          sessions = config.session_bindings(section, env)
          new(env, section["adapter"].to_s, config.primary_binding(section), databases, sessions)
        end

        def initialize(env, adapter, binding_name, databases = {}, sessions = [])
          raise Error, "unknown database adapter #{adapter.inspect} (one of #{ADAPTERS.keys.join(", ")})" unless ADAPTERS.key?(adapter)

          @env = env
          @adapter = adapter
          @binding_name = binding_name
          @databases = databases
          @sessions = adapter == "d1" ? sessions : []
        end

        def adapter_file = ADAPTERS.fetch(@adapter)
      end
    end
  end
end
