module Edgeway
  module Model
    # A model class's metadata in one object. Spinel widens the class instance
    # variables that inherited class methods read to untyped, while the fields of
    # a plain object stay typed. An empty table_name stands for none, as nil
    # would make it a nullable String.
    class Schema
      attr_accessor :id_type, :table_name, :database
      attr_reader :belongs_tos, :rules, :has_manys

      def initialize
        @id_type = :integer
        @table_name = ""
        @database = nil
        @column_types = {}
        @column_names = []
        @attribute_defaults = {}
        @default_columns = []
        @belongs_tos = []
        @kept_types = {}
        @rules = []
        @has_manys = []
      end

      def declare(column, type)
        @column_names << column unless @column_types.key?(column)
        @column_types[column] = type
      end

      def declare_default(column, value)
        @default_columns << column unless @attribute_defaults.key?(column)
        @attribute_defaults[column] = value
      end

      def each_default
        @default_columns.each { |column| yield column, @attribute_defaults[column] }
      end

      def declared?(column) = @column_types.key?(column)

      def attribute_names = @column_names

      def type_of(column) = @column_types[column]

      def keep_type(column)
        @kept_types[column] = @column_types[column] if @column_types.key?(column)
      end

      def restore_type(column)
        @column_types[column] = @kept_types[column] if @kept_types.key?(column)
      end
    end
  end
end
