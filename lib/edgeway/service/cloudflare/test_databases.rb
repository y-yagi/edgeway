require_relative "d1"

module Edgeway
  module Cloudflare
    module TestImports
      ffi_source <<~C
        __attribute__((import_module("edgeway_test"), import_name("reset"))) void js_test_reset(void);

        int test_reset(void) {
          js_test_reset();
          return 0;
        }
      C
      ffi_func :test_reset, [], :int
    end

    class TestD1Adapter < D1Adapter
      attr_reader :log

      def initialize(binding: "DB")
        super(binding: binding)
        @log = []
      end

      def select_all(sql, binds)
        log_statement(sql, binds)
        super(sql, binds)
      end

      def execute(sql, binds)
        log_statement(sql, binds)
        super(sql, binds)
      end

      def exec(sql)
        log_statement(sql, [])
        super(sql)
      end

      def batch(statements)
        @log << "BATCH #{statements.size}"
        super(statements)
      end

      def close
      end

      private

      def log_statement(sql, binds)
        @log << "#{sql} | #{JSON.generate(binds)}"
      end
    end
  end

  module TestDatabases
    def self.reset
      Cloudflare::TestImports.test_reset
    end

    def self.open(name)
      Cloudflare::TestD1Adapter.new(binding: Edgeway::TEST_BINDINGS.fetch(name))
    end
  end
end
