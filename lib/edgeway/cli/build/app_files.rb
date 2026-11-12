# frozen_string_literal: true

module Edgeway
  module CLI
    class Build
      class AppFiles
        def initialize(root)
          @root = root
        end

        def require_lines(views: nil, dispatch: nil)
          lines = files.map { |file| require_line(file) }
          lines << "require_relative #{views.dump}" if views
          lines << "require_relative #{dispatch.dump}" if dispatch
          lines << 'require_relative "../config/routes"'
          lines
        end

        def files
          app = File.join(@root, "app")
          directories = Dir.exist?(app) ? Dir.children(app).sort.select { |name| File.directory?(File.join(app, name)) } : []
          generic = directories.reject { |name| %w[models controllers].include?(name) }
          (generic.map { |name| "app/#{name}" } + ["app/models", "app/controllers"]).flat_map { |directory| files_in(directory) }
        end

        private

        def files_in(directory)
          full = File.join(@root, directory)
          return [] unless Dir.exist?(full)

          paths = Dir.glob("**/*.rb", base: full).map { |path| File.join(directory, path) }
          first, rest = paths.partition { |path| File.basename(path).start_with?("application_") }
          first.sort + rest.sort
        end

        # String#dump quotes a path with spaces, quotes or "#{" safely.
        def require_line(file)
          "require_relative #{"../#{file.delete_suffix(".rb")}".dump}"
        end
      end
    end
  end
end
