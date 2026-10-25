# frozen_string_literal: true

module Edgeway
  module CLI
    class Build
      class AppFiles
        def initialize(root)
          @root = root
        end

        def require_lines(views: nil)
          lines = []
          app = File.join(@root, "app")
          dirs = Dir.exist?(app) ? Dir.children(app).sort.select { |d| File.directory?(File.join(app, d)) } : []
          dirs.each do |d|
            next if %w[models controllers].include?(d)

            lines.concat(requires("app/#{d}"))
          end
          lines.concat(requires("app/models"))
          lines.concat(requires("app/controllers"))
          lines << "require_relative #{views.dump}" if views
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
end
