require "json"
require_relative "../import_result"
require_relative "rate_limiter"

module Edgeway
  module Cloudflare
    module RateLimitImports
      ffi_source <<~C
        #define RATE_LIMIT_IMPORT(name) __attribute__((import_module("edgeway_ratelimit"), import_name(name)))

        RATE_LIMIT_IMPORT("check") int  js_rate_limit_check(const char *binding, const char *key);
        RATE_LIMIT_IMPORT("take")  void js_rate_limit_take(char *buffer);

        static ImportResultBuffer rate_limit_result;

        const char *rate_limit_check(const char *binding, const char *key) {
          return take_import_result(&rate_limit_result, js_rate_limit_check(binding, key), js_rate_limit_take);
        }
      C
      ffi_func :rate_limit_check, [:str, :str], :str
    end

    class RateLimitImportTransport < RateLimitTransport
      def check(binding_name, key) = RateLimitImports.rate_limit_check(binding_name, key)
    end
  end
end
