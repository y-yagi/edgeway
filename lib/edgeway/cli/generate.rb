# frozen_string_literal: true

require_relative "../inflector"
require_relative "package_manager"

module Edgeway
  module CLI
    class Generate
      USAGE = <<~TEXT
        Usage: edgeway generate model NAME [field:type ...]
               edgeway generate controller NAME [action ...]
               edgeway generate scaffold NAME [field:type ...]

        Types: #{%w[string text integer float boolean datetime].join(", ")} (default string)
      TEXT

      # field type => its column's SQL type, its attribute type, and the values
      # (as Ruby source) the scaffold's test creates and updates with.
      # D1 is SQLite, which has no datetime/boolean type (only NULL, INTEGER,
      # REAL, TEXT and BLOB): a datetime is TEXT (ISO 8601, as Model.now
      # writes it) and a boolean is an INTEGER 0/1. It is SQLite's, not a
      # Cloudflare, limit.
      Type = Struct.new(:sql, :attr, :created, :updated)
      TYPES = {
        "string" => Type.new("TEXT", ":string", '"MyString"', '"Updated"'),
        "text" => Type.new("TEXT", ":string", '"MyText"', '"Updated"'),
        "integer" => Type.new("INTEGER", ":integer", "1", "2"),
        "float" => Type.new("REAL", ":float", "1.5", "2.5"),
        "boolean" => Type.new("INTEGER NOT NULL DEFAULT 0", ":boolean", "true", "false"),
        "datetime" => Type.new("TEXT", ":datetime", '"2026-01-01T00:00:00Z"', '"2026-02-01T00:00:00Z"')
      }.freeze

      Field = Struct.new(:name, :sql, :attr, :created, :updated)

      RESOURCE_ACTIONS = %w[index show create update destroy].freeze

      def self.run(args)
        kind, name, *rest = args
        raise Error, USAGE unless %w[model controller scaffold].include?(kind) && name && !name.start_with?("-")

        generator = new(Dir.pwd)
        generator.public_send(kind, name, rest)
      end

      def initialize(root)
        @root = root
        return if File.exist?(File.join(root, "config/routes.rb"))

        raise Error, "no config/routes.rb in #{root}; run this inside an app made by `edgeway new`"
      end

      def model(name, fields)
        base = underscore(name)
        columns = fields.map { |f| parse_field(f) }
        write_all(model_files(base, columns))
        puts_migration_hint
      end

      def controller(name, actions)
        base = underscore(name).delete_suffix("_controller")
        actions.each { |a| raise Error, "invalid action name: #{a}" unless a.match?(/\A[a-z_][a-z0-9_]*\z/) }
        write_all([
          ["app/controllers/#{base}_controller.rb", controller_source(camelize(base), actions)],
          ["test/controllers/#{base}_test.rb", controller_test_source(camelize(base))]
        ])
        puts_route_hints(route_hints(base, actions))
      end

      def scaffold(name, fields)
        base = underscore(Inflector.singularize(name))
        plural = Inflector.pluralize(base)
        columns = fields.map { |f| parse_field(f) }
        # Every path is checked before the first is written: no half a scaffold.
        write_all(model_files(base, columns) + [
          ["app/controllers/#{plural}_controller.rb", scaffold_controller_source(camelize(base), plural, columns)],
          ["test/controllers/#{plural}_test.rb", scaffold_test_source(camelize(base), plural, columns)]
        ])
        add_route(plural)
        puts_migration_hint
      end

      private

      def underscore(name)
        raise Error, "invalid name: #{name}" unless name.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)

        name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      def camelize(name) = Inflector.camelize(name)

      # "title:string" => Field.new("title", "TEXT", ":string", '"MyString"', '"Updated"')
      def parse_field(spec)
        name, type = spec.split(":", 2)
        type ||= "string"
        raise Error, "invalid field name: #{spec}" unless name.match?(/\A[a-z_][a-z0-9_]*\z/)
        raise Error, "unknown field type #{type} (#{TYPES.keys.join(", ")})" unless TYPES.key?(type)

        Field.new(name, *TYPES[type].to_a)
      end

      def model_files(base, columns)
        table = Inflector.pluralize(base)
        existing = Dir.glob("db/migrations/*_create_#{table}.sql", base: @root).first
        raise Error, "#{existing} already exists" if existing

        [
          ["app/models/#{base}.rb", model_source(camelize(base), columns)],
          ["db/migrations/#{next_migration_number}_create_#{table}.sql", migration_source(table, columns)],
          ["test/models/#{base}_test.rb", model_test_source(camelize(base))]
        ]
      end

      def puts_migration_hint
        puts "\nApply the migration locally: #{PackageManager.exec} wrangler d1 migrations apply DB_NAME --local"
      end

      def add_route(plural)
        path = File.join(@root, "config/routes.rb")
        text = File.read(path)
        match = text.match(/^([ \t]*)[\w.]*routes\.draw[ \t]+do[ \t]*\|[ \t]*(\w+)[ \t]*\|[ \t]*(\r?\n)/)
        return puts_route_hints(["r.resources :#{plural}"], "no `routes.draw do |r|` block found") unless match

        indent, var, eol = match.captures
        line = "#{var}.resources :#{plural}"
        return puts "  identical  #{line}" if text.match?(/^[ \t]*#{Regexp.escape(var)}\.resources[ \t]*\(?[ \t]*:#{plural}(?!\w)/)

        close = text.index(/^#{Regexp.escape(indent)}end\b/, match.end(0))
        return puts_route_hints([line], "no closing `end` found") unless close

        File.write(path, text[0...close] + "#{indent}  #{line}#{eol}" + text[close..])
        puts "  route  #{line}"
      end

      def puts_route_hints(hints, reason = nil)
        puts "\nconfig/routes.rb not changed: #{reason}" if reason
        puts "\nAdd to config/routes.rb:"
        hints.each { |l| puts "  #{l}" }
      end

      def model_source(klass, columns)
        lines = columns.map do |c|
          c.attr == ":boolean" ? "  attribute :#{c.name}, :boolean, default: false" : "  attribute :#{c.name}, #{c.attr}"
        end
        lines << "  timestamps"
        "class #{klass} < ApplicationModel\n#{lines.join("\n")}\nend\n"
      end

      def migration_source(table, columns)
        lines = ["  id INTEGER PRIMARY KEY AUTOINCREMENT"]
        columns.each { |c| lines << "  #{c.name} #{c.sql}" }
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

      def scaffold_controller_source(klass, plural, columns)
        var = underscore(klass)
        lines = [
          "class #{camelize(plural)}Controller < ApplicationController",
          "  def index = render json: #{klass}.order(:id).limit(50)",
          "",
          "  def show = render json: #{klass}.find(params[:id])",
          "",
          "  def create",
          "    #{var} = #{columns.empty? ? "#{klass}.create!" : "#{klass}.create!(#{var}_params)"}",
          "    render json: #{var}, status: :created",
          "  end",
          "",
          "  def update",
          "    #{var} = #{klass}.find(params[:id])"
        ]
        lines << "    #{var}.update!(#{var}_params)" unless columns.empty?
        lines += [
          "    render json: #{var}",
          "  end",
          "",
          "  def destroy",
          "    #{klass}.find(params[:id]).destroy",
          "    head :no_content",
          "  end"
        ]
        unless columns.empty?
          permitted = columns.map { |c| ":#{c.name}" }.join(", ")
          lines += ["", "  private", "", "  def #{var}_params = params.require(:#{var}).permit(#{permitted})"]
        end
        lines << "end"
        lines.join("\n") + "\n"
      end

      def scaffold_test_source(klass, plural, columns)
        var = underscore(klass)
        create_args = columns.empty? ? "" : "(#{columns.map { |c| "#{c.name}: #{c.created}" }.join(", ")})"
        hash = lambda do |value|
          columns.empty? ? "{}" : "{ #{columns.map { |c| "\"#{c.name}\" => #{c.public_send(value)}" }.join(", ")} }"
        end
        checks = ->(value) { columns.map { |c| "    assert_equal #{c.public_send(value)}, json[\"#{c.name}\"]" }.join("\n") }
        <<~RUBY
          require "edgeway/test"
          require "test_helper"

          class #{camelize(plural)}Test < Edgeway::IntegrationTest
            def test_index
              #{var} = #{klass}.create!#{create_args}
              get "/#{plural}"
              assert_response 200
              assert_equal 1, json.size
              assert_equal #{var}.id, json[0]["id"]
            end

            def test_show
              #{var} = #{klass}.create!#{create_args}
              get "/#{plural}/\#{#{var}.id}"
              assert_response 200
              assert_equal #{var}.id, json["id"]
            end

            def test_show_not_found
              get "/#{plural}/0"
              assert_response 404
            end

            def test_create
              post "/#{plural}", json: { "#{var}" => #{hash.call(:created)} }
              assert_response 201
              assert_equal 1, #{klass}.count
          #{checks.call(:created)}
            end

            def test_update
              #{var} = #{klass}.create!#{create_args}
              patch "/#{plural}/\#{#{var}.id}", json: { "#{var}" => #{hash.call(:updated)} }
              assert_response 200
          #{checks.call(:updated)}
            end

            def test_destroy
              #{var} = #{klass}.create!#{create_args}
              delete "/#{plural}/\#{#{var}.id}"
              assert_response 204
              assert_equal 0, #{klass}.count
            end
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

      def write_all(files)
        files.each { |rel, _text| raise Error, "#{rel} already exists" if File.exist?(File.join(@root, rel)) }
        files.each { |rel, text| write(rel, text) }
      end

      def write(rel, text)
        dest = File.join(@root, rel)
        FileUtils.mkdir_p(File.dirname(dest))
        File.write(dest, text)
        puts "  create  #{rel}"
      end
    end
  end
end
