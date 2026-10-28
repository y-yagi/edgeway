module Edgeway
  module Model
    class Relation
      # eager is the associations eager_load names (empty: none); records, when
      # set, are what to_a answers instead of a query (an eager-loaded has_many).
      # conds are the WHERE terms (each with its own "?"s) and binds their
      # values in order; eq_cols/eq_vals are the plain equality terms, which
      # build copies into the new record.
      attr_writer :records

      def initialize(model, conds = [], binds = [], eq_cols = [], eq_vals = [], order = [], limit = nil, offset = nil, eager = [])
        @model = model
        @conds = conds
        @binds = binds
        @eq_cols = eq_cols
        @eq_vals = eq_vals
        @order = order
        @limit = limit
        @offset = offset
        @eager = eager
        @records = nil
      end

      def where(conditions, *args)
        conds = @conds.dup
        binds = @binds.dup
        eq_cols = @eq_cols.dup
        eq_vals = @eq_vals.dup
        if conditions.is_a?(String)
          add_fragment(conditions, args, conds, binds)
        else
          raise ArgumentError, "where(Hash) takes no binds" unless args.empty?
          conditions.each do |k, v|
            column = @model.column(k)
            type = @model.type_of(column)
            if v.is_a?(Array)
              add_in(column, type, v, conds, binds)
            elsif v.is_a?(Range)
              add_range(column, type, v, conds, binds)
            else
              add_equality(column, type, v, conds, binds, eq_cols, eq_vals)
            end
          end
        end
        Relation.new(@model, conds, binds, eq_cols, eq_vals, @order, @limit, @offset, @eager)
      end

      def order(col, dir = :asc)
        Relation.new(@model, @conds, @binds, @eq_cols, @eq_vals, @order + [order_term(col, dir)], @limit, @offset, @eager)
      end

      # Replaces all the terms.
      def reorder(col, dir = :asc)
        Relation.new(@model, @conds, @binds, @eq_cols, @eq_vals, [order_term(col, dir)], @limit, @offset, @eager)
      end

      def limit(n)
        Relation.new(@model, @conds, @binds, @eq_cols, @eq_vals, @order, count_arg("limit", n), @offset, @eager)
      end

      def offset(n)
        Relation.new(@model, @conds, @binds, @eq_cols, @eq_vals, @order, @limit, count_arg("offset", n), @eager)
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
        Relation.new(@model, @conds, @binds, @eq_cols, @eq_vals, @order, @limit, @offset, eager)
      end

      # Same conditions, but to_a answers these records.
      def loaded(records)
        relation = Relation.new(@model, @conds, @binds, @eq_cols, @eq_vals, @order, @limit, @offset)
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
        Model.write("DELETE FROM #{@model.table_name}#{where_clause}", @binds)["changes"]
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

      def find_by(conditions) = Relation.new(@model, @conds, @binds, @eq_cols, @eq_vals, @order, @limit, nil, @eager).where(conditions).limit(1).to_a.first

      def find(id)
        find_by("id" => id) || raise(RecordNotFound, "#{@model.table_name} #{id} not found")
      end

      def build(attrs = {})
        record = @model.new(attrs)
        @eq_cols.each_with_index { |col, i| record.write_attribute(col, @eq_vals[i]) }
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
          return "#{theirs}.#{other.column(one.primary_key)} = #{mine}.#{@model.column(one.foreign_key)}"
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

      def add_fragment(sql, values, conds, binds)
        conds << "(#{sql})"
        values.each do |v|
          raise ArgumentError, "an Array bind in a SQL fragment isn't expanded; use where(column: [...])" if v.is_a?(Array)
          binds << Model.to_db(v)
        end
      end

      def add_in(column, type, values, conds, binds)
        vals = values.map { |x| bind_value(type, x) }
        rest = vals.compact
        has_nil = rest.size < vals.size
        if rest.empty?
          conds << (has_nil ? "#{column} IS NULL" : "1 = 0")
          return
        end
        term = "#{column} IN (#{rest.map { |_x| "?" }.join(", ")})"
        conds << (has_nil ? "(#{term} OR #{column} IS NULL)" : term)
        rest.each { |x| binds << x }
      end

      def add_range(column, type, range, conds, binds)
        lo = range.begin
        hi = range.end
        unless lo.nil?
          conds << "#{column} >= ?"
          binds << bind_value(type, lo)
        end
        unless hi.nil?
          conds << "#{column} #{range.exclude_end? ? "<" : "<="} ?"
          binds << bind_value(type, hi)
        end
      end

      def add_equality(column, type, value, conds, binds, eq_cols, eq_vals)
        bound = bind_value(type, value)
        if bound.nil?
          conds << "#{column} IS NULL"
        else
          conds << "#{column} = ?"
          binds << bound
        end
        eq_cols << column
        eq_vals << bound
      end

      # The value as it is bound. An integer outside 32 bits can't be held as
      # one; it goes as its text, which SQLite compares as the number it is
      # (an equality on it matches nothing: a find on it is a 404).
      def bind_value(type, v)
        v = Model.to_db(v) if v.is_a?(Time)
        casted = Model.cast(type, v)
        casted = v.to_s if casted.nil? && !v.nil?
        Model.to_db(casted)
      end

      def where_clause = @conds.empty? ? "" : " WHERE " + @conds.join(" AND ")

      def select(what, ordered)
        sql = "SELECT #{what} FROM #{@model.table_name}#{where_clause}"
        sql += " ORDER BY #{@order.join(", ")}" if ordered && !@order.empty?
        if @limit
          sql += " LIMIT #{@limit}"
        elsif @offset
          sql += " LIMIT -1"
        end
        sql += " OFFSET #{@offset}" if @offset
        [sql, @binds]
      end
    end
  end
end
