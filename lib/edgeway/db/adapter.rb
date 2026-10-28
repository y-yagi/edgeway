module Edgeway
  module DB
    class Adapter
      MAX_BINDS = 100

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

      def check_binds(binds)
        return if binds.size <= MAX_BINDS
        raise ArgumentError, "too many bind parameters: #{binds.size} (D1 allows #{MAX_BINDS})"
      end

      def fail_with(message)
        raise RecordNotUnique, message if message.include?("UNIQUE constraint failed")
        raise NotNullViolation, message if message.include?("NOT NULL constraint failed")
        raise InvalidForeignKey, message if message.include?("FOREIGN KEY constraint failed")
        raise CheckViolation, message if message.include?("CHECK constraint failed")
        raise DatabaseError, message
      end

      def raise_error_result(res, prefix = "")
        message = "#{prefix}#{res["error"]}"
        raise DatabaseUnavailable, message if res.key?("unavailable")
        fail_with(message)
      end

      def supports_returning? = true
      def placeholder(n) = "?"
      def quote_boolean(value) = value ? 1 : 0
    end
  end
end
