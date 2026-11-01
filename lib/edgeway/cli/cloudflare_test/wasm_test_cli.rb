# frozen_string_literal: true

module Edgeway
  module CLI
    class CloudflareTest
      class WasmTestCLI < SpinelTest::Unit::CLI
        def initialize(argv, root:, launcher:)
          super(argv, root: root)
          @launcher = launcher
        end

        private

        def compile(spinel, main, bin, entries)
          wasm = File.join(@root, "tmp/test_app.wasm")
          command = [spinel, "--target=wasm32-wasi", "--incremental"] +
                    include_dirs(entries).flat_map { |directory| ["-I", directory] } + [main, "-o", wasm]
          output, status = Open3.capture2e(*command)
          unless status.success?
            warn output unless output.empty?
            warn "edgeway test: compilation failed (#{command.join(" ")})"
            return false
          end
          write_launcher(bin, wasm)
        end

        def write_launcher(bin, wasm)
          File.write(bin, "#!/bin/sh\nexec #{Shellwords.join(@launcher + [wasm])} \"$@\"\n")
          File.chmod(0o755, bin)
          true
        end
      end
    end
  end
end
