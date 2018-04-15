class MongoidTagResource < JsonapiCompliable::Resource
  model MongoidTag
  use_adapter JsonapiCompliable::Adapters::MongoidAdapter
end
