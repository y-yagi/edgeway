# frozen_string_literal: true

require_relative "js_files"

module Edgeway
  module CLI
    class Build
      class CloudflarePlatform
        ADAPTERS = %w[d1 memory].freeze
        STORES = %w[kv memory null].freeze

        def name = "cloudflare"

        def adapters = ADAPTERS

        def stores = STORES

        # Always, whatever the app uses: js/cloudflare.js supplies the
        # edgeway_jwt, edgeway_fetch and edgeway_ratelimit imports to every app,
        # and each is only called by an app that authenticates, calls out or
        # rate limits.
        def service_lines
          [
            'require "edgeway/service/jwt"',
            'require "edgeway/service/fetch"',
            'require "edgeway/service/cloudflare/rate_limit"'
          ]
        end

        def setup_lines
          [
            "Edgeway::Auth.verifier = Edgeway::JWTVerifier.new",
            "Edgeway::HTTP.client = Edgeway::FetchTransport.new"
          ]
        end

        def rate_limiter_lines
          [
            "Edgeway::Controller.rate_limiter = Edgeway::Cloudflare::RateLimiter.new(transport: Edgeway::Cloudflare::RateLimitImportTransport.new)"
          ]
        end

        def adapter_expression(adapter, binding_name)
          case adapter
          when "d1" then "Edgeway::Cloudflare::D1Adapter.new(binding: #{binding_name.inspect})"
          else "Edgeway::DB::MemoryAdapter.new"
          end
        end

        def js_paths(tests: false) = JsFiles.paths(name, tests)
      end

      PlatformConfig::PLATFORMS["cloudflare"] = CloudflarePlatform
    end
  end
end
