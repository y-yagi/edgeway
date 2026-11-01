# frozen_string_literal: true

module Edgeway
  module CLI
    # Finds the Spinel compiler, for `edgeway build` and the Rakefile.
    #
    #   1. SPINEL (a Spinel checkout, for example)
    #   2. spinel on PATH (mise puts its spinel there when it is activated)
    #   3. `mise which spinel` (mise is installed but not activated)
    #
    # The WASI SDK that --target=wasm32-wasi needs is Spinel's to find: it
    # reads WASI_SDK (mise.toml sets it), then WASI_SDK_PATH, and defaults to
    # /opt/wasi-sdk.
    module Toolchain
      def self.spinel
        env = ENV["SPINEL"]
        return env unless env.nil? || env.empty?

        find_on_path("spinel") || mise_which("spinel")
      end

      def self.wasi_sdk
        dir = [ENV["WASI_SDK"], ENV["WASI_SDK_PATH"]].find { |value| !value.to_s.empty? } || "/opt/wasi-sdk"
        File.directory?(dir) ? dir : nil
      end

      def self.find_on_path(name)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |d| File.join(d, name) }
                   .find { |f| File.file?(f) && File.executable?(f) }
      end

      def self.mise_which(name)
        return nil unless find_on_path("mise")

        out = IO.popen(["mise", "which", name], err: File::NULL, &:read).strip
        $?.success? && !out.empty? ? out : nil
      end
    end
  end
end
