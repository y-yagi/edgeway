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

db = Edgeway::DB::SQLiteAdapter.new(":memory:")
Edgeway::Model.connection = db
db.load_schema(<<~SQL)
  CREATE TABLE groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score REAL, active INTEGER NOT NULL DEFAULT 0, rank INTEGER);
  CREATE TABLE members (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE, name TEXT);
  CREATE TABLE ratings (id INTEGER PRIMARY KEY AUTOINCREMENT, stars INTEGER CHECK (stars BETWEEN 1 AND 5));
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

# a second database is separate
db2 = Edgeway::DB::SQLiteAdapter.new(":memory:")
db2.load_schema("CREATE TABLE t (id INTEGER PRIMARY KEY)")
p db2.select_all("SELECT COUNT(*) AS n FROM t", [])
db2.close
db.close
