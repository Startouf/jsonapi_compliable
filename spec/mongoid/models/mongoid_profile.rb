class MongoidProfile
  include Mongoid::Document

  has_and_belongs_to_many :tags, inverse_of: nil
end
