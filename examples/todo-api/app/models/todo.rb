class Todo < ApplicationModel
  attribute :title, :string
  attribute :done, :boolean, default: false
  attribute :priority, :string, default: "normal"
  timestamps
  has_many :comments, dependent: :destroy  # destroyed with the todo (the table also has ON DELETE CASCADE)
  validates :title, presence: true, length: { maximum: 200 }
  validates :priority, inclusion: { in: ["low", "normal", "high"] }
end
