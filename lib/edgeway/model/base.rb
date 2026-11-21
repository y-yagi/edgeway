module Edgeway
  module Model
    class Base
      include Persistence
      include Validations

      # The model an association name ("comments", "todo") stands for. owner is
      # the full name of the model that declares it: the namespaces around the
      # owner are tried first, innermost out ("Admin::Comment" for an
      # Admin::Post), then the top level.
      def self.model_named(name, owner = "")
        base = Inflector.singularize(name).split("_").map(&:capitalize).join
        scope = owner.split("::")
        scope.pop
        klass = nil
        until klass || scope.empty?
          klass = model_class((scope + [base]).join("::"))
          scope.pop
        end
        klass ||= model_class(base)
        raise ArgumentError, "no model for #{name}" if klass.nil?
        klass
      end

      def self.model_class(full_name)
        klass = nil
        begin
          klass = Object.const_get(full_name)
        rescue NameError
          return nil
        end
        klass.is_a?(Class) && klass < Base ? klass : nil
      end

      def self.schema = (@schema ||= Schema.new)

      def self.table_name=(name)
        schema.table_name = name.to_s
      end

      def self.table_name
        custom = schema.table_name
        custom.empty? ? Inflector.pluralize(Model.underscore(name.split("::").last)) : custom
      end

      def self.database=(name)
        raise ArgumentError, "database name can't be blank" if name.nil? || name.to_s.empty?
        schema.database = name.to_s
      end

      def self.own_database = schema.database

      def self.database
        klass = self
        while klass
          name = klass.own_database
          return name unless name.nil?
          break if klass == Base
          klass = klass.superclass
        end
        Model::PRIMARY
      end

      def self.connection = Model.connection_for(database)

      def self.declare_attribute(column, type) = schema.declare(column, type)
      def self.attribute?(column) = schema.declared?(column)
      def self.attribute_names = schema.attribute_names
      def self.declare_default(column, value) = schema.declare_default(column, value)
      def self.belongs_to_list = schema.belongs_tos
      def self.keep_type(column) = schema.keep_type(column)
      def self.restore_type(column) = schema.restore_type(column)
      def self.rules = schema.rules
      def self.has_manys = schema.has_manys

      # The has_manys with a dependent: option.
      def self.dependents = has_manys.reject { |h| h.mode.nil? }

      def self.validates(*names, presence: false, length: nil, inclusion: nil, numericality: nil, format: nil, uniqueness: nil)
        names.each do |n|
          attr = n.to_s
          rules << Rule.new(attr, "presence", {}, [], nil) if presence
          rules << Rule.new(attr, "length", Rule.bounds(length), [], nil) unless length.nil?
          rules << Rule.new(attr, "inclusion", {}, inclusion[:in].map(&:to_s), nil) unless inclusion.nil?
          rules << Rule.new(attr, "numericality", Rule.bounds(numericality), [], nil) unless numericality.nil?
          rules << Rule.new(attr, "format", {}, [], format[:with]) unless format.nil?
          # The scope columns are in the list slot.
          rules << Rule.new(attr, "uniqueness", {}, Rule.scope_columns(uniqueness), nil) unless uniqueness.nil? || uniqueness == false
        end
      end

      def self.column(name)
        column = name.to_s
        raise UnknownColumn, "unknown column: #{column}" unless column == "id" || attribute?(column)
        column
      end

      def self.columns = schema.columns

      def self.id_type = schema.id_type

      def self.id_type=(type)
        schema.id_type = type
      end

      def self.type_of(column)
        column == "id" ? id_type : schema.type_of(column)
      end

      def self.all = Relation.new(self)
      def self.where(conditions, *args) = all.where(conditions, *args)
      def self.order(col, dir = :asc) = all.order(col, dir)
      def self.reorder(col, dir = :asc) = all.reorder(col, dir)
      def self.delete_all = all.delete_all
      def self.destroy_all = all.destroy_all
      def self.eager_load(*names) = all.eager_load(*names)
      def self.limit(n) = all.limit(n)
      def self.offset(n) = all.offset(n)
      def self.count = all.count
      def self.exists?(conditions = {}) = all.where(conditions).exists?
      def self.pluck(col) = all.pluck(col)
      def self.first = all.first
      def self.find_by(conditions) = all.find_by(conditions)
      def self.find_by_sql(sql, binds = []) = Model.select_all(sql, binds, database: database).map { |row| instantiate(row) }
      def self.find(id) = all.find(id)

      def self.find_or_create_by(conditions) = all.find_or_create_by(conditions)
      def self.find_or_create_by!(conditions) = all.find_or_create_by!(conditions)

      def self.create(attrs = {})
        record = new(attrs)
        record.save
        record
      end

      def self.create!(attrs = {})
        record = new(attrs)
        record.save!
        record
      end

      def self.instantiate(row)
        record = new({})
        record.load_row(row)
        record
      end

      def initialize(attrs = {})
        @attributes = {}
        @raw = {}
        @errors = []
        @persisted = false
        @loaded_children = {}
        @loaded_parents = {}
        self.class.schema.each_default { |column, value| write_attribute(column, value) }
        assign(attrs)
      end

      def id = @attributes["id"]
      def persisted? = @persisted
      def new_record? = !@persisted

      def assign(attrs)
        if attrs.is_a?(HTTP::Parameters)
          raise ForbiddenAttributes, "#{self.class.name}: params must go through permit" unless attrs.permitted?
          values = attrs.to_h
        else
          values = attrs
        end
        values.each do |k, v|
          key = k.to_s
          write_attribute(key, param_value(self.class.type_of(key), v, attrs)) if self.class.attribute?(key)
        end
      end

      def param_value(type, value, attrs)
        return value unless type == :binary && attrs.is_a?(HTTP::Parameters) && value.is_a?(String)
        { "$blob" => value }
      end

      def load_row(row)
        @raw = {}
        self.class.columns.each { |column| load_column(column, row[column]) }
        @persisted = true
      end

      def load_column(column, value)
        casted = Model.cast(self.class.type_of(column), value)
        @attributes[column] = casted
        @raw[column] = value if casted.nil? && !value.nil?
      end

      def write_attribute(col, v)
        @raw[col] = v
        @attributes[col] = Model.cast(self.class.type_of(col), v)
      end

      def as_json
        h = {}
        self.class.columns.each { |column| h[column] = json_value(column) }
        h
      end

      private

      def json_value(column)
        value = @attributes[column]
        return value unless self.class.type_of(column) == :binary && !value.nil?
        Model.encode_base64(value)
      end
    end
  end
end
