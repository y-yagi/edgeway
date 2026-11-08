# frozen_string_literal: true

module Edgeway
  module CLI
    class Build
      class PlatformConfig
        # name => the platform class; each platform file registers itself.
        PLATFORMS = {}
        DEFAULT = "cloudflare"
        KEYS = %w[platform].freeze

        def self.load(root)
          path = File.join(root, "config", "edgeway.yml")
          return platform_named(DEFAULT) unless File.exist?(path)

          settings = YAML.safe_load_file(path) || {}
          raise Error, "config/edgeway.yml must be a Hash" unless settings.is_a?(Hash)

          unknown = settings.keys.map(&:to_s) - KEYS
          raise Error, "config/edgeway.yml: unknown #{unknown.join(", ")} (one of #{KEYS.join(", ")})" unless unknown.empty?

          platform_named(settings.fetch("platform", DEFAULT))
        end

        def self.platform_named(name)
          platform = PLATFORMS[name]
          raise Error, "config/edgeway.yml: platform must be one of #{PLATFORMS.keys.join(", ")} (got #{name.inspect})" unless platform

          platform.new
        end
      end
    end
  end
end

Dir[File.join(__dir__, "*_platform.rb")].sort.each { |file| require file }
