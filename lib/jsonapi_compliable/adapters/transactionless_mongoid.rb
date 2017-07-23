module JsonapiCompliable
  module Adapters
    # Mongoid transactionless adapter
    #
    # @author [Startouf]
    #
    class TransactionlessMongoid < JsonapiCompliable::Adapters::Abstract
      def sideloading_module
        Jsonapi::Adapters::MongoidSideloading
      end

      def filter(scope, attribute, value)
        scope.where(attribute => value)
      end

      # @Override to use Mongoid's #asc and #desc
      def order(scope, attribute, direction)
        if direction == :asc
          scope.asc(attribute)
        else
          scope.desc(attribute)
        end
      end

      # @Override Mongoid Criteria supports #page and #per
      def paginate(scope, current_page, per_page)
        scope.page(current_page).per(per_page)
      end

      # @Override
      def count(scope, attr)
        scope.count
      end

      # @Override
      # No easy transaction mechanism in Mongoid :'(
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
        when :has_many, :habtm
          # TODO: Check Mongoid's HABTM can indeed be reduced to :has_many
          parent.send(association_name).push(child)
        when :belongs_to
          child.send(:"#{association_name}=", parent)
        else
          raise 'Define how to associate parent and child !'
        end
      end
    end
  end
end
