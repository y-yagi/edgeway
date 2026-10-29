# Spinel only (ffi_lib cannot run under CRuby): `rake test:spinel` builds it.
require "edgeway"
require "edgeway/db/sqlite"

class ApplicationModel < Edgeway::Model::Base
  extend Edgeway::Model::Macros
end

class Group < ApplicationModel
  attribute :name, :string
  attribute :score, :float
  attribute :active, :boolean, default: false
  attribute :rank, :integer
  has_many :members
end

class Member < ApplicationModel
  attribute :name, :string
  belongs_to :group
end

class Label < ApplicationModel
  attribute :name, :string
end

class Document < ApplicationModel
  attribute :name, :string
  attribute :body, :binary
end

class Ticket < ApplicationModel
  attribute :id, :bigint
  attribute :title, :string
  attribute :owner_id, :bigint
end

class Reference < ApplicationModel
  attribute :ticket_id, :integer
  attribute :note, :string
end

class Event < ApplicationModel
  attribute :name, :string
  timestamps
end

db = Edgeway::DB::SQLiteAdapter.new(":memory:")
Edgeway::Model.connection = db
db.load_schema(<<~SQL)
  CREATE TABLE groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score REAL, active INTEGER NOT NULL DEFAULT 0, rank INTEGER);
  CREATE TABLE members (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE, name TEXT);
  CREATE TABLE ratings (id INTEGER PRIMARY KEY AUTOINCREMENT, stars INTEGER CHECK (stars BETWEEN 1 AND 5));
  CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, created_at TEXT, updated_at TEXT);
  CREATE TABLE documents (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, body BLOB);
  CREATE TABLE tickets (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, owner_id INTEGER);
  CREATE TABLE refs (id INTEGER PRIMARY KEY AUTOINCREMENT, ticket_id INTEGER, note TEXT);
  CREATE TABLE labels (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, UNIQUE (name));
SQL

puts "returning: #{db.supports_returning?}"

# raw adapter: types
r = db.execute("INSERT INTO groups (name, score, rank) VALUES (?, ?, ?)", ["a'b", 1.5, 9000000000])
p r
rows = db.select_all("SELECT id, name, score, active, rank FROM groups", [])
p rows
p rows[0]["rank"].class
p rows[0]["score"].class
p db.execute("INSERT INTO groups (name) VALUES (?)", ["nil-score"])
p db.select_all("SELECT score, rank FROM groups WHERE id = ?", [2])
p db.select_all("SELECT 1 AS one, 2.5 AS two, 'x' AS three, NULL AS four", [])
p db.select_all("SELECT id FROM groups WHERE name = ?", ["none"])
p db.execute("INSERT INTO groups (name, active) VALUES (?, ?)", ["bools", true])
p db.select_all("SELECT active FROM groups WHERE name = ?", ["bools"])

# model CRUD
g = Group.create!(name: "g1", score: 2.25, active: true, rank: 3)
p g.as_json
p Group.find(g.id).as_json
g.update!(name: "g1b", rank: nil)
p Group.find(g.id).as_json
p Group.where(name: "g1b").count
p Group.where(rank: nil).count
p Group.where(active: true).pluck(:name)
g.destroy
p Group.exists?(id: g.id)
p Group.pluck(:name)
puts "---"

# errors
begin
  Label.create!(name: "x")
  Label.create!(name: "x")
rescue Edgeway::RecordNotUnique => e
  puts "unique: #{e.message}"
end
begin
  db.select_all("SELECT nope FROM nowhere", [])
rescue Edgeway::DatabaseError => e
  puts "db error: #{e.message} #{e.is_a?(Edgeway::RecordNotUnique)}"
end
begin
  db.execute("INSERT INTO labels (name) VALUES (?)", [nil])
rescue Edgeway::NotNullViolation => e
  puts "not null: #{e.message}"
end
begin
  db.execute("INSERT INTO ratings (stars) VALUES (?)", [9])
rescue Edgeway::CheckViolation => e
  puts "check: #{e.message}"
end
p Label.count

# batch
res = db.batch([["INSERT INTO labels (name) VALUES (?)", ["b1"]], ["INSERT INTO labels (name) VALUES (?)", ["b2"]]])
p res.size
p Label.pluck(:name)
begin
  db.batch([["INSERT INTO labels (name) VALUES (?)", ["b3"]], ["INSERT INTO labels (name) VALUES (?)", ["b1"]]])
rescue Edgeway::RecordNotUnique => e
  puts "rolled back: #{e.message}"
end
p Label.pluck(:name)
# the connection is usable after a rollback
Label.create!(name: "b4")
p Label.count

# Model.batch
l1 = Label.find_by(name: "b1")
l2 = Label.find_by(name: "b2")
Edgeway::Model.batch do
  l1.update!(name: "c1")
  l2.update!(name: "c2")
end
p Label.order(:id).pluck(:name)
l1 = Label.find_by(name: "c1")
l2 = Label.find_by(name: "c2")
begin
  Edgeway::Model.batch do
    l1.update!(name: "d1")
    l2.update!(name: "b4")
  end
