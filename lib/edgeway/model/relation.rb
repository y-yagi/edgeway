module Edgeway
  module Model
    class Relation
      def initialize(model, where_cols = [], binds = [], order = [], limit = nil, offset = nil)
        @model = model
        @where_cols = where_cols
        @binds = binds
        @order = order
        @limit = limit
        @offset = offset
      end

      def where(conditions)
        cols = @where_cols.dup
        binds = @binds.dup
        conditions.each do |k, v|
          col = @model.column(k)
          casted = Model.cast(@model.type_of(col), v)
          # An integer outside 32 bits can't be held as one; it goes as its
          # text, which SQLite compares as the number it is, so nothing
          # matches (a find on it is a 404).
          casted = v.to_s if casted.nil? && !v.nil?
          cols << col
          binds << Model.to_db(casted)
        end
        Relation.new(@model, cols, binds, @order, @limit, @offset)
      end

      # Adds a term, as Rails: order(:a).order(:b, :desc) is ORDER BY a ASC, b DESC.
      def order(col, dir = :asc)
        Relation.new(@model, @where_cols, @binds, @order + [order_term(col, dir)], @limit, @offset)
      end

      # Replaces all the terms.
      def reorder(col, dir = :asc)
        Relation.new(@model, @where_cols, @binds, [order_term(col, dir)], @limit, @offset)
      end

      def limit(n)
        Relation.new(@model, @where_cols, @binds, @order, count_arg("limit", n), @offset)
      end

      def offset(n)
        Relation.new(@model, @where_cols, @binds, @order, @limit, count_arg("offset", n))
      end

      def to_a
        sql, binds = select(@model.columns.join(", "), true)
        Model.connection.select_all(sql, binds).map { |row| @model.instantiate(row) }
      end

      def count
        sql, binds = select("1", false)
        Model.connection.select_all("SELECT COUNT(*) AS n FROM (#{sql})", binds)[0]["n"].to_i
      end

      def exists? = limit(1).count > 0

      def pluck(col)
        name = @model.column(col)
        type = @model.type_of(name)
        sql, binds = select(name, true)
        Model.connection.select_all(sql, binds).map { |row| Model.cast(type, row[name]) }
      end

      def first = (@order.empty? ? order(:id) : self).limit(1).to_a.first
      # One DELETE of the rows this relation matches; the number deleted.
      # Nothing is instantiated and no dependents run (destroy_all does that).
      # Inside Model.batch the count is 0 (not known yet). Order is ignored. SQLite has no DELETE ... LIMIT in general, so a
      # limit or offset is refused.
      def delete_all
        raise ArgumentError, "delete_all doesn't support limit/offset" if @limit || @offset
        conn = Model.connection
        where_sql, _marks = where_clause(conn)
        Model.write("DELETE FROM #{@model.table_name}#{where_sql}", @binds.compact)["changes"]
      end

      # Destroys each record in turn, so their dependents run; the records.
      def destroy_all
        records = to_a
        records.each { |r| r.destroy }
        records
      end

      def each(&block) = to_a.each(&block)
      def map(&block) = to_a.map(&block)
      def size = to_a.size
      def empty? = !exists?

      def find_by(conditions) = Relation.new(@model, @where_cols, @binds, @order, @limit, nil).where(conditions).limit(1).to_a.first

      def find(id)
        find_by({ "id" => id }) || raise(RecordNotFound, "#{@model.table_name} #{id} not found")
      end

      def build(attrs = {})
        record = @model.new(attrs)
        @where_cols.each_with_index { |col, i| record.write_attribute(col, @binds[i]) }
        record
      end

      def create(attrs = {})
        record = build(attrs)
        record.save
        record
      end

      def create!(attrs = {})
        record = build(attrs)
        record.save!
        record
      end

      # The record with these conditions (and this relation's), or a new one
      # saved with them. Two requests can both find nothing and both create;
      # the database's UNIQUE constraint refuses the second (RecordNotUnique),
      # and then the record the first made is the answer.
      def find_or_create_by(conditions) = find_or_create(conditions, false)
      def find_or_create_by!(conditions) = find_or_create(conditions, true)

      private

      def find_or_create(conditions, bang)
        found = find_by(conditions)
        return found unless found.nil?
        begin
          bang ? create!(conditions) : create(conditions)
        rescue Edgeway::RecordNotUnique => e
          again = find_by(conditions)
          raise e if again.nil?
          again
        end
      end

      def count_arg(what, n)
        i = Model.to_int(n)
        raise BadRequest, "bad #{what}: #{n}" if i.nil? || i < 0
        i
      end

      def order_term(col, dir)
        d = dir.to_s.downcase
        raise BadRequest, "bad order direction: #{dir}" unless d == "asc" || d == "desc"
        "#{@model.column(col)} #{d.upcase}"
      end

      # " WHERE ..." (empty without conditions) and the number of placeholders
      # it used. A nil value is IS NULL, with no bind.
      def where_clause(conn)
        marks = 0
        return ["", marks] if @where_cols.empty?
        conds = @where_cols.each_with_index.map do |c, i|
          if @binds[i].nil?
            "#{c} IS NULL"
          else
            marks += 1
            "#{c} = #{conn.placeholder(marks)}"
          end
        end
        [" WHERE " + conds.join(" AND "), marks]
      end

      def select(what, ordered)
        conn = Model.connection
        where_sql, _marks = where_clause(conn)
        sql = "SELECT #{what} FROM #{@model.table_name}#{where_sql}"
        sql += " ORDER BY #{@order.join(", ")}" if ordered && !@order.empty?
        binds = @binds.compact
        if @limit
          binds = binds + [@limit]
          sql += " LIMIT #{conn.placeholder(binds.size)}"
        elsif @offset
          sql += " LIMIT -1"
        end
        if @offset
          binds = binds + [@offset]
          sql += " OFFSET #{conn.placeholder(binds.size)}"
        end
        [sql, binds]
      end
    end
  end
end
