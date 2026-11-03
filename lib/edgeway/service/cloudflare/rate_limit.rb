require "json"
require_relative "rate_limiter"

module Edgeway
  module Cloudflare
    module RateLimitImports
      ffi_source <<~C
        #include <stdlib.h>

        #define RATE_LIMIT_IMPORT(name) __attribute__((import_module("edgeway_ratelimit"), import_name(name)))

        RATE_LIMIT_IMPORT("check") int  js_rate_limit_check(const char *binding, const char *key);
        RATE_LIMIT_IMPORT("take")  void js_rate_limit_take(char *buffer);

        static char *rate_limit_result;
        static int rate_limit_result_capacity;

        const char *rate_limit_check(const char *binding, const char *key) {
          int length = js_rate_limit_check(binding, key);
          if (length + 1 > rate_limit_result_capacity) {
            char *grown = realloc(rate_limit_result, length + 1);
            if (!grown) abort();
            rate_limit_result = grown;
            rate_limit_result_capacity = length + 1;
          }
          js_rate_limit_take(rate_limit_result);
          rate_limit_result[length] = 0;
          return rate_limit_result;
        }
      C
      ffi_func :rate_limit_check, [:str, :str], :str
    end

    class RateLimitImportTransport < RateLimitTransport
      def check(binding_name, key) = RateLimitImports.rate_limit_check(binding_name, key)
    end
  end
end
