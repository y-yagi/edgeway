module Edgeway
  module DB
    # What the database reported for one request (D1's result metadata).
    class QueryStats
      MAX_COUNT = 2147483647

      attr_reader :queries, :rows_read, :rows_written, :duration_ms, :served_by_region, :served_by_primary

      def initialize
        @queries = 0
        @rows_read = 0
        @rows_written = 0
        @duration_ms = 0.0
        @served_by_region = ""
        @served_by_primary = true
      end

      def add(meta)
        rows_read = capped_sum(@rows_read, meta["rows_read"])
        rows_written = capped_sum(@rows_written, meta["rows_written"])
        duration_ms = @duration_ms + meta["duration"].to_f
        @rows_read = rows_read
        @rows_written = rows_written
        @duration_ms = duration_ms
        @served_by_region = meta["served_by_region"].to_s
        @served_by_primary = meta["served_by_primary"] != false
        @queries = capped_sum(@queries, 1)
      end

      def log_text
        "db=#{@queries} rows_read=#{count_text(@rows_read)} rows_written=#{count_text(@rows_written)} db_ms=#{format("%.2f", @duration_ms)}"
      end

      private

      def count_text(count)
        count == MAX_COUNT ? "#{count}+" : count.to_s
      end

      def capped_sum(total, count)
        return MAX_COUNT if count.to_i > MAX_COUNT - total
        total + count.to_i
      end
    end
  end
end
