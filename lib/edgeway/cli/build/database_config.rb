# frozen_string_literal: true

module Edgeway
  module CLI
    class Build
      class DatabaseConfig
        DATABASE_NAME = /\A[a-z_][a-z0-9_]*\z/

        def initialize(root)
          @root = root
        end

        def section(env)
          section = sections[env]
          raise Error, "config/database.yml has no #{env} section" unless section.is_a?(Hash)

          section
        end

        def databases_in(section, env)
          entries = section["databases"] || {}
          raise Error, "config/database.yml: databases in #{env} must be a Hash" unless entries.is_a?(Hash)

          entries.to_h do |name, entry|
            name = name.to_s
            [name, database_binding(name, entry, env)]
          end
        end

        def names
          names = []
          return names unless File.exist?(path)

          sections.each do |env, section|
            next unless section.is_a?(Hash)
            databases_in(section, env).each_key { |name| names << name unless names.include?(name) }
          end
          names
        end

        private

        def path = File.join(@root, "config", "database.yml")

        def sections
          raise Error, "no config/database.yml in #{@root} (is this an Edgeway app?)" unless File.exist?(path)

          YAML.safe_load_file(path) || {}
        end

        def database_binding(name, entry, env)
          unless name.match?(DATABASE_NAME) && name != "primary"
            raise Error, "config/database.yml: bad database name #{name.inspect} in #{env} (lowercase letters, digits and _, and not primary)"
          end

          binding_name = entry.is_a?(Hash) ? entry["binding"].to_s : ""
          raise Error, "config/database.yml: databases.#{name} in #{env} has no binding:" if binding_name.empty?

          binding_name
        end
      end
    end
  end
end
