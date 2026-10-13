require_relative "adapter"

module Edgeway
  module DB
    # An adapter for tests: it records the SQL it is given and answers the
    # rows the test queued (none: an empty answer). Nothing is stored.
    #
    #   db = Edgeway::DB::MemoryAdapter.new
    #   Edgeway::Model.connection = db
    #   db.queue([{ "id" => 1, "title" => "a" }])
    #   Todo.find(1)
    #   puts db.log      # SELECT ... | [1]
    class MemoryAdapter < Adapter
      attr_reader :log
      attr_writer :returning
      # The "changes" count execute answers (1 by default), for delete_all.
      attr_writer :changes

      def initialize
        @log = []
        @queue = []
        @returning = true
        @changes = 1
        @failure = nil
        @failure_on = ""
        @next_id = 1
      end

      # The rows the next query answers (one queue entry per query).
      def queue(rows)
        @queue << rows
      end

      # Makes the next query or execute whose SQL contains `containing` (any,
      # by default) fail with this database message, after logging it, as D1
      # would: "UNIQUE constraint failed: t.c" is a RecordNotUnique.
      def fail_next(message, containing = "")
        @failure = message
        @failure_on = containing
      end

      def supports_returning? = @returning

      def select_all(sql, binds)
        record(sql, binds)
        @queue.empty? ? [] : @queue.shift
      end

      def execute(sql, binds)
        record(sql, binds)
        id = @next_id
        @next_id += 1
        { "changes" => @changes, "last_insert_id" => id }
      end

      def batch(statements)
        @log << "BATCH #{statements.size}"
        statements.map { |s| execute(s[0], s[1]) }
      end

      private

      def record(sql, binds)
        @log << "#{sql} | #{JSON.generate(binds)}"
        if !@failure.nil? && sql.include?(@failure_on)
          message = @failure
          @failure = nil
          fail_with(message)
        end
      end
    end
  end
end
