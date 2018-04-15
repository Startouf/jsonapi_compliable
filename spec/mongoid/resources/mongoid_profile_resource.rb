require_relative 'mongoid_tag_resource'

class MongoidProfileResource < JsonapiCompliable::Resource
  model MongoidProfile
  use_adapter JsonapiCompliable::Adapters::MongoidAdapter

  has_and_belongs_to_many :tags, resource: MongoidTagResource
end