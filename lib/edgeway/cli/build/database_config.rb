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

        def section?(env)
          File.exist?(path) && sections[env].is_a?(Hash)
        end

        def databases_in(section, env)
          entries = section["databases"] || {}
          raise Error, "config/database.yml: databases in #{env} must be a Hash" unless entries.is_a?(Hash)

          entries.to_h do |name, entry|
            name = name.to_s
            [name, database_binding(name, entry, env)]
          end
        end

        def primary_binding(section) = (section["binding"] || "DB").to_s

        def session_bindings(section, env)
          flags = {}
          record_sessions(flags, "the #{env} section", primary_binding(section), section, "the #{env} section")
          (section["databases"] || {}).each do |name, entry|
            record_sessions(flags, "databases.#{name}", entry["binding"].to_s, entry, "databases.#{name} in #{env}")
          end
          flags.select { |_binding, (_label, enabled)| enabled }.keys
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

        def record_sessions(flags, label, binding_name, entry, where)
          enabled = sessions?(entry, where)
          known_label, known = flags[binding_name]
          if known_label && known != enabled
            raise Error, "config/database.yml: #{known_label} and #{label} share binding #{binding_name} but differ in sessions"
          end

          flags[binding_name] = [label, enabled]
        end

        def sessions?(entry, where)
          return false unless entry.is_a?(Hash) && entry.key?("sessions")
          return entry["sessions"] if [true, false].include?(entry["sessions"])

          raise Error, "config/database.yml: sessions in #{where} must be true or false"
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
