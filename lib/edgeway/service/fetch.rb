require_relative "../http/client"
require_relative "import_result"

module Edgeway
  module FetchImports
    ffi_source <<~C
      #define FETCH_IMPORT(name) __attribute__((import_module("edgeway_fetch"), import_name(name)))

      FETCH_IMPORT("request") int  js_fetch_request(const char *payload);
      FETCH_IMPORT("take")    void js_fetch_take(char *buffer);

      static ImportResultBuffer fetch_result;

      const char *fetch_request(const char *payload) {
        return take_import_result(&fetch_result, js_fetch_request(payload), js_fetch_take);
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
