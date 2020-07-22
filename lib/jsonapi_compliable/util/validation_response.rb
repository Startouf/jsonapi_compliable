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

        # First match payload with id to their corresponding item
        related_objects_with_existing_ids = check_items_with_ids(payload, related_objects, checks)

        remaining_related_objects = (related_objects - related_objects_with_existing_ids)
        # Then match new items assuming the temp-id objects were created in chronological order
        # (if #created_at is available on the objects only)
        check_items_with_temp_id(payload, remaining_related_objects, checks)
      else
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
  # @return [Array<?>] array of related objects that were found by ID
  def check_items_with_ids(payload, related_objects, checks)
    payload_items_with_id = payload.select { |h| h.dig('id').present? }


    payload_items_with_id.map do |payload_item_with_id|
      related_object = related_objects.detect do |o|
        o.id.to_s == payload_item_with_id.dig('id')
      end
      if !related_object
        raise ::JsonapiCompliable::Errors::ValidationError.new(self), 'could not match incoming item with ID to its related object'
      end

      related_objects_with_existing_ids << related_object
      valid = valid_object?(r)
      checks << valid
      if valid
        checks << all_valid?(r, payload[index][:relationships] || {})
      end
      related_object
    end.compact
  end

  # @param payload [Array] incoming modifications
  # @param related_objects [?] list of items being modified,
  #   should exclude objects already matched by ID
  # @param checks [Array] list of checks
  #
  # @return [Array<?>] array of related objects that were found by ID
  def check_items_with_temp_id(payload, related_objects, checks)
    sorted_related_objects = if related_objects.all? { |o| o.respond_to?(:created_at) }
      related_objects.sort_by!(&:created_at)
    else
      related_objects
    end

    payload_items_sorted_by_temp_id = payload.select { |h| h.dig('temp_id').present? }.sort_by { |h| h.dig('temp_id') }
    payload_items_sorted_by_temp_id.each do |payload_item_with_temp_id|
      if sorted_related_objects.any?
        related_object = remaining_related_objects.shift
        valid = valid_object?(r)
        checks << valid
        if valid
          checks << all_valid?(r, payload[index][:relationships] || {})
        end
      else
        raise ::JsonapiCompliable::Errors::ValidationError.new(self), 'could not match incoming item with temp-id to its related object'
      end
    end
  end
end
