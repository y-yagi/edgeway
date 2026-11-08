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

class Basket < ApplicationModel
  attribute :name, :string
  has_many :categories
end

class Attachment < ApplicationModel
  attribute :name, :string
  attribute :data, :binary
end

class Ledger < ApplicationModel
  attribute :id, :bigint
  attribute :total, :bigint
end

class Category < ApplicationModel
  attribute :basket_id, :integer
end

db = Edgeway::DB::MemoryAdapter.new
Edgeway::Model.connection = db
Edgeway::Model.freeze_time("2026-01-02T03:04:05.000Z")

def show(db)
  puts db.log
  db.log.clear
end

puts Todo.table_name
puts Comment.table_name

# queries
Todo.where(done: false).order(:title, :desc).limit(5).offset(10).to_a
show(db)
db.queue([{ "n" => 4 }])
p Todo.where("priority" => "high").count
show(db)
db.queue([{ "id" => 3, "title" => "a", "done" => 1, "priority" => "low", "position" => 2, "created_at" => "t", "updated_at" => "t" }])
t = Todo.find(3)
p t.as_json
show(db)
p t.done
db.queue([])
begin
  Todo.find(4)
rescue Edgeway::RecordNotFound => e
  puts e.message
end
show(db)
begin
  Todo.order("title;DROP TABLE todos")
rescue Edgeway::UnknownColumn => e
  puts e.message
end
begin
  Todo.where(nope: 1)
rescue Edgeway::BadRequest => e
  puts e.message
end
db.queue([{ "title" => "x" }, { "title" => "y" }])
p Todo.pluck(:title)
show(db)

