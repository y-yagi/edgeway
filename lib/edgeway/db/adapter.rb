module Edgeway
  module DB
    class Adapter
      def select_all(sql, binds)
        raise Error, "#{self.class} does not define select_all"
      end

      def execute(sql, binds)
        raise Error, "#{self.class} does not define execute"
      end

      def batch(statements)
        raise Error, "#{self.class} does not define batch"
      end

      def insert_returning(sql, binds)
        rows = select_all(sql, binds)
        raise DatabaseError, "INSERT ... RETURNING answered no row" if rows.empty?
        rows[0]
      end

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
