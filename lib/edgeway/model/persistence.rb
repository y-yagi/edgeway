module Edgeway
  module Model
    # A has_many: the association's name, its foreign key and primary key (nil
    # for the defaults) and its dependent mode (nil, "destroy" or "delete_all").
    class HasMany
      attr_reader :name, :foreign_key, :primary_key, :mode

      def initialize(name, foreign_key, primary_key, mode)
        @name = name
        @foreign_key = foreign_key
        @primary_key = primary_key
        @mode = mode
      end
    end

    # A belongs_to: the association's name, our foreign key column and the
    # parent's primary key column.
    class BelongsTo
      attr_reader :name, :foreign_key, :primary_key

      def initialize(name, foreign_key, primary_key)
        @name = name
        @foreign_key = foreign_key
        @primary_key = primary_key
      end
    end

    module Persistence
      def save
        return false unless valid?
        touch(!@persisted)
        if @persisted
          update_row
        else
          insert_row
        end
        true
      end

      def save!
        raise RecordInvalid.new(@errors) unless save
        true
      end

      def update(attrs)
        assign(attrs)
        save
      end

      def update!(attrs)
        assign(attrs)
        save!
      end

      def destroy
        if self.class.dependents.empty?
          delete_row
        else
          Model.batch do
            self.class.dependents.each do |d|
              if d.mode == "destroy"
                association(d.name).destroy_all
              else
                association(d.name).delete_all
              end
            end
            delete_row
          end
        end
        @persisted = false
        true
      end

      # eager_load keeps what it loaded here: association and parent_of answer
      # from it without a query.
      def cache_children(name, relation)
        @loaded_children[name] = relation
      end

      def cache_parent(name, record)
        @loaded_parents[name] = record
      end

      def association(name)
        return @loaded_children[name] if @loaded_children.key?(name)
        cfg = nil
        self.class.has_manys.each { |h| cfg = h if h.name == name }
        raise ArgumentError, "no has_many #{name}" if cfg.nil?
        fk = cfg.foreign_key.nil? ? "#{Edgeway::Model.underscore(self.class.name.split("::").last)}_id" : cfg.foreign_key
        pk = self.class.column(cfg.primary_key.nil? ? "id" : cfg.primary_key)
        Edgeway::Model::Base.model_named(name, self.class.name).where(fk => @attributes[pk])
      end

      def parent_of(name)
        return @loaded_parents[name] if @loaded_parents.key?(name)
        cfg = nil
        self.class.belongs_to_list.each { |b| cfg = b if b.name == name }
        raise ArgumentError, "no belongs_to #{name}" if cfg.nil?
        parent = Edgeway::Model::Base.model_named(name, self.class.name)
        key = @attributes[cfg.foreign_key]
        return parent.find(key) if cfg.primary_key == "id"
        found = key.nil? ? nil : parent.find_by(cfg.primary_key => key)
        raise RecordNotFound, "#{parent.table_name} #{cfg.primary_key} #{key} not found" if found.nil?
        found
      end

      private

      def delete_row
        conn = Model.connection
        Model.write("DELETE FROM #{self.class.table_name} WHERE id = #{conn.placeholder(1)}", [id])
      end

      def update_row
        conn = Model.connection
        cols = self.class.attribute_types.keys
        values = cols.map { |c| Model.to_db(@attributes[c]) }
        sets = cols.each_with_index.map { |c, i| "#{c} = #{conn.placeholder(i + 1)}" }.join(", ")
        Model.write("UPDATE #{self.class.table_name} SET #{sets} WHERE id = #{conn.placeholder(cols.size + 1)}",
                     values + [id])
      end

      def insert_row
        raise ArgumentError, "create isn't supported inside Model.batch" if Model.batching?
        conn = Model.connection
        table = self.class.table_name
        cols = self.class.attribute_types.keys.reject { |c| @attributes[c].nil? }
        values = cols.map { |c| Model.to_db(@attributes[c]) }
        sql = "INSERT INTO #{table}"
        if cols.empty?
          sql += " DEFAULT VALUES"
        else
          marks = cols.each_with_index.map { |_c, i| conn.placeholder(i + 1) }
          sql += " (#{cols.join(", ")}) VALUES (#{marks.join(", ")})"
        end
        if conn.supports_returning?
          load_row(conn.insert_returning(sql + " RETURNING #{self.class.columns.join(", ")}", values))
        else
          new_id = conn.execute(sql, values)["last_insert_id"]
          load_row(conn.select_all("SELECT #{self.class.columns.join(", ")} FROM #{table} WHERE id = #{conn.placeholder(1)}", [new_id])[0])
        end
      end

      def touch(creating)
        types = self.class.attribute_types
        now = Model.now
        write_attribute("created_at", now) if creating && types.key?("created_at")
        write_attribute("updated_at", now) if types.key?("updated_at")
      end
    end
  end
end