# create and validations
db.queue([{ "id" => 9, "title" => "new", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
n = Todo.create!(title: "new", position: "1")
p n.id
p n.persisted?
show(db)

bad = Todo.create(title: "  ", priority: "urgent", position: "x")
p bad.persisted?
p bad.errors
show(db)
long = Todo.new(title: "12345678901", position: 1)
long.valid?
p long.errors
begin
  Todo.create!(title: "")
rescue Edgeway::RecordInvalid => e
  puts e.message
end

# update and destroy
n.update!(done: "true", title: "changed")
show(db)
p n.done
n.destroy
show(db)

# a database without RETURNING
db.returning = false
db.queue([{ "id" => 1, "title" => "z", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
z = Todo.create!(title: "z", position: 1)
p z.id
show(db)

# where(col: nil) is IS NULL, with no bind
Todo.where(position: nil).to_a
show(db)
Todo.where(position: nil, done: true).where(title: "x").to_a
show(db)
c = Todo.where(position: nil).build(title: "b")
p c.position

# exists?, count with a limit, an offset alone
db.queue([{ "n" => 1 }])
p Todo.exists?
show(db)
db.queue([{ "n" => 0 }])
p Todo.exists?(title: "none")
show(db)
db.queue([{ "n" => 2 }])
p Todo.limit(2).count
show(db)
Todo.offset(3).to_a
show(db)
db.queue([{ "n" => 0 }])
p Todo.where(done: true).empty?
show(db)

# first orders by id unless ordered; find and find_by ignore an offset
Todo.first
show(db)
Todo.order(:title).first
show(db)
db.queue([])
p Todo.offset(5).find_by(title: "z")
show(db)
db.queue([])
p Todo.where(done: true).offset(5).limit(3).find_by(title: "z")
show(db)

# 32-bit limits: an id outside them finds nothing, a limit or offset is a BadRequest
db.queue([])
begin
  Todo.find(4294967297)
rescue Edgeway::RecordNotFound => e
  puts e.message
end
show(db)
db.queue([])
begin
  Todo.find("99999999999999999999")
rescue Edgeway::RecordNotFound => e
  puts e.message
end
show(db)
["99999999999", "-1", 2147483648].each do |n|
  begin
    Todo.limit(n)
  rescue Edgeway::BadRequest => e
    puts e.message
  end
end
begin
  Todo.offset("4294967297")
rescue Edgeway::BadRequest => e
  puts e.message
end
p Todo.limit("2147483647").offset(0).to_a.size
show(db)
big = Todo.new(title: "t", position: "4294967297")
p big.valid?
p big.errors
p Edgeway::Model.cast(:integer, "2147483647")
p Edgeway::Model.cast(:integer, "-2147483648")
p Edgeway::Model.cast(:integer, "2147483648")

# one helper for plurals: ies <-> y
puts Category.table_name
puts Basket.table_name
puts Edgeway::Inflector.pluralize("day")
puts Edgeway::Inflector.pluralize("category")
puts Edgeway::Inflector.singularize("categories")
puts Edgeway::Inflector.singularize("todos")
%w[status class box wish match address bus post category day case base database type house todo comment].each do |w|
  pl = Edgeway::Inflector.pluralize(w)
  puts "#{w} #{pl} #{Edgeway::Inflector.singularize(pl)} #{Edgeway::Inflector.singularize(w)}"
end
%w[statuses classes addresses boxes wishes matches cases bases databases types houses todos comments].each do |pl|
  sg = Edgeway::Inflector.singularize(pl)
  puts "#{pl} #{sg} #{Edgeway::Inflector.pluralize(sg) == pl}"
end
basket = Basket.instantiate({ "id" => 4, "name" => "n" })
basket.categories.to_a
show(db)

# order adds terms; reorder replaces them
Todo.order(:updated_at, :desc).order(:id, :desc).to_a
show(db)
Todo.order(:title).order("position", "DESC").limit(2).to_a
show(db)
Todo.order(:title).order(:id).reorder(:position).to_a
show(db)
Todo.reorder(:title, :desc).to_a
show(db)
Todo.where(done: true).order(:title).reorder(:id, :desc).first
show(db)
Todo.order(:title).order(:id, :desc).first
show(db)
db.queue([{ "n" => 1 }])
Todo.order(:title).order(:id).count
show(db)
begin
  Todo.order(:title).order(:nope)
rescue Edgeway::UnknownColumn => e
  puts e.message
end
begin
  Todo.order(:title).order(:id, :sideways)
rescue Edgeway::BadRequest => e
  puts e.message
end
begin
  Todo.order(:title).reorder(:id, :up)
rescue Edgeway::BadRequest => e
  puts e.message
end
begin
  Todo.order(:title).reorder("id;DROP")
rescue Edgeway::UnknownColumn => e
  puts e.message
end

# delete_all: one DELETE, the number of rows, no records
p Todo.delete_all
show(db)
p Todo.where(done: true, position: nil).delete_all
show(db)
db.changes = 4
p Todo.where(priority: "low").order(:id).delete_all
show(db)
db.changes = 1
begin
  Todo.limit(2).delete_all
rescue ArgumentError => e
  puts e.message
end
begin
  Todo.where(done: true).offset(1).delete_all
rescue ArgumentError => e
  puts e.message
end
show(db)

# destroy_all: a SELECT, then one DELETE per row; the records
db.queue([{ "id" => 1, "title" => "a" }, { "id" => 2, "title" => "b" }])
gone = Todo.where(done: true).destroy_all
p gone.map(&:id)
p gone.map(&:persisted?)
show(db)
p Todo.destroy_all
show(db)

db.returning = true

# a persisted Todo that the multiple-database checks below reuse
db.queue([{ "id" => 1, "title" => "p", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
bt = Todo.find(1)
db.log.clear

db.log.clear
Todo.where(id: [1, "2"]).to_a
Todo.where(done: [true, false]).to_a
Todo.where(id: []).to_a
Todo.where(position: [1, nil]).to_a
Todo.where(position: [nil]).to_a
show(db)
Todo.where(position: 1..5).to_a
Todo.where(position: 1...5).to_a
Todo.where(position: (2..)).to_a
Todo.where(position: (..5)).to_a
Todo.where(position: (...5)).to_a
show(db)
Todo.where("title LIKE ?", "%x%").to_a
Todo.where("done = 1").to_a
Todo.where("title LIKE ? OR priority = ?", "%x%", "low").where(done: true).to_a
Todo.where("done = ?", true).to_a
show(db)
Todo.where(id: [1, 2]).where(position: 3..4).where("title <> ?", "z").where(done: false).order(:id).limit(5).offset(2).to_a
show(db)
db.queue([{ "n" => 2 }])
p Todo.where(id: [1, 2]).where("title <> ?", "z").limit(1).count
show(db)
db.queue([{ "n" => 1 }])
p Todo.where(position: 1..3).exists?
show(db)
Todo.where(id: [1, 2]).pluck(:title)
Todo.where(position: 1..3).first
Todo.where(id: [3, 4]).find_by(title: "z")
Todo.where("title LIKE ?", "a%").find_by(id: 7)
show(db)
Todo.where(id: [1, 2]).delete_all
Todo.where(position: 1...3).where("title = ?", "z").where(done: true).delete_all
Todo.where(id: []).delete_all
show(db)
db.queue([{ "id" => 1, "title" => "a" }, { "id" => 2, "title" => "b" }])
p Todo.where(id: [1, 2]).where("title <> ?", "z").destroy_all.size
show(db)
Todo.where(id: [1, 2]).eager_load(:comments).where("title <> ?", "z").limit(3).to_a
show(db)
todo = Todo.instantiate({ "id" => 5, "title" => "x" })
todo.comments.where(body: ["a", "b"]).where("body <> ?", "c").to_a
show(db)
begin
  Todo.where(nope: [1]).to_a
rescue Edgeway::UnknownColumn => e
  puts e.message
end
begin
  Todo.where(nope: 1..2).to_a
rescue Edgeway::UnknownColumn => e
  puts e.message
end

t0 = Time.utc(2026, 10, 28, 5, 0, 0)
db.log.clear
Todo.where(created_at: t0).to_a
Todo.where(created_at: [t0, t0 + 3600]).where("updated_at > ?", t0).to_a
Edgeway::Model.select_all("SELECT 1 WHERE ? < ?", [t0, true])
show(db)
begin
  Todo.where("id IN (?)", [1, 2])
rescue ArgumentError => e
  puts e.message
end
begin
  Todo.where({ id: 1 }, 2)
rescue ArgumentError => e
  puts e.message
end

# raw SQL
db.queue([{ "id" => 4, "title" => "raw", "done" => 1, "priority" => "low", "position" => 2 }])
raw = Todo.find_by_sql("SELECT * FROM todos WHERE done = ? AND title LIKE ?", [true, "r%"])
p raw.map { |r| [r.id, r.title, r.done, r.persisted?] }
db.queue([{ "n" => 3 }])
p Edgeway::Model.select_all("SELECT COUNT(*) AS n FROM todos WHERE done = ?", [false])
p Todo.find_by_sql("SELECT * FROM todos").size
p Edgeway::Model.execute("UPDATE todos SET done = ? WHERE id = ?", [true, 1])
p Edgeway::Model.execute("DELETE FROM todos")
show(db)
results = Edgeway::Model.batch do
  p Edgeway::Model.execute("UPDATE todos SET done = ? WHERE id = ?", [true, 1])
  Edgeway::Model.execute("DELETE FROM comments WHERE todo_id = ?", [1])
  p db.log.size
end
p results
show(db)

db.log.clear
Todo.where(id: (1..100).to_a).to_a
p db.log.size
begin
  Todo.where(id: (1..101).to_a).to_a
rescue ArgumentError => e
  puts e.message
end
Todo.where(id: (1..100).to_a).limit(1).offset(2).to_a
puts db.log.last.split(" | ")[0][-30..]
begin
  Edgeway::Model.execute("DELETE FROM todos WHERE id IN (#{(1..101).map { "?" }.join(", ")})", (1..101).to_a)
rescue ArgumentError => e
  puts e.message
end
begin
  Edgeway::Model.batch do
    Edgeway::Model.execute("DELETE FROM todos WHERE id = ?", [1])
    Edgeway::Model.execute("DELETE FROM todos WHERE id IN (#{(1..101).map { "?" }.join(", ")})", (1..101).to_a)
  end
rescue ArgumentError => e
  puts e.message
end
p db.log.size
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
