require 'jsonapi_compliable/adapters/mongoid_sideloading'

module JsonapiCompliable
  module Adapters
    # Mongoid transactionless adapter
    # See https://github.com/jsonapi-suite/jsonapi_compliable/blob/master/lib/jsonapi_compliable/adapters/abstract.rb
    #
    # @author [Cyril]
    #
    class MongoidAdapter < JsonapiCompliable::Adapters::Abstract
      def sideloading_module
        JsonapiCompliable::Adapters::MongoidSideloading
      end

      # @override
      # If we keep the default behavior, this returns a criteria
      # and will mess up sideloading scopes
      # jsonapi_suite resolve is meant to evaluate and not lazy-evaluate
      def resolve(scope)
        scope.to_a
      end

      def filter(scope, attribute, value)
        scope.where(attribute => value)
      end

      # @Override using Mongoid's #asc and #desc
      def order(scope, attribute, direction)
        scope.public_send(direction, attribute)
      end

      # @Override
      def paginate(scope, current_page, per_page)
        scope.page(current_page).per(per_page)
      end

      # @Override
      def count(scope, _attr)
        scope.count
      end

      # @Override
      # No transaction mechanism in Mongoid :'('
      def transaction(_model_class)
        yield
      end

      # @Override
      def update(model_class, update_params)
        instance = model_class.find(update_params.delete(:id))
        instance.update_attributes(update_params)
        instance
      end

      # @Override
      def associate(parent, child, association_name, association_type)
        case association_type
        when :has_many
          parent.send(association_name).push(child)
        when :belongs_to
          child.send(:"#{association_name}=", parent)
        when :habtm
          # No such thing as child <-> parent in HABTM anyway
          #
          # For some reason `child.send(association_name)`
          #   is a Mongoid::Relations::Targets::Enumerable
          #   and seems to behave like a belongs_to/has
          # child.send(association_name) << parent
        when :embeds_one, :embeds_many
          # Nested models are already associated :-)
        else
          raise "Define how to associate parent and child for #{association_type}!"
        end
      end
    end
  end
end
