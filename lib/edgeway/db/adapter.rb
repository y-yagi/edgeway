module Edgeway
  module DB
    # The base of the database adapters. A subclass defines select_all and
    # execute, and overrides the rest where its database differs.
    class Adapter
      # The rows (Hash, column name => value) of a SELECT.
      #
      # Defined here for Spinel, which refuses the select_all call in
      # insert_returning when no subclass is loaded.
      def select_all(sql, binds)
        raise Error, "#{self.class} does not define select_all"
      end

      # {"changes" => n, "last_insert_id" => id}
      def execute(sql, binds)
        raise Error, "#{self.class} does not define execute"
      end

      # Runs [sql, binds] pairs as one atomic batch: all of them or none.
      # Answers one execute-style result per statement, in order.
      def batch(statements)
        raise Error, "#{self.class} does not define batch"
      end

      def insert_returning(sql, binds)
        rows = select_all(sql, binds)
        raise DatabaseError, "INSERT ... RETURNING answered no row" if rows.empty?
        rows[0]
      end

      # Raises the error for a failure message from the database: a UNIQUE
      # violation is RecordNotUnique (D1 says "UNIQUE constraint failed: t.c",
      # as SQLite does, for a PRIMARY KEY too), the rest DatabaseError. Here so
      # that the memory adapter's fail_next goes through the same mapping.
      def fail_with(message)
        raise RecordNotUnique, message if message.include?("UNIQUE constraint failed")
        raise DatabaseError, message
      end

      def supports_returning? = true
      def placeholder(n) = "?"
      def quote_boolean(value) = value ? 1 : 0
    end
  end
end
