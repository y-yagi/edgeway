class Comment < ApplicationModel
  attribute :body, :string
  belongs_to :todo
  timestamps
  validates :body, presence: true, length: { maximum: 1000 }
end
