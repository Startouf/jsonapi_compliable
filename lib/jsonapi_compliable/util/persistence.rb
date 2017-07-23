# Save the given Resource#model, and all of its nested relationships.
# @api private
class JsonapiCompliable::Util::Persistence
  # @param [Resource] resource the resource instance
  # @param [Hash] meta see (Deserializer#meta)
  # @param [Hash] attributes see (Deserializer#attributes)
  # @param [Hash] relationships see (Deserializer#relationships)
  # @param [Hash] relationships see (Deserializer#relationships)
  # @param parent_object : nil [Class] optional parent object for the nested relationship
  def initialize(resource, meta, attributes, relationships, parent_object: nil)
    @resource      = resource
    @meta          = meta
    @attributes    = attributes
    @relationships = relationships
    @parent_object = parent_object
  end

  # Perform the actual save logic.
  #
  # belongs_to must be processed before/separately from has_many -
  # we need to know the primary key value of the parent before
  # persisting the child.
  #
  # Flow:
  # * process parents
  # * update attributes to reflect parent primary keys
  # * persist current object
  # * associate temp id with current object
  # * associate parent objects with current object
  # * process children
  # * associate children
  # * return current object
  #
  # @return the persisted model instance
  def run
    parents = process_belongs_to(@relationships)
    update_foreign_key_for_parents(parents)

    persisted = persist_object(@meta[:method], @attributes)
    assign_temp_id(persisted, @meta[:temp_id])
    associate_parents(persisted, parents)

    children = process_has_many(@relationships) do |x|
      if x[:sideload].type.in?([:embeds_many, :embeds_one])
        x[:parent_object] = persisted
      else
        update_foreign_key(persisted, x[:attributes], x)
      end
    end

    associate_children(persisted, children)
    persisted unless @meta[:method] == :destroy
  end

  private

  # The child's attributes should be modified to nil-out the
  # foreign_key when the parent is being destroyed or disassociated
  def update_foreign_key(parent_object, attrs, x)
    if [:destroy, :disassociate].include?(x[:meta][:method])
      attrs[x[:foreign_key]] = nil
      update_foreign_type(attrs, x, null: true) if x[:is_polymorphic]
    elsif x[:sideload].type == :habtm
      (attrs[x[:foreign_key]] ||= []) << parent_object.send(x[:primary_key]).to_s
      update_foreign_type(attrs, x) if x[:is_polymorphic]
    else
      attrs[x[:foreign_key]] = parent_object.send(x[:primary_key])
      update_foreign_type(attrs, x) if x[:is_polymorphic]
    end
  end

  def update_foreign_type(attrs, x, null: false)
    grouping_field = x[:sideload].parent.grouping_field
    attrs[grouping_field] = null ? nil : x[:sideload].name
  end

  def update_foreign_key_for_parents(parents)
    parents.each do |x|
      update_foreign_key(x[:object], @attributes, x)
    end
  end

  def associate_parents(object, parents)
    parents.each do |x|
      x[:sideload].associate(x[:object], object) if x[:object] && object
    end
  end

  def associate_children(object, children)
    children.each do |x|
      x[:sideload].associate(object, x[:object]) if x[:object] && object
    end
  end

  def persist_object(method, attributes)
    if parent_object.present?
      return persist_embedded_object(method, attributes, parent_object)
    end
    case method
      when :destroy
        @resource.destroy(attributes[:id])
      when :disassociate, nil
        @resource.update(attributes)
      else
        @resource.send(method, attributes)
    end
  end

  # Forwards persistence arguments for nested relations
  # @param method [Symbol]
  # @param attributes [ActionController::Parameter]
  # @param parent_object [Class]
  #
  # @return [void]
  def persist_embedded_object(method, attributes, parent_object)
    case method
    when :destroy
      @resource.destroy(attributes[:id], parent_object)
    when :disassociate, nil
      @resource.update(attributes, parent_object)
    else
      @resource.send(method, attributes, parent_object)
    end
  end

  def process_has_many(relationships)
    [].tap do |processed|
      iterate(except: [:polymorphic_belongs_to, :belongs_to]) do |x|
        yield x
        x[:object] = x[:sideload].resource
          .persist_with_relationships(x[:meta], x[:attributes], x[:relationships],
            parent_object: x[:parent_object])
        processed << x
      end
    end
  end

  def process_belongs_to(relationships)
    [].tap do |processed|
      iterate(only: [:polymorphic_belongs_to, :belongs_to]) do |x|
        x[:object] = x[:sideload].resource
          .persist_with_relationships(x[:meta], x[:attributes], x[:relationships])
        processed << x
      end
    end
  end

  def assign_temp_id(object, temp_id)
    object.instance_variable_set(:@_jsonapi_temp_id, temp_id)
  end

  def iterate(only: [], except: [])
    opts = {
      resource: @resource,
      relationships: @relationships,
    }.merge(only: only, except: except)

    JsonapiCompliable::Util::RelationshipPayload.iterate(opts) do |x|
      yield x
    end
  end
end
