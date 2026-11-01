# frozen_string_literal: true

require "shellwords"
require "open3"

module Edgeway
  module CLI
    class CloudflareTest < Test
      RUNTIME_DIR = "tmp/edgeway"
      RUNNER = "cloudflare-test-runner.js"
      MIN_NODE_MAJOR = 24

      # The apps whose test environment uses the d1 adapter.
      def self.handles?(database)
        database.section?("test") && database.section("test")["adapter"] == "d1"
      end

      def initialize(root)
        super
        @config = Build::AppConfig.load(root, "test")
      end

      def run(args)
        check_prerequisites
        write_test_app
        write_runtime
        require_spinel_test_unit
        argv = ["-I", @root, "-I", CLI.gem_dir + "/lib", *args]
        exit WasmTestCLI.new(argv, root: @root, launcher: launcher).run
      end

      private

      def database_lines
        [
          'require "edgeway/db/memory"',
          'require "edgeway/service/cloudflare/test_databases"',
          'require "edgeway/service/cloudflare/jwt"',
          "module Edgeway; TEST_DATABASES = #{@config.databases.keys.inspect}; end",
          "module Edgeway; TEST_BINDINGS = #{bindings.inspect}; end"
        ]
      end

      def bindings
        { "primary" => @config.binding_name }.merge(@config.databases)
      end

      def migration_directories
        { "primary" => "db/migrations" }.merge(@config.databases.to_h { |name, _binding| [name, "db/#{name}/migrations"] })
      end

      def write_runtime
        databases = bindings.map do |name, binding_name|
          { "binding" => binding_name, "migrations" => File.join(@root, migration_directories.fetch(name)) }
        end
        values = {
          "env" => "test", "d1Binding" => @config.binding_name, "sessions" => @config.sessions,
          "appRoot" => @root, "databases" => databases
        }
        directory = File.join(@root, RUNTIME_DIR)
        Build::JsFiles.copy(directory, Build::JsFiles.config_js(values, "test"), tests: true)
        File.write(File.join(directory, "package.json"), %({"type": "module"}\n))
      end

      def launcher
        ["node", *node_flags, File.join(@root, RUNTIME_DIR, RUNNER)]
      end

      def node_flags
        has_jspi = system("node", "-e", "process.exit(typeof WebAssembly.Suspending === 'function' ? 0 : 1)")
        has_jspi ? [] : ["--experimental-wasm-jspi", "--experimental-wasm-exnref"]
      end

      def require_spinel_test_unit
        require "spinel_test/unit/cli"
        require_relative "cloudflare_test/wasm_test_cli"
      rescue LoadError
        raise Error, 'spinel_test-unit is not installed (add gem "spinel_test-unit", "~> 0.1", group: :test to the Gemfile and run bundle install)'
      end

      def check_prerequisites
        check_node
        raise Error, "no wrangler.toml in #{@root} (the tests run on the local D1 it describes)" unless File.exist?(File.join(@root, "wrangler.toml"))

        check_wrangler
        raise Error, "no WASI SDK found (install it with mise, or set WASI_SDK=/path/to/wasi-sdk)" unless Toolchain.wasi_sdk
        raise Error, "no Spinel compiler found (install it with mise, or set SPINEL=/path/to/spinel)" unless Toolchain.spinel

        check_migration_directories
      end

      def check_node
        raise Error, "node is not installed; `edgeway test` runs the tests on the local D1 of wrangler, which needs Node.js #{MIN_NODE_MAJOR} or later" unless Toolchain.find_on_path("node")

        version, = Open3.capture2("node", "-p", "process.versions.node")
        return if version.to_i >= MIN_NODE_MAJOR

        raise Error, "Node.js #{version.strip} is too old: `edgeway test` needs #{MIN_NODE_MAJOR} or later (WebAssembly JSPI)"
      end

      def check_wrangler
        return if File.directory?(File.join(@root, "node_modules/wrangler"))

        raise Error, "wrangler is not installed in #{@root}/node_modules; run #{PackageManager.install} (or bin/setup)"
      end

      def check_migration_directories
        @config.databases.each_key do |name|
          directory = migration_directories.fetch(name)
          next if File.directory?(File.join(@root, directory))

          raise Error, "database #{name} (config/database.yml) has no #{directory} directory"
        end
      end
    end

    Test::PLATFORMS << CloudflareTest
  end
end
