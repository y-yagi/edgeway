# JWT signature checks on Cloudflare Workers, through the wasm import module
# "edgeway_jwt" that js/jwt.js implements. Only wasm builds load this file
# (ffi_source is Spinel's; tests use edgeway/http/auth/stub).
require "json"
require_relative "../../http/auth/jwt"

module Edgeway
  module Cloudflare
    # jwt_verify takes the token and answers the result as JSON text (see
    # Auth::Verifier). As with D1, an import can't hand a string to wasm, so
    # a call is two: verify answers the byte length of the result, and
    # take(buf) copies it into buf. JS wraps verify in WebAssembly.Suspending,
    # so WebCrypto and the JWKS fetch read like blocking calls here.
    module JWTImports
      ffi_source <<~C
        #include <stdlib.h>

        #define JWT_IMPORT(name) __attribute__((import_module("edgeway_jwt"), import_name(name)))

        JWT_IMPORT("verify") int  js_jwt_verify(const char *token);
        JWT_IMPORT("take")   void js_jwt_take(char *buf);

        /* The last result, NUL-terminated; grown as needed and reused. */
        static char *jwt_result;
        static int jwt_result_cap;

        const char *jwt_verify(const char *token) {
          int length = js_jwt_verify(token);
          if (length + 1 > jwt_result_cap) {
            char *grown = realloc(jwt_result, length + 1);
            if (!grown) abort();
            jwt_result = grown;
            jwt_result_cap = length + 1;
          }
          js_jwt_take(jwt_result);
          jwt_result[length] = 0;
          return jwt_result;
        }
      C
      ffi_func :jwt_verify, [:str], :str
    end

    class JWTVerifier < Auth::Verifier
      def verify(token)
        JWTImports.jwt_verify(token)
      end
    end
  end
end
