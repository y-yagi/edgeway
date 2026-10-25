# frozen_string_literal: true

require_relative "../inflector"
require_relative "package_manager"

module Edgeway
  module CLI
    class Generate
      USAGE = <<~TEXT
        Usage: edgeway generate model NAME [field:type ...]
               edgeway generate controller NAME [action ...]

        Types: #{%w[string text integer float boolean datetime].join(", ")} (default string)
      TEXT

      # field type => [the column's SQL type, its attribute type]
      # D1 is SQLite, which has no datetime/boolean type (only NULL, INTEGER,
      # REAL, TEXT and BLOB): a datetime is TEXT (ISO 8601, as Model.now
      # writes it) and a boolean is an INTEGER 0/1. It is SQLite's, not a
      # Cloudflare, limit.
      TYPES = {
        "string" => ["TEXT", ":string"],
        "text" => ["TEXT", ":string"],
        "integer" => ["INTEGER", ":integer"],
        "float" => ["REAL", ":float"],
        "boolean" => ["INTEGER NOT NULL DEFAULT 0", ":boolean"],
        "datetime" => ["TEXT", ":datetime"]
      }.freeze

      RESOURCE_ACTIONS = %w[index show create update destroy].freeze

      def self.run(args)
        kind, name, *rest = args
        raise Error, USAGE unless %w[model controller].include?(kind) && name && !name.start_with?("-")

        generator = new(Dir.pwd)
        kind == "model" ? generator.model(name, rest) : generator.controller(name, rest)
      end

      def initialize(root)
        @root = root
        return if File.exist?(File.join(root, "config/routes.rb"))

        raise Error, "no config/routes.rb in #{root}; run this inside an app made by `edgeway new`"
      end

      def model(name, fields)
        base = underscore(name)
        table = Inflector.pluralize(base)
        columns = fields.map { |f| parse_field(f) }
        write("app/models/#{base}.rb", model_source(camelize(base), columns))
        write("db/migrations/#{next_migration_number}_create_#{table}.sql", migration_source(table, columns))
        write("test/models/#{base}_test.rb", model_test_source(camelize(base)))
        puts "\nApply the migration locally: #{PackageManager.exec} wrangler d1 migrations apply DB_NAME --local"
      end

      def controller(name, actions)
        base = underscore(name).delete_suffix("_controller")
        actions.each { |a| raise Error, "invalid action name: #{a}" unless a.match?(/\A[a-z_][a-z0-9_]*\z/) }
        write("app/controllers/#{base}_controller.rb", controller_source(camelize(base), actions))
        write("test/controllers/#{base}_test.rb", controller_test_source(camelize(base)))
        puts "\nAdd to config/routes.rb:"
        route_hints(base, actions).each { |l| puts "  #{l}" }
      end

      private

      def underscore(name)
        raise Error, "invalid name: #{name}" unless name.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)

        name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      def camelize(name) = Inflector.camelize(name)

      # "title:string" => ["title", "TEXT", ":string"]
      def parse_field(spec)
        name, type = spec.split(":", 2)
        type ||= "string"
        raise Error, "invalid field name: #{spec}" unless name.match?(/\A[a-z_][a-z0-9_]*\z/)
        raise Error, "unknown field type #{type} (#{TYPES.keys.join(", ")})" unless TYPES.key?(type)

        [name, *TYPES[type]]
      end

      def model_source(klass, columns)
        lines = columns.map do |name, _sql, attr|
          attr == ":boolean" ? "  attribute :#{name}, :boolean, default: false" : "  attribute :#{name}, #{attr}"
        end
        lines << "  timestamps"
        "class #{klass} < ApplicationModel\n#{lines.join("\n")}\nend\n"
      end

      def migration_source(table, columns)
        lines = ["  id INTEGER PRIMARY KEY AUTOINCREMENT"]
        columns.each { |name, sql, _attr| lines << "  #{name} #{sql}" }
        lines << "  created_at TEXT" << "  updated_at TEXT"
        "CREATE TABLE #{table} (\n#{lines.join(",\n")}\n);\n"
      end

      def model_test_source(klass)
        <<~RUBY
          require "edgeway/test"
          require "test_helper"

          class #{klass}Test < Edgeway::UnitTest
            def test_starts_empty
              assert_equal 0, #{klass}.count
            end
          end
        RUBY
      end

      def controller_source(klass, actions)
        defs = actions.map { |a| "  def #{a} = render json: {}\n" }
        "class #{klass}Controller < ApplicationController\n#{defs.join("\n")}end\n"
      end

      def controller_test_source(klass)
        <<~RUBY
          require "edgeway/test"
          require "test_helper"

          class #{klass}Test < Edgeway::IntegrationTest
            # def test_index
            #   get "/#{underscore(klass)}"
            #   assert_response 200
            # end
          end
        RUBY
      end

      def route_hints(base, actions)
        return ["r.resources :#{base}"] if actions.empty?

        standard = actions & RESOURCE_ACTIONS
        # Before the resources: "/todos/archive" would match "/todos/:id" first.
        hints = (actions - standard).map { |a| "r.get \"/#{base}/#{a}\", to: \"#{base}##{a}\"" }
        hints << "r.resources :#{base}, only: [#{standard.map { |a| ":#{a}" }.join(", ")}]" unless standard.empty?
        hints
      end

      # NNNN, one above the highest numbered file in db/migrations (0001 for none).
      def next_migration_number
        dir = File.join(@root, "db/migrations")
        last = Dir.exist?(dir) ? Dir.children(dir).filter_map { |f| f[/\A\d+/]&.to_i }.max.to_i : 0
        format("%04d", last + 1)
      end

      def write(rel, text)
        dest = File.join(@root, rel)
        raise Error, "#{rel} already exists" if File.exist?(dest)

        FileUtils.mkdir_p(File.dirname(dest))
        File.write(dest, text)
        puts "  create  #{rel}"
      end
    end
  end
end
