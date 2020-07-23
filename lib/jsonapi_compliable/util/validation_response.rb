# We need to know two things in the response of a persistence call:
#
#   * The model we just tried to persist
#   * Was the persistence successful?
#
# This object wraps those bits of data. The call is considered
# unsuccessful when it adheres to the ActiveModel#errors interface,
# and #errors is not blank. In other words, it is not successful if
# there were validation errors.
#
# @attr_reader object the object we are saving
class JsonapiCompliable::Util::ValidationResponse
  attr_reader :object

  # @param object the model instance we tried to save
  # @param deserialized_params see Base#deserialized_params
  def initialize(object, deserialized_params)
    @object = object
    @deserialized_params = deserialized_params
  end

  # Check to ensure no validation errors.
  # @return [Boolean] did the persistence call succeed?
  def success?
    all_valid?(object, @deserialized_params.relationships)
  end

  # @return [Array] the object and success state
  def to_a
    [object, success?]
  end

  def validate!
    unless success?
      raise ::JsonapiCompliable::Errors::ValidationError.new(self)
    end
    self
  end

  private

  def valid_object?(object)
    !object.respond_to?(:errors) ||
      (object.respond_to?(:errors) && object.errors.blank?)
  end

  def all_valid?(model, deserialized_params)
    checks = []
    checks << valid_object?(model)
    deserialized_params.each_pair do |name, payload|
      if payload.is_a?(Array)
        related_objects = model.send(name)

        payload_with_id, other = payload.partition { |h| get_id_from_payload(h) }
        payload_with_temp_id, unknown = other.partition { |h| h.with_indifferent_access.dig(:meta, :temp_id).present? }
        raise "Resources not identified by id or temp_id" if  unknown.any?

        check_items_with_id(payload_with_id, related_objects, checks)
        check_items_with_temp_id(payload_with_temp_id, related_objects, checks)
      else
        # Do not forget to handle destroy disassociate
        next if model.nil? && %i[destroy disassociate].include?(payload.dig(:meta, :method))

        related_object = model.send(name)
        valid = valid_object?(related_object)
        checks << valid
        if valid
          checks << all_valid?(related_object, payload[:relationships] || {})
        end
      end
    end
    checks.all? { |c| c == true }
  end

  # @param payload [Array] incoming modifications
  # @param related_objects [?] list of items being modified
  # @param checks [Array] list of checks
  #
  # @return [void]
  def check_items_with_id(payload, related_objects, checks)
    payload.each do |payload_item_with_id|
      related_object = related_objects.detect do |o|
        o.id.to_s == get_id_from_payload(payload_item_with_id)
      end
      # Do not forget to handle destroy disassociate
      if !related_object && !%i[destroy disassociate].include?(payload_item_with_id.dig(:meta, :method))
        raise ::JsonapiCompliable::Errors::ValidationError.new(self), 'could not match incoming item with ID to its related object'
      end

      valid = valid_object?(related_object)
      checks << valid
      if valid
        checks << all_valid?(related_object, payload_item_with_id[:relationships] || {})
      end
    end.compact
  end

  # @param payload [Array] incoming modifications
  # @param related_objects [?] list of items being modified,
  # @param checks [Array] list of checks
  #
  # @return [void]
  def check_items_with_temp_id(payload, related_objects, checks)
    payload.each do |payload_item_with_temp_id|
      related_object = related_objects.detect do |obj|
        obj.instance_variable_get(:@_jsonapi_temp_id) == payload_item_with_temp_id.dig(:meta, :temp_id)
      end
      if !related_object
        raise ::JsonapiCompliable::Errors::ValidationError.new(self), 'could not match incoming item with temp-id to its related object'
      end
      valid = valid_object?(related_object)
      checks << valid
      if valid
        checks << all_valid?(related_object, payload_item_with_temp_id[:relationships] || {})
      end
    end
  end

  def get_id_from_payload(payload)
    payload.dig(:attributes, 'id') || payload.dig(:attributes, :id)
  end
end
