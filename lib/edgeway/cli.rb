# frozen_string_literal: true

# The edgeway command (CRuby). Not part of the wasm: lib/edgeway.rb does not
# require it.
require "fileutils"
require "yaml"
require_relative "version"
require_relative "cli/app_config"
require_relative "cli/toolchain"
require_relative "cli/app_files"
require_relative "cli/build"
require_relative "cli/precheck"
require_relative "cli/test"
require_relative "cli/routes"
require_relative "cli/package_manager"
require_relative "cli/generate"
require_relative "cli/new"

module Edgeway
  module CLI
    USAGE = <<~TEXT
      Usage: edgeway COMMAND [options]

        new APP                  create a new app in APP/
        build [--env ENV]        compile the app to build/app.wasm (ENV: development)
        test [ARGS]              regenerate tmp/test_app.rb, run test/ with spinel_test-unit
        generate, g KIND NAME    generate a model (NAME field:type ...) or a controller (NAME action ...)
        routes                   print the routes
        version                  print the version
    TEXT

    class Error < StandardError; end

    # The directory of the gem: lib/ is what Spinel gets as -I, js/ is
    # copied into the app's build/.
    def self.gem_dir
      File.expand_path("../..", __dir__)
    end

    def self.start(argv)
      command, *args = argv
      case command
      when "new" then New.run(args)
      when "build" then Build.run(args)
      when "test" then Test.run(args)
      when "generate", "g" then Generate.run(args)
      when "routes" then Routes.run(args)
      when "version", "-v", "--version" then puts "edgeway #{Edgeway::VERSION}"
      when nil, "help", "-h", "--help" then puts USAGE
      else
        warn "edgeway: unknown command #{command}\n\n#{USAGE}"
        exit 1
      end
    rescue Error => e
      warn "edgeway: #{e.message}"
      exit 1
    end
  end
end
