require "edgeway"
require "edgeway/db/memory"

class ApplicationModel < Edgeway::Model::Base
  extend Edgeway::Model::Macros
end

class Todo < ApplicationModel
  attribute :title, :string
  attribute :done, :boolean, default: false
  attribute :priority, :string, default: "normal"
  attribute :position, :integer
  timestamps
  has_many :comments
  validates :title, presence: true, length: { maximum: 10 }
  validates :priority, inclusion: { in: ["low", "normal", "high"] }
  validates :position, numericality: { only_integer: true }
end

class Comment < ApplicationModel
  attribute :body, :string
  belongs_to :todo
  validates :body, presence: true
end

class Attachment < ApplicationModel
  attribute :name, :string
  attribute :data, :binary
end

class Ledger < ApplicationModel
  attribute :id, :bigint
  attribute :total, :bigint
end

db = Edgeway::DB::MemoryAdapter.new
Edgeway::Model.connection = db
Edgeway::Model.freeze_time("2026-01-02T03:04:05.000Z")

def show(db)
  puts db.log
  db.log.clear
end

# a persisted Todo that the multiple-database checks below reuse
db.queue([{ "id" => 1, "title" => "p", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
bt = Todo.find(1)
db.log.clear

# Model.now without a frozen time: UTC, always three digits of milliseconds
# (so the strings sort in time order).
Edgeway::Model.freeze_time(nil)
puts Edgeway::Model.now.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/)

puts JSON.generate(Edgeway::Model.query_stats.log_fields)
puts Edgeway::Model.query_stats.queries
stats_db = Edgeway::DB::MemoryAdapter.new
stats_db.record_meta(JSON.parse('{"rows_read":3,"rows_written":1,"duration":2,"served_by_region":"WEUR","served_by_primary":false}'))
stats_db.record_meta(JSON.parse('{"rows_read":4,"rows_written":0,"duration":0.456,"served_by_region":"ENAM","served_by_primary":true}'))
stats = stats_db.query_stats
puts [stats.queries, stats.rows_read, stats.rows_written, stats.duration_ms, stats.served_by_region, stats.served_by_primary].inspect
puts JSON.generate(stats.log_fields)
stats_db.record_meta(JSON.parse('{"rows_read":0,"rows_written":0,"duration":0.5}'))
puts [stats_db.query_stats.queries, stats_db.query_stats.served_by_region, stats_db.query_stats.served_by_primary].inspect
batch_db = Edgeway::DB::MemoryAdapter.new
batch_db.record_meta(JSON.parse('{"rows_read":30,"rows_written":3,"duration":1.5,"served_by_region":"","served_by_primary":true}'))
puts JSON.generate(batch_db.query_stats.log_fields)
big_db = Edgeway::DB::MemoryAdapter.new
big_db.record_meta(JSON.parse('{"rows_read":2147483647,"rows_written":5,"duration":1}'))
big_db.record_meta(JSON.parse('{"rows_read":10,"rows_written":5,"duration":1}'))
puts JSON.generate(big_db.query_stats.log_fields)

# binary and bigint
raw = [0, 1, 255, 0, 128].pack("C*")
puts Edgeway::Model.cast(:binary, raw).bytes.inspect
puts Edgeway::Model.cast(:binary, {"$blob" => "AAH/AIA="}).bytes.inspect
puts Edgeway::Model.cast(:binary, {"$blob" => ""}).bytesize
puts Edgeway::Model.cast(:binary, {"other" => 1}).inspect
puts Edgeway::Model.cast(:binary, {"$blob" => "!!"}).inspect
puts Edgeway::Model.cast(:binary, nil).inspect
puts Edgeway::Model.blob(raw).inspect
puts Edgeway::Model.database_value(raw, :binary).inspect
puts Edgeway::Model.database_value(raw).bytes.inspect
puts Edgeway::Model.database_value(nil, :binary).inspect
puts ["3000000000", 3000000000, "-5", 7, "", "1.5", "12a", " 1", 1.5, true].map { |v| Edgeway::Model.cast(:bigint, v).inspect }.join(" ")
puts Edgeway::Model.database_value("3000000000", :bigint).inspect

db.log.clear
attachment = Attachment.new(name: "a", data: raw)
puts attachment.data.bytes.inspect
puts attachment.as_json.inspect
db.queue([{ "id" => 1, "name" => "a", "data" => {"$blob" => "AAH/AIA="} }])
attachment.save
puts db.log.last
puts attachment.data.bytes.inspect
db.queue([{ "id" => 1, "name" => "a", "data" => {"$blob" => "AAH/AIA="} }])
puts Attachment.where(data: raw).first.as_json.inspect
puts db.log.last
attachment.data = "x"
attachment.save
puts db.log.last

db.log.clear
db.queue([{ "id" => 3000000000, "total" => 9007199254740991 }])
ledger = Ledger.find("3000000000")
puts db.log.last
puts ledger.id.inspect
puts ledger.total.inspect
puts ledger.as_json.inspect
ledger.total = 12
ledger.save
puts db.log.last
ledger.destroy
puts db.log.last
puts Ledger.new(total: "12x").total.inspect

puts [5, 2147483647, 2147483648, -2147483648, -2147483649, 9007199254740991, nil].map { |v| db.last_insert_id_of(v).inspect }.join(" ")
puts db.last_insert_id_of(JSON.parse('{"id":3000000000}')["id"]).inspect

# request params carry a binary attribute as base64
params = Edgeway::HTTP::Parameters.new({ "name" => "p", "data" => "AAH/AIA=" }, true)
puts Attachment.new(params).data.bytes.inspect
puts Attachment.new(Edgeway::HTTP::Parameters.new({ "data" => "" }, true)).data.bytesize
bad = Attachment.new(Edgeway::HTTP::Parameters.new({ "data" => "!!" }, true))
puts bad.data.inspect
puts bad.valid?
puts bad.errors.inspect
puts Attachment.new(data: "AAH/").data.bytes.inspect

puts ["007", "-0", "-007", "0", "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "00000000000000000000001"].map { |v| Edgeway::Model.cast(:bigint, v).inspect }.join(" ")
ledger = Ledger.new(total: "12x")
puts ledger.valid?
puts ledger.errors.inspect

class Sized < ApplicationModel
  attribute :data, :binary
  validates :data, presence: true, length: { maximum: 3 }
end
puts Sized.new(data: [0, 0].pack("C*")).valid?
["", "abcd"].each do |data|
  sized = Sized.new(data: data)
  sized.valid?
  puts sized.errors.inspect
end

# a stored value an :integer can't hold is kept, so a save is refused
class Reference < ApplicationModel
  attribute :ticket_id, :integer
  attribute :note, :string
end
db.queue([{ "id" => 1, "ticket_id" => 5000000000, "note" => "a" }])
reference = Reference.first
puts reference.ticket_id.inspect
puts reference.update(note: "b")
puts reference.errors.inspect

class Event < ApplicationModel
  self.database = :analytics
  attribute :name, :string
end

class Impression < ApplicationModel
  self.database = :analytics
  attribute :note, :string
  belongs_to :todo
end

class ClickEvent < Event
end

puts [Todo.database, Event.database, ClickEvent.database].inspect
begin
  Event.count
rescue Edgeway::ConfigurationError => e
  puts e.message
end
analytics_db = Edgeway::DB::MemoryAdapter.new
Edgeway::Model.connect(:analytics, analytics_db)
puts Edgeway::Model.connection_for("analytics").equal?(analytics_db)
puts Event.connection.equal?(analytics_db)
puts Todo.connection.equal?(db)
db.log.clear

analytics_db.queue([{ "id" => 1, "name" => "signup" }])
event = Event.create!(name: "signup")
event.update!(name: "login")
analytics_db.queue([{ "n" => 1 }])
ClickEvent.count
analytics_db.queue([{ "n" => 1 }])
Event.where(name: "login").count
Event.find_by_sql("SELECT * FROM events WHERE id = ?", [1])
Edgeway::Model.select_all("SELECT 1", [], database: :analytics)
Edgeway::Model.execute("DELETE FROM events", [], database: "analytics")
event.destroy
Event.delete_all
show(analytics_db)
p db.log

db.log.clear
analytics_db.log.clear
p Edgeway::Model.exec("CREATE TABLE a (id)\nINSERT INTO a VALUES (1)")
p Edgeway::Model.exec("DROP TABLE a", database: :analytics)
p [db.log, analytics_db.log]
begin
  Edgeway::Model.batch { Edgeway::Model.exec("DROP TABLE a") }
rescue ArgumentError => e
  puts e.message
end
p [db.log, analytics_db.log]
db.fail_next("D1_EXEC_ERROR: syntax error")
begin
  Edgeway::Model.exec("NOPE")
rescue Edgeway::DatabaseError => e
  puts e.message
end
["", "  \n", nil].each do |sql|
  begin
    Edgeway::Model.exec(sql)
  rescue ArgumentError => e
    puts e.message
  end
end
db.log.clear
analytics_db.log.clear

analytics_db.queue([{ "id" => 1, "note" => "n", "todo_id" => 7 }])
impression = Impression.first
db.queue([{ "id" => 7, "title" => "p", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
puts impression.todo.title
show(analytics_db)
show(db)

event = Event.instantiate({ "id" => 1, "name" => "signup" })
Edgeway::Model.batch do
  event.update!(name: "one")
  Event.delete_all
end
show(analytics_db)
p db.log

begin
  Edgeway::Model.batch do
    event.update!(name: "two")
    bt.update!(title: "mixed")
  end
rescue ArgumentError => e
  puts e.message
end
p Edgeway::Model.batching?
p [db.log, analytics_db.log]
begin
  Edgeway::Model.batch do
    bt.update!(title: "mixed")
    event.update!(name: "two")
  end
rescue ArgumentError => e
  puts e.message
end
p [db.log, analytics_db.log]

begin
  Impression.eager_load(:todo).to_a
rescue ArgumentError => e
  puts e.message
end
p [db.log, analytics_db.log]

analytics_db.record_meta(JSON.parse('{"rows_read":2,"rows_written":0,"duration":1,"served_by_region":"WEUR","served_by_primary":true}'))
puts JSON.generate(Edgeway::Model.query_stats(:analytics).log_fields)
puts Edgeway::Model.database_names.inspect

class Venue < ApplicationModel
  attribute :name, :string
  has_many :guests, dependent: :destroy
end

class Stand < ApplicationModel
  attribute :name, :string
  has_many :passes, dependent: :delete_all
end

class Guest < ApplicationModel
  self.database = :analytics
  attribute :venue_id, :integer
end

class Pass < ApplicationModel
  self.database = :analytics
  attribute :stand_id, :integer
end

[Venue.instantiate({ "id" => 1, "name" => "hall" }), Stand.instantiate({ "id" => 1, "name" => "booth" })].each do |owner|
  db.log.clear
  analytics_db.log.clear
  begin
    owner.destroy
  rescue ArgumentError => e
    puts e.message
  end
  p owner.persisted?
  p [db.log, analytics_db.log]
end
