# frozen_string_literal: true

module Edgeway
  module CLI
    # The order in which an app's files are required (see Build). Shared by
    # `edgeway build` (build/main.rb) and `edgeway test` (tmp/test_app.rb),
    # because Spinel resolves require at compile time.
    class AppFiles
      def initialize(root)
        @root = root
      end

      # require_relative lines, relative to build/ and tmp/, in load order: app/*/ other
      # than models/ and controllers/, then models, controllers, config/routes.
      def require_lines
        lines = []
        app = File.join(@root, "app")
        dirs = Dir.exist?(app) ? Dir.children(app).sort.select { |d| File.directory?(File.join(app, d)) } : []
        dirs.each do |d|
          next if %w[models controllers].include?(d)

          lines.concat(requires("app/#{d}"))
        end
        lines.concat(requires("app/models"))
        lines.concat(requires("app/controllers"))
        lines << 'require_relative "../config/routes"'
        lines
      end

      # require_relative lines for the .rb files under dir, application_*.rb first.
      def requires(dir)
        full = File.join(@root, dir)
        return [] unless Dir.exist?(full)

        files = Dir.glob("**/*.rb", base: full).map { |f| File.join(dir, f) }
        first, rest = files.partition { |f| File.basename(f).start_with?("application_") }
        # String#dump quotes a path with spaces, quotes or "#{" safely.
        (first.sort + rest.sort).map { |f| "require_relative #{"../#{f.delete_suffix(".rb")}".dump}" }
      end
    end
  end
end