rescue Edgeway::RecordNotUnique => e
  puts "model batch rolled back"
end
p Label.order(:id).pluck(:name)

# cascade
g = Group.create!(name: "parent")
Member.create!(group_id: g.id, name: "m1")
Member.create!(group_id: g.id, name: "m2")
p Member.count
db.execute("DELETE FROM groups WHERE id = ?", [g.id])
p Member.count
begin
  db.execute("INSERT INTO members (group_id, name) VALUES (?, ?)", [999, "orphan"])
rescue Edgeway::InvalidForeignKey => e
  puts "fk: #{e.message}"
end

# RETURNING
p db.insert_returning("INSERT INTO labels (name) VALUES (?) RETURNING id, name", ["ret"])
p db.execute("UPDATE labels SET name = ? WHERE name = ?", ["ret2", "ret"])["changes"]
p db.execute("DELETE FROM labels WHERE name = ?", ["zzz"])["changes"]

# log
db.log.clear
Label.find_by(name: "ret2")
puts db.log

# where: IN, Range, fragments; raw SQL
Group.delete_all
[["a", 1.0, 1, true], ["b", 2.0, 2, false], ["c", 3.0, 3, true], ["d", 4.0, nil, false], ["e'", 5.0, 5, true]].each do |n, s, r, a|
  Group.create!(name: n, score: s, rank: r, active: a)
end
p Group.where(rank: [1, 3]).order(:id).pluck(:name)
p Group.where(rank: ["2", 5]).order(:id).pluck(:name)
p Group.where(rank: []).count
p Group.where(rank: [1, nil]).order(:id).pluck(:name)
p Group.where(active: [true]).order(:id).pluck(:name)
p Group.where(name: ["a", "e'"]).order(:id).pluck(:name)
p Group.where(rank: 2..4).order(:id).pluck(:name)
p Group.where(rank: 2...4).order(:id).pluck(:name)
p Group.where(rank: (3..)).order(:id).pluck(:name)
p Group.where(rank: (..2)).order(:id).pluck(:name)
p Group.where(score: 1.5..3.5).order(:id).pluck(:name)
p Group.where("name LIKE ?", "%'").pluck(:name)
p Group.where("rank > 1 AND active = 1").order(:id).pluck(:name)
p Group.where("rank > ? OR rank IS NULL", 4).order(:id).pluck(:name)
p Group.where("active = ?", true).where(rank: 1..3).order(:id).pluck(:name)
p Group.where(rank: [1, 2, 3]).where("name <> ?", "b").order(:id).limit(1).offset(1).pluck(:name)
p Group.where(rank: 1..3).count
p Group.where("name = ?", "a").exists?
p Group.where(rank: [1, 2]).first.name
p Group.where(rank: [4]).find_by(name: "d")
p Group.where(rank: 3..9).find_by(name: "e'").name
p Group.where(rank: [1, 2, 3]).eager_load(:members).to_a.size
p Group.where(rank: 1..2).build(name: "z").rank
p Group.where(rank: [5], name: "e'").destroy_all.map { |g| g.name }
p Group.where(rank: 1...2).delete_all
p Group.where("name = ?", "none").delete_all
p Group.where(rank: [2, 3]).order(:id).pluck(:name)
g = Group.where(rank: 2).first
Member.create!(group_id: g.id, name: "m")
p g.members.where(name: ["m", "n"]).where("name <> ?", "x").count
p Group.find_by_sql("SELECT * FROM groups WHERE rank >= ? ORDER BY id", [2]).map { |x| [x.name, x.active, x.score] }
p Group.find_by_sql("SELECT id, name, score, active, rank FROM groups WHERE active = ?", [false]).map { |x| x.as_json }
p Edgeway::Model.select_all("SELECT name, active FROM groups WHERE active = ? ORDER BY id", [true])
p Edgeway::Model.execute("UPDATE groups SET rank = ? WHERE name = ?", [10, "c"])
p Edgeway::Model.execute("INSERT INTO labels (name) VALUES (?)", ["raw"])["changes"]
Edgeway::Model.batch do
  p Edgeway::Model.execute("UPDATE groups SET rank = ? WHERE name = ?", [11, "c"])
  Edgeway::Model.execute("DELETE FROM labels WHERE name = ?", ["raw"])
  p Group.find_by(name: "c").rank
end
p Group.find_by(name: "c").rank
p Label.where(name: "raw").count
p Group.where(id: (1..100).to_a).count
begin
  Group.where(id: (1..101).to_a).count
rescue ArgumentError => e
  puts e.message
end
begin
  Edgeway::Model.batch do
    Edgeway::Model.execute("UPDATE groups SET rank = 0", [])
    Edgeway::Model.execute("DELETE FROM groups WHERE id IN (#{(1..101).map { "?" }.join(", ")})", (1..101).to_a)
  end
rescue ArgumentError => e
  puts e.message
end
p Group.find_by(name: "c").rank

t0 = Time.utc(2026, 10, 28, 5, 0, 0)
[0, 1800, 3600, 7200].each_with_index do |d, i|
  Edgeway::Model.freeze_time((t0 + d).utc.iso8601(3))
  Event.create!(name: "e#{i}")
