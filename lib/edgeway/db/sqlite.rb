# SQLite through Spinel's FFI (libsqlite3). Only Spinel builds load this file:
# ffi_lib is Spinel's, so CRuby can't read it (like service/cloudflare/d1; the
# CRuby tests use edgeway/db/memory). Needs libsqlite3 (libsqlite3-dev on
# Debian/Ubuntu) at link time.
#
#   db = Edgeway::DB::SQLiteAdapter.new(":memory:")
#   db.load_schema("CREATE TABLE todos (id INTEGER PRIMARY KEY, title TEXT)")
#   Edgeway::Model.connection = db
require "json"
require_relative "adapter"

module Edgeway
  module DB
    module SQLiteFFI
      ffi_lib "sqlite3"

      ffi_const :OK,   0
      ffi_const :ROW,  100
      ffi_const :DONE, 101

      ffi_func :sqlite3_open,            [:str, :ptr],                      :int
      ffi_func :sqlite3_close,           [:ptr],                            :int
      ffi_func :sqlite3_exec,            [:ptr, :str, :ptr, :ptr, :ptr],    :int
      ffi_func :sqlite3_prepare_v2,      [:ptr, :str, :int, :ptr, :ptr],    :int
      ffi_func :sqlite3_bind_text,       [:ptr, :int, :str, :int, :ptr],    :int
      ffi_func :sqlite3_bind_int64,      [:ptr, :int, :long],               :int
      ffi_func :sqlite3_bind_double,     [:ptr, :int, :double],             :int
      ffi_func :sqlite3_bind_null,       [:ptr, :int],                      :int
      ffi_func :sqlite3_step,            [:ptr],                            :int
      ffi_func :sqlite3_finalize,        [:ptr],                            :int
      ffi_func :sqlite3_column_count,    [:ptr],                            :int
      ffi_func :sqlite3_column_name,     [:ptr, :int],                      :str
      ffi_func :sqlite3_column_type,     [:ptr, :int],                      :int
      ffi_func :sqlite3_column_int64,    [:ptr, :int],                      :long
      ffi_func :sqlite3_column_double,   [:ptr, :int],                      :double
      ffi_func :sqlite3_column_text,     [:ptr, :int],                      :str
      ffi_func :sqlite3_errmsg,          [:ptr],                            :str
      ffi_func :sqlite3_last_insert_rowid, [:ptr],                          :long
      ffi_func :sqlite3_changes,         [:ptr],                            :int
      ffi_func :sqlite3_libversion_number, [],                              :int

      # Out-params: sqlite3_open writes the db handle, prepare_v2 the stmt.
      ffi_buffer :db_out,   8
      ffi_buffer :stmt_out, 8
      ffi_read_ptr :read_ptr, 0
    end

    class SQLiteAdapter < Adapter
      # sqlite3_column_type results.
      INTEGER = 1
      FLOAT = 2
      NULL = 5

      # The SQL executed so far, as MemoryAdapter logs it ("sql | [binds]").
      attr_reader :log

      # path: a file name, or ":memory:" (a fresh, private database).
      def initialize(path = ":memory:")
        @log = []
        rc = SQLiteFFI.sqlite3_open(path, SQLiteFFI.db_out)
        raise DatabaseError, "sqlite3_open failed: #{rc}" if rc != SQLiteFFI::OK
        @db = SQLiteFFI.read_ptr(SQLiteFFI.db_out)
        # Off by default in SQLite; ON DELETE CASCADE needs it.
        run_script("PRAGMA foreign_keys = ON")
        @returning = SQLiteFFI.sqlite3_libversion_number >= 3035000
      end

      def close
        SQLiteFFI.sqlite3_close(@db)
      end

      # RETURNING is SQLite 3.35+; older ones INSERT and read the row back.
      def supports_returning? = @returning

      def select_all(sql, binds)
        stmt = start(sql, binds)
        rows = []
        rc = SQLiteFFI.sqlite3_step(stmt)
        while rc == SQLiteFFI::ROW
          rows << read_row(stmt)
          rc = SQLiteFFI.sqlite3_step(stmt)
        end
        finish(stmt, rc)
        rows
      end

      def execute(sql, binds)
        stmt = start(sql, binds)
        rc = SQLiteFFI.sqlite3_step(stmt)
        # A RETURNING statement answers rows even when executed; drain them.
        while rc == SQLiteFFI::ROW
          rc = SQLiteFFI.sqlite3_step(stmt)
        end
        finish(stmt, rc)
        { "changes" => SQLiteFFI.sqlite3_changes(@db), "last_insert_id" => SQLiteFFI.sqlite3_last_insert_rowid(@db) }
      end

      # One transaction: all the statements or none.
      def batch(statements)
        @log << "BATCH #{statements.size}"
        run_script("BEGIN")
        results = []
        begin
          statements.each { |s| results << execute(s[0], s[1]) }
        rescue => e
          run_script("ROLLBACK")
          raise e
        end
        run_script("COMMIT")
        results
      end

      # Runs SQL text of one or more statements (a schema or a migration).
      def load_schema(sql_text)
        @log << sql_text
        run_script(sql_text)
      end

      # Applies dir/*.sql in file name order (db/migrations); the file names.
      def apply_migrations(dir)
        files = Dir.glob(File.join(dir, "*.sql")).sort
        files.each { |f| load_schema(File.read(f)) }
        files
      end

      private

      def run_script(sql_text)
        rc = SQLiteFFI.sqlite3_exec(@db, sql_text, nil, nil, nil)
        fail_with(SQLiteFFI.sqlite3_errmsg(@db)) if rc != SQLiteFFI::OK
      end

      # A prepared statement with the binds set. On failure the statement is
      # finalized before the error is raised.
      def start(sql, binds)
        @log << "#{sql} | #{JSON.generate(binds)}"
        rc = SQLiteFFI.sqlite3_prepare_v2(@db, sql, -1, SQLiteFFI.stmt_out, nil)
        if rc != SQLiteFFI::OK
          message = SQLiteFFI.sqlite3_errmsg(@db)
          fail_with(message)
        end
        stmt = SQLiteFFI.read_ptr(SQLiteFFI.stmt_out)
        i = 0
        while i < binds.size
          rc = bind(stmt, i + 1, binds[i])
          if rc != SQLiteFFI::OK
            message = SQLiteFFI.sqlite3_errmsg(@db)
            SQLiteFFI.sqlite3_finalize(stmt)
            fail_with(message)
          end
          i += 1
        end
        stmt
      end

      def bind(stmt, n, value)
        if value.nil?
          SQLiteFFI.sqlite3_bind_null(stmt, n)
        elsif value.is_a?(Integer)
          SQLiteFFI.sqlite3_bind_int64(stmt, n, value)
        elsif value.is_a?(Float)
          SQLiteFFI.sqlite3_bind_double(stmt, n, value)
        elsif value == true
          SQLiteFFI.sqlite3_bind_int64(stmt, n, 1)
        elsif value == false
          SQLiteFFI.sqlite3_bind_int64(stmt, n, 0)
        else
          # -1: SQLITE_TRANSIENT, SQLite copies the text.
          SQLiteFFI.sqlite3_bind_text(stmt, n, value.to_s, -1, -1)
        end
      end

      # Finalizes the statement; raises if its last step failed.
      def finish(stmt, rc)
        message = rc == SQLiteFFI::DONE ? "" : SQLiteFFI.sqlite3_errmsg(@db)
        SQLiteFFI.sqlite3_finalize(stmt)
        fail_with(message) if rc != SQLiteFFI::DONE
      end

      def read_row(stmt)
        row = {}
        n = SQLiteFFI.sqlite3_column_count(stmt)
        i = 0
        while i < n
          name = SQLiteFFI.sqlite3_column_name(stmt, i)
          type = SQLiteFFI.sqlite3_column_type(stmt, i)
          if type == NULL
            row[name] = nil
          elsif type == INTEGER
            row[name] = SQLiteFFI.sqlite3_column_int64(stmt, i)
          elsif type == FLOAT
            row[name] = SQLiteFFI.sqlite3_column_double(stmt, i)
          else
            row[name] = SQLiteFFI.sqlite3_column_text(stmt, i)
          end
          i += 1
        end
        row
      end
    end
  end
end
