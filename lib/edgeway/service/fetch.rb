require_relative "../http/client"

module Edgeway
  module FetchImports
    ffi_source <<~C
      #include <stdlib.h>

      #define FETCH_IMPORT(name) __attribute__((import_module("edgeway_fetch"), import_name(name)))

      FETCH_IMPORT("request") int  js_fetch_request(const char *payload);
      FETCH_IMPORT("take")    void js_fetch_take(char *buffer);

      static char *fetch_result;
      static int fetch_result_capacity;

      const char *fetch_request(const char *payload) {
        int length = js_fetch_request(payload);
        if (length + 1 > fetch_result_capacity) {
          char *grown = realloc(fetch_result, length + 1);
          if (!grown) abort();
          fetch_result = grown;
          fetch_result_capacity = length + 1;
        }
        js_fetch_take(fetch_result);
        fetch_result[length] = 0;
        return fetch_result;
      }
    C
    ffi_func :fetch_request, [:str], :str
  end

  class FetchTransport < HTTP::Transport
    def request(payload)
      FetchImports.fetch_request(payload)
    end
  end
end
