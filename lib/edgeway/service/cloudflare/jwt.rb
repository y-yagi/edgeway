# JWT signature checks on Cloudflare Workers, through the wasm import module
# "edgeway_jwt" that js/jwt.js implements. Only wasm builds load this file
# (ffi_source is Spinel's; tests use edgeway/http/auth/stub).
require "json"
require_relative "../../http/auth/jwt"
require_relative "../import_result"

module Edgeway
  module Cloudflare
    module JWTImports
      ffi_source <<~C
        #define JWT_IMPORT(name) __attribute__((import_module("edgeway_jwt"), import_name(name)))

        JWT_IMPORT("verify") int  js_jwt_verify(const char *token);
        JWT_IMPORT("take")   void js_jwt_take(char *buf);

        static ImportResultBuffer jwt_result;

        const char *jwt_verify(const char *token) {
          return take_import_result(&jwt_result, js_jwt_verify(token), js_jwt_take);
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
