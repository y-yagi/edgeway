module Edgeway
  module Model
    module Macros
      def attribute(name, type, default: nil)
        attribute_types[name.to_s] = type
        attribute_defaults[name.to_s] = default unless default.nil?
        define_method(name) { @attributes[name.to_s] }
        define_method("#{name}=") { |v| write_attribute(name.to_s, v) }
      end

      def timestamps
        attribute :created_at, :datetime
        attribute :updated_at, :datetime
      end

      # dependent: :destroy destroys the children (their own dependents run
      # too), :delete_all deletes them with one DELETE. foreign_key: is the
      # children's column and primary_key: ours (a String foreign key is
      # declared with attribute on the child, as for belongs_to). An unset
      # foreign_key stays nil: association works out "<model>_id" per call.
      def has_many(name, dependent: nil, foreign_key: nil, primary_key: nil)
        mode = nil
        unless dependent.nil?
          mode = dependent.to_s
          raise ArgumentError, "unknown dependent: #{dependent}" unless mode == "destroy" || mode == "delete_all"
        end
        fk = foreign_key.nil? ? nil : foreign_key.to_s
        pk = primary_key.nil? ? nil : primary_key.to_s
        has_manys << Edgeway::Model::HasMany.new(name.to_s, fk, pk, mode)
        define_method(name) do
          association(name.to_s)
        end
      end

      # foreign_key: is our column ("<name>_id" by default), primary_key: the
      # parent's ("id"). A foreign key that is already declared keeps its type,
      # which is how a String one is made: attribute :owner_uid, :string first.
      # attribute is called either way (Spinel needs a macro call to be
      # unconditional, and a macro body can't read attribute_types into a
      # local), so keep_type/restore_type put the declared type back.
      def belongs_to(name, foreign_key: nil, primary_key: nil)
        fk = foreign_key.nil? ? "#{name}_id" : foreign_key.to_s
        pk = primary_key.nil? ? "id" : primary_key.to_s
        keep_type(fk)
        if foreign_key.nil?
          attribute "#{name}_id", :integer
        else
          attribute foreign_key, :integer
        end
        restore_type(fk)
        belongs_to_list << Edgeway::Model::BelongsTo.new(name.to_s, fk, pk)
        define_method(name) do
          parent_of(name.to_s)
        end
      end
    end
  end
end
