require "json"
require_relative "../import_result"
require_relative "kv_store"

module Edgeway
  module Cloudflare
    module KVImports
      ffi_source <<~C
        #define KV_IMPORT(name) __attribute__((import_module("edgeway_kv"), import_name(name)))

        KV_IMPORT("get")    int  js_kv_get(const char *binding, const char *key);
        KV_IMPORT("put")    int  js_kv_put(const char *binding, const char *key, const char *text, int expires_in);
        KV_IMPORT("delete") int  js_kv_delete(const char *binding, const char *key);
        KV_IMPORT("take")   void js_kv_take(char *buffer);

        static ImportResultBuffer kv_result;

        const char *kv_get(const char *binding, const char *key) {
          return take_import_result(&kv_result, js_kv_get(binding, key), js_kv_take);
        }

        const char *kv_put(const char *binding, const char *key, const char *text, int expires_in) {
          return take_import_result(&kv_result, js_kv_put(binding, key, text, expires_in), js_kv_take);
        }

        const char *kv_delete(const char *binding, const char *key) {
          return take_import_result(&kv_result, js_kv_delete(binding, key), js_kv_take);
        }
      C
      ffi_func :kv_get, [:str, :str], :str
      ffi_func :kv_put, [:str, :str, :str, :int], :str
      ffi_func :kv_delete, [:str, :str], :str
    end

    class KVImportTransport < KVTransport
      def get(binding_name, key) = KVImports.kv_get(binding_name, key)

      def put(binding_name, key, text, expires_in_seconds)
        KVImports.kv_put(binding_name, key, text, expires_in_seconds)
      end

      def delete(binding_name, key) = KVImports.kv_delete(binding_name, key)
    end
  end
end
