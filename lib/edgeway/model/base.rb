module Edgeway
  module Model
    # A model: its declarations (attributes, validations, associations), its
    # queries and its attribute values. Writing the row is in Persistence and
    # valid? in Validations.
    #
    # The class methods are all defined here, not in an extended module:
    # Spinel binds self in a method of a module extended into Base to Base,
    # not to the subclass it is called on (Todo.all would query "bases").
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

      # The model of that full name, or nil when there is no such constant or
      # it is not a model.
      def self.model_class(full_name)
        klass = nil
        begin
          klass = Object.const_get(full_name)
        rescue NameError
          return nil
        end
        klass.is_a?(Class) && klass < Base ? klass : nil
      end

      # ---- Declarations ----

      def self.table_name=(name)
        @table_name = name
      end

      def self.table_name
        @table_name || Inflector.pluralize(Model.underscore(name.split("::").last))
      end

      def self.attribute_types = (@attribute_types ||= {})
      def self.attribute_defaults = (@attribute_defaults ||= {})
      def self.belongs_to_list = (@belongs_to ||= [])
      # belongs_to declares its foreign key with attribute, which sets :integer;
      # these two put back the type of a column declared before it. They are
      # methods because a macro body can't read attribute_types into a local.
      def self.keep_type(col)
        @kept_types ||= {}
        @kept_types[col] = attribute_types[col] if attribute_types.key?(col)
      end

      def self.restore_type(col)
        @kept_types ||= {}
        attribute_types[col] = @kept_types[col] if @kept_types.key?(col)
      end

      def self.rules = (@rules ||= [])
      def self.has_manys = (@has_manys ||= [])

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
        col = name.to_s
        raise UnknownColumn, "unknown column: #{col}" unless col == "id" || attribute_types.key?(col)
        col
      end

      def self.columns
        ["id"] + attribute_types.keys
      end

      def self.type_of(col)
        col == "id" ? :integer : attribute_types[col]
      end

      # ---- Queries ----

      def self.all = Relation.new(self)
      def self.where(conditions) = all.where(conditions)
      def self.order(col, dir = :asc) = all.order(col, dir)
      def self.reorder(col, dir = :asc) = all.reorder(col, dir)
      def self.delete_all = all.delete_all
      def self.destroy_all = all.destroy_all
      def self.limit(n) = all.limit(n)
      def self.offset(n) = all.offset(n)
      def self.count = all.count
      def self.exists?(conditions = {}) = all.where(conditions).exists?
      def self.pluck(col) = all.pluck(col)
      def self.first = all.first
      def self.find_by(conditions) = all.find_by(conditions)
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

      # A record from a row the database answered.
      def self.instantiate(row)
        record = new({})
        record.load_row(row)
        record
      end

      # ---- A record ----

      def initialize(attrs = {})
        @attributes = {}
        # The values as they were set, before the cast ("abc" for an integer
        # attribute): what numericality checks, as Rails'
        # attribute_before_type_cast.
        @raw = {}
        @errors = []
        @persisted = false
        self.class.attribute_defaults.each { |k, v| write_attribute(k, v) }
        assign(attrs)
      end

      def id = @attributes["id"]
      def persisted? = @persisted
      def new_record? = !@persisted

      # Sets the declared attributes in attrs (a Hash with String or Symbol
      # keys, or permitted Parameters); other keys, "id" among them, are
      # ignored. Parameters that were not permitted raise ForbiddenAttributes.
      def assign(attrs)
        if attrs.is_a?(HTTP::Parameters)
          raise ForbiddenAttributes, "#{self.class.name}: params must go through permit" unless attrs.permitted?
          values = attrs.to_h
        else
          values = attrs
        end
        types = self.class.attribute_types
        values.each do |k, v|
          key = k.to_s
          write_attribute(key, v) if types.key?(key)
        end
      end

      def load_row(row)
        self.class.columns.each { |col| @attributes[col] = Model.cast(self.class.type_of(col), row[col]) }
        @raw = {}
        @persisted = true
      end

      # Sets an attribute (a declared one, or "id") as its type, skipping
      # assign's filter: a Relation's conditions use it for the records it
      # makes.
      def write_attribute(col, v)
        @raw[col] = v
        @attributes[col] = Model.cast(self.class.type_of(col), v)
      end

      def as_json
        h = {}
        self.class.columns.each { |col| h[col] = @attributes[col] }
        h
      end
    end
  end
end