end
Edgeway::Model.freeze_time(nil)
p Event.where("created_at >= ? AND created_at <= ?", t0, t0 + 3600).order(:id).pluck(:name)
p Event.where(created_at: [t0, t0 + 7200]).order(:id).pluck(:name)
p Event.where(created_at: t0).pluck(:name)
p Event.where("created_at > ?", t0 + 1800).order(:id).pluck(:name)
p Event.find_by_sql("SELECT * FROM events WHERE created_at < ?", [t0 + 1800]).map { |e| e.name }
p Event.where(created_at: "2026-10-28T05:00:00.000Z".."2026-10-28T06:00:00.000Z").order(:id).pluck(:name)
p Event.where(created_at: t0.utc.iso8601(3)...(t0 + 3600).utc.iso8601(3)).order(:id).pluck(:name)
p Edgeway::Model.select_all("SELECT name FROM events WHERE created_at = ?", [t0 + 7200])
begin
  Group.where("rank IN (?)", [1, 2])
rescue ArgumentError => e
  puts e.message
end

# binary
bytes = [0, 1, 255, 0, 128, 10, 200].pack("C*")
doc = Document.create!(name: "bin", body: bytes)
p doc.body.bytes
p doc.body.encoding
found = Document.find(doc.id)
p found.body == bytes
p found.as_json
p db.select_all("SELECT typeof(body) AS type, length(body) AS bytes, hex(body) AS hex FROM documents", [])
p db.select_all("SELECT body FROM documents", [])
doc.update!(body: [0, 0].pack("C*"))
p Document.find(doc.id).body.bytes
p Document.where(body: [0, 0].pack("C*")).count
p Document.where(body: [0, 1].pack("C*")).count
p Document.where(body: [[0, 0].pack("C*"), bytes]).count
Document.create!(name: "empty", body: "")
Document.create!(name: "none")
p Document.order(:id).map { |d| d.body.nil? ? nil : d.body.bytesize }
p Document.find_by_sql("SELECT * FROM documents WHERE name = ?", ["bin"]).first.body.bytes
p Document.new(body: {"$blob" => "AAH/"}).body.bytes

# bigint
p Ticket.create!(title: "small").id
db.execute("UPDATE sqlite_sequence SET seq = ? WHERE name = ?", ["3000000000", "tickets"])
ticket = Ticket.create!(title: "big", owner_id: "5000000000")
p ticket.id
p ticket.owner_id
p ticket.as_json
p db.select_all("SELECT typeof(id) AS id_type, typeof(owner_id) AS owner_type FROM tickets WHERE title = ?", ["big"])
p db.execute("INSERT INTO tickets (title) VALUES (?)", ["raw"])
big = Ticket.find(ticket.id)
p big.title
p Ticket.find("3000000001").title
p Ticket.where(id: ["3000000001", 1]).order(:id).pluck(:title)
p Ticket.where(owner_id: "5000000000").count
p Ticket.where(id: "3000000001"..).count
big.update!(title: "big2")
p Ticket.find(big.id).title
big.destroy
p Ticket.exists?(id: 3000000001)
p Ticket.order(:id).pluck(:id)
db.execute("UPDATE sqlite_sequence SET seq = ? WHERE name = ?", ["3000000010", "tickets"])
p Ticket.new(title: "x").tap { |t| t.save }.id

# a value an :integer can't hold is not overwritten by NULL
Reference.table_name = "refs"
db.execute("INSERT INTO refs (ticket_id, note) VALUES (?, ?)", ["5000000000", "a"])
reference = Reference.first
p reference.ticket_id
p reference.update(note: "b")
p reference.errors
p db.select_all("SELECT ticket_id, note FROM refs", [])

begin
  db.execute("INSERT INTO documents (name, body) VALUES (?, ?)", ["x", { "other" => 1 }])
rescue ArgumentError => e
  puts e.message
end
begin
  db.execute("INSERT INTO documents (name, body) VALUES (?, ?)", ["x", { "$blob" => "!!" }])
rescue ArgumentError => e
  puts e.message
end
p Document.count

class Visit < ApplicationModel
  self.database = :stats
  attribute :path, :string
end

stats_db = Edgeway::DB::SQLiteAdapter.new(":memory:")
stats_db.load_schema("CREATE TABLE visits (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT)")
Edgeway::Model.connect(:stats, stats_db)
p Visit.create!(path: "/a").id
p Visit.where(path: "/a").count
Edgeway::Model.batch do
  Visit.where(path: "/a").delete_all
end
p Edgeway::Model.select_all("SELECT COUNT(*) AS n FROM visits", [], database: :stats)
begin
  db.select_all("SELECT * FROM visits", [])
rescue Edgeway::DatabaseError => e
  puts e.message
end
stats_db.close

# a second database is separate
db2 = Edgeway::DB::SQLiteAdapter.new(":memory:")
db2.load_schema("CREATE TABLE t (id INTEGER PRIMARY KEY)")
p db2.select_all("SELECT COUNT(*) AS n FROM t", [])
db2.close
db.close
