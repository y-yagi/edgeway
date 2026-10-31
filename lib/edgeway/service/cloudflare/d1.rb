# Cloudflare D1, through the wasm import module "edgeway_d1" that
# js/cloudflare.js implements. Only wasm builds load this file: ffi_source is
# Spinel's, so CRuby can't read it (tests use edgeway/db/memory).
require "json"
require_relative "../../db/adapter"

module Edgeway
  module Cloudflare
    # The imports as Ruby methods: d1_query and d1_execute take the binding
    # name, the SQL and the binds (JSON text); d1_exec takes the binding name
    # and SQL text of one or more statements; d1_batch takes the binding name
    # and the statements ([[sql, binds], ...], JSON text), and answer the result as JSON
    # text:
    #
    #   d1_query    {"rows": [...], "meta": META}
    #   d1_execute  {"changes": n, "last_insert_id": id, "meta": META}
    #   d1_exec     {"count": n, "meta": META}
    #   d1_batch    {"results": [{"changes": n, "last_insert_id": id}, ...], "meta": META}
    #   META        {"rows_read": n, "rows_written": n, "duration": ms,
    #                "served_by_region": "...", "served_by_primary": bool}
    #               (a batch's is the sum over its statements)
    #   BLOB        a bind or a column value that is a BLOB is {"$blob": "<base64>"}
    #               (raw bytes can't cross: JSON text holds no arbitrary bytes)
    #   last_insert_id  is a number; a rowid beyond 32 bits is a Bignum here,
    #               which last_insert_id_of turns into its decimal String
    #   any         {"error": "message"} when D1 failed
    #   any         {"error": "message", "unavailable": true} when it failed
    #               in a transient way (DatabaseUnavailable)
    #
    # An import can't hand a string to wasm, so a call is two: each import
    # runs the statement(s) and answers the byte length of its result, and
    # take(buf) copies the result into buf. JS wraps each import in
    # WebAssembly.Suspending: the D1 Promise is awaited with the wasm stack
    # suspended (JSPI), so they read like blocking calls here.
    module D1Imports
      ffi_source <<~C
        #include <stdlib.h>

        #define D1_IMPORT(name) __attribute__((import_module("edgeway_d1"), import_name(name)))

        D1_IMPORT("query")   int  js_d1_query(const char *binding, const char *sql, const char *binds);
        D1_IMPORT("execute") int  js_d1_execute(const char *binding, const char *sql, const char *binds);
        D1_IMPORT("exec")    int  js_d1_exec(const char *binding, const char *sql);
        D1_IMPORT("batch")   int  js_d1_batch(const char *binding, const char *statements);
        D1_IMPORT("take")    void js_d1_take(char *buf);

        /* The last result, NUL-terminated; grown as needed and reused. */
        static char *result;
        static int result_cap;

        static const char *take_result(int length) {
          if (length + 1 > result_cap) {
            char *grown = realloc(result, length + 1);
            if (!grown) abort();
            result = grown;
            result_cap = length + 1;
          }
          js_d1_take(result);
          result[length] = 0;
          return result;
        }

        /* What ffi_func binds. Its own extern declaration would lose the
           import attributes, so the imports are wrapped. */
        const char *d1_query(const char *binding, const char *sql, const char *binds) {
          return take_result(js_d1_query(binding, sql, binds));
        }

        const char *d1_execute(const char *binding, const char *sql, const char *binds) {
          return take_result(js_d1_execute(binding, sql, binds));
        }

        const char *d1_exec(const char *binding, const char *sql) {
          return take_result(js_d1_exec(binding, sql));
        }

        const char *d1_batch(const char *binding, const char *statements) {
          return take_result(js_d1_batch(binding, statements));
        }
      C
      ffi_func :d1_query, [:str, :str, :str], :str
      ffi_func :d1_execute, [:str, :str, :str], :str
      ffi_func :d1_exec, [:str, :str], :str
      ffi_func :d1_batch, [:str, :str], :str
    end

    class D1Adapter < DB::Adapter
      # binding: the name of the D1 binding in wrangler.toml.
      def initialize(binding: "DB")
        @binding_name = binding
      end

      def select_all(sql, binds)
        check_binds(binds)
        result(D1Imports.d1_query(@binding_name, sql, JSON.generate(binds)))["rows"]
      end

      def execute(sql, binds)
        check_binds(binds)
        res = result(D1Imports.d1_execute(@binding_name, sql, JSON.generate(binds)))
        write_result(res)
      end

      def exec(sql)
        result(D1Imports.d1_exec(@binding_name, sql))
      end

      # One D1 batch(): the statements run as a single transaction, so any
      # failure rolls all of them back.
      def batch(statements)
        statements.each { |s| check_binds(s[1]) }
        res = result(D1Imports.d1_batch(@binding_name, JSON.generate(statements)))
        res["results"].map { |entry| write_result(entry) }
      end

      private

      def write_result(entry)
        { "changes" => entry["changes"].to_i, "last_insert_id" => last_insert_id_of(entry["last_insert_id"]) }
      end

      def result(json)
        res = JSON.parse(json)
        raise_error_result(res, "d1: ") if res.key?("error")
        record_meta(res["meta"]) if res.key?("meta")
        res
      end
    end
  end
end
