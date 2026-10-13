# The UNIQUE (name) of the table is all that keeps names apart, so a second
# create answers 409 (RecordNotUnique); `validates :name, uniqueness: true`
# would make it a 422 with a message instead.
class Tag < ApplicationModel
  attribute :name, :string
  validates :name, presence: true
end
