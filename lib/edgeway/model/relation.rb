module Edgeway
  module Model
    class Relation
      # eager is the associations eager_load names (empty: none); records, when
      # set, are what to_a answers instead of a query (an eager-loaded has_many).
      attr_writer :records

      def initialize(model, where_cols = [], binds = [], order = [], limit = nil, offset = nil, eager = [])
        @model = model
        @where_cols = where_cols
        @binds = binds
        @order = order
        @limit = limit
        @offset = offset
        @eager = eager
        @records = nil
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
        Relation.new(@model, cols, binds, @order, @limit, @offset, @eager)
      end

      def order(col, dir = :asc)
        Relation.new(@model, @where_cols, @binds, @order + [order_term(col, dir)], @limit, @offset, @eager)
      end

      # Replaces all the terms.
      def reorder(col, dir = :asc)
        Relation.new(@model, @where_cols, @binds, [order_term(col, dir)], @limit, @offset, @eager)
      end

      def limit(n)
        Relation.new(@model, @where_cols, @binds, @order, count_arg("limit", n), @offset, @eager)
      end

      def offset(n)
        Relation.new(@model, @where_cols, @binds, @order, @limit, count_arg("offset", n), @eager)
      end

      # Loads the has_manys and belongs_tos named of every record with the one
      # query: a LEFT JOIN each, always (no separate preload query). The
      # records' associations then answer from memory. Calls accumulate.
      #
      #   Todo.eager_load(:comments, :tags).to_a.each { |t| t.comments.to_a }
      def eager_load(*names)
        eager = @eager.dup
        names.each do |n|
          eager << n.to_s unless eager.include?(n.to_s)
        end
        Relation.new(@model, @where_cols, @binds, @order, @limit, @offset, eager)
      end

      # Same conditions, but to_a answers these records.
      def loaded(records)
        relation = Relation.new(@model, @where_cols, @binds, @order, @limit, @offset)
        relation.records = records
        relation
      end

      def to_a
        return @records unless @records.nil?
        return eager_records unless @eager.empty?
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

      def delete_all
        raise ArgumentError, "delete_all doesn't support limit/offset" if @limit || @offset
        conn = Model.connection
        where_sql, _marks = where_clause(conn)
        Model.write("DELETE FROM #{@model.table_name}#{where_sql}", @binds.compact)["changes"]
      end

      def destroy_all
        records = to_a
        records.each { |r| r.destroy }
        records
      end

      def each(&block) = to_a.each(&block)
      def map(&block) = to_a.map(&block)
      def size = to_a.size
      def empty? = !exists?

      def find_by(conditions) = Relation.new(@model, @where_cols, @binds, @order, @limit, nil, @eager).where(conditions).limit(1).to_a.first

      def find(id)
        find_by("id" => id) || raise(RecordNotFound, "#{@model.table_name} #{id} not found")
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

      def find_or_create_by(conditions) = find_or_create(conditions, false)
      def find_or_create_by!(conditions) = find_or_create(conditions, true)

      private

      # The records with @eager loaded. The conditions, order and limit apply
      # to our own records, so they run in a subquery that each association's
      # table is joined to. A row is one of ours with one of each association's
      # (nil without any); joining several has_manys repeats a child once per
      # row of the others, so a record of ours comes once however many rows it
      # has, and each child once per record (by id).
      def eager_records
        mine = @model.table_name
        many_flags = []
        joins = []
        cols = @model.columns.map { |c| "#{mine}.#{c} AS p_#{c}" }
        order = @order.empty? ? ["#{mine}.id"] : @order.map { |t| "#{mine}.#{t}" }
        @eager.each_with_index do |name, i|
          many_flags << eager_many?(name)
          other = Edgeway::Model::Base.model_named(name, @model.name)
          theirs = "eager_#{name}"
          joins << " LEFT JOIN #{other.table_name} AS #{theirs} ON #{eager_on(name, other, theirs)}"
          cols = cols + other.columns.map { |c| "#{theirs}.#{c} AS c#{i}_#{c}" }
          order << "#{theirs}.id"
        end
        inner, binds = select(@model.columns.join(", "), true)
        sql = "SELECT #{cols.join(", ")} FROM (#{inner}) AS #{mine}#{joins.join}"
        sql += " ORDER BY #{order.join(", ")}"

        records = []
        # children[i][j]: the records of association j of record i
        children = []
        position = {}
        seen = {}
        Model.connection.select_all(sql, binds).each do |row|
          id = row["p_id"]
          i = position[id]
          if i.nil?
            i = records.size
            position[id] = i
            mine_row = {}
            @model.columns.each { |c| mine_row[c] = row["p_" + c] }
            records << @model.instantiate(mine_row)
            lists = []
            @eager.each { |_n| lists << [] }
            children << lists
          end
          @eager.each_with_index do |name, j|
            cid = row["c#{j}_id"]
            next if cid.nil?
            key = "#{j}:#{id}:#{cid}"
            next if seen.key?(key)
            seen[key] = true
            other = Edgeway::Model::Base.model_named(name, @model.name)
            their_row = {}
            other.columns.each { |c| their_row[c] = row["c#{j}_" + c] }
            children[i][j] << other.instantiate(their_row)
          end
        end
        records.each_with_index do |record, i|
          @eager.each_with_index do |name, j|
            if many_flags[j]
              record.cache_children(name, record.association(name).loaded(children[i][j]))
            else
              record.cache_parent(name, children[i][j][0]) unless children[i][j].empty?
            end
          end
        end
        records
      end

      def eager_many?(name)
        many = nil
        @model.has_manys.each { |h| many = h if h.name == name }
        one = nil
        @model.belongs_to_list.each { |b| one = b if b.name == name }
        raise ArgumentError, "no association #{name}" if many.nil? && one.nil?
        !many.nil?
      end

      # The join condition of the association `name` (the model `other`,
      # joined as `theirs`) to our records.
      def eager_on(name, other, theirs)
        mine = @model.table_name
        many = nil
        @model.has_manys.each { |h| many = h if h.name == name }
        if many.nil?
          one = nil
          @model.belongs_to_list.each { |b| one = b if b.name == name }
          # .dup: since matz/spinel 44119ab30 (Strings shared by reference),
          # Spinel refuses this String as it is, or emits C that doesn't compile.
          return "#{theirs}.#{other.column(one.primary_key.dup)} = #{mine}.#{@model.column(one.foreign_key.dup)}"
        end
        fk = many.foreign_key.nil? ? "#{Model.underscore(@model.name.split("::").last)}_id" : many.foreign_key
        pk = many.primary_key.nil? ? "id" : many.primary_key
        "#{theirs}.#{other.column(fk)} = #{mine}.#{@model.column(pk)}"
      end

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
