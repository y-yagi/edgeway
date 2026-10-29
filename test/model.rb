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

class Measure < ApplicationModel
  attribute :amount, :float
  attribute :qty, :integer
  attribute :ratio, :float
  attribute :code, :string
  validates :amount, numericality: { greater_than: 0 }
  validates :qty, numericality: { only_integer: true, less_than_or_equal_to: 100 }
  validates :ratio, numericality: true
  validates :code, length: { in: 2..4 }
end

class Pin < ApplicationModel
  attribute :code, :string
  validates :code, length: { is: 3 }
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

class Project < ApplicationModel
  attribute :owner_id, :string
  attribute :name, :string
  validates :name, presence: true, uniqueness: { scope: :owner_id }
end

class Tag < ApplicationModel
  attribute :name, :string
  attribute :a, :string
  attribute :b, :string
  validates :name, uniqueness: true
  validates :a, uniqueness: { scope: [:b, :name] }
end

class Odd < ApplicationModel
  attribute :name, :string
  validates :name, uniqueness: { scope: :nope }
end

class Category < ApplicationModel
  attribute :basket_id, :integer
end

class Group < ApplicationModel
  attribute :name, :string
  has_many :members, dependent: :destroy
  has_many :notes
end

class Member < ApplicationModel
  attribute :name, :string
  belongs_to :group
  has_many :notes, dependent: :destroy
end

class Note < ApplicationModel
  attribute :body, :string
  belongs_to :member
end

class Team < ApplicationModel
  attribute :name, :string
  has_many :tasks, dependent: :delete_all
end

class Task < ApplicationModel
  attribute :title, :string
  belongs_to :team
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

# associations
db.queue([{ "id" => 1, "title" => "p", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
parent = Todo.find(1)
db.log.clear
parent.comments.order(:id).to_a
show(db)
db.queue([{ "id" => 1 }])
db.queue([{ "id" => 5, "body" => "b", "todo_id" => 1, "created_at" => "c", "updated_at" => "u" }])
c = parent.comments.create!(body: "b")
p c.todo_id
show(db)
db.queue([])
bad_comment = Comment.create(body: "x", todo_id: 99)
p bad_comment.errors
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

# numericality checks what was set, not the cast value
def check(attrs)
  m = Measure.new(attrs)
  m.valid?
  p m.errors
end
check(amount: "abc", qty: "x", ratio: "y", code: "abc")
check(amount: "1.5", qty: "1.9", ratio: "2", code: "abc")
check(amount: "1e3", qty: "1e3", ratio: "-1.5E-3", code: "abc")
check(amount: 0.00001, qty: 5, ratio: 1.5e-7, code: "abc")
# Float#to_s writes an exponent for these (set through the writers: a big
# integral Float in a Hash literal fails in Spinel)
big = Measure.new(qty: 5, code: "abc")
big.amount = 1.0e20
big.ratio = 0.00001
big.valid?
p big.errors
p big.amount
check(amount: "0.00001", qty: "101", ratio: "", code: "a")
check(amount: "  ", qty: nil, ratio: nil, code: "abcde")
check(amount: "Infinity", qty: "0x10", ratio: "1_000", code: "abc")
check(amount: 2, qty: 100, ratio: 3, code: "abcd")
m = Measure.new(amount: "2", qty: "3", ratio: "4", code: "abc")
m.qty = "z"
p m.valid?
p m.errors
m.qty = 7
p m.valid?
p m.qty

# length: is: and in:
["ab", "abc"].each do |code|
  pin = Pin.new(code: code)
  pin.valid?
  p pin.errors
end

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

# uniqueness: a query, only when nothing else failed
project_row = { "id" => 2, "owner_id" => "u1", "name" => "work" }
db.queue([project_row])
dup = Project.new(owner_id: "u1", name: "work")
p dup.valid?
p dup.errors
show(db)
db.queue([])
fresh = Project.new(owner_id: "u1", name: "home")
p fresh.valid?
show(db)
# the same record saved again is not a duplicate of itself
db.queue([project_row])
same = Project.instantiate(project_row)
p same.valid?
show(db)
# but another row with the value is
db.queue([{ "id" => 3, "owner_id" => "u1", "name" => "work" }])
p same.valid?
p same.errors
show(db)
# an invalid record does not query
p Project.new(owner_id: "u1", name: " ").valid?
show(db)
# a nil value is not checked (a nil scope is IS NULL)
p Tag.new(a: "x").valid?
show(db)
db.queue([])
db.queue([])
p Tag.new(name: "l", a: "x").valid?
show(db)
# a scope column that does not exist is an UnknownColumn
begin
  Odd.new(name: "n").valid?
rescue Edgeway::UnknownColumn => e
  puts e.message
end
show(db)

# find_or_create_by: found, so no insert
db.returning = true
db.queue([project_row])
found = Project.where(owner_id: "u1").find_or_create_by(name: "work")
p found.id
show(db)
# not found: the insert has the relation's conditions too
db.queue([])
db.queue([])
db.queue([{ "id" => 4, "owner_id" => "u1", "name" => "default" }])
made = Project.where(owner_id: "u1").find_or_create_by(name: "default")
p [made.id, made.owner_id, made.persisted?]
show(db)
# on the model; a validation failure answers the unsaved record
db.queue([])
bad_project = Project.find_or_create_by(name: "")
p [bad_project.persisted?, bad_project.errors]
show(db)
begin
  Project.find_or_create_by!(name: "")
rescue Edgeway::RecordInvalid => e
  puts e.message
end
show(db)
begin
  Project.find_or_create_by(nope: 1)
rescue Edgeway::UnknownColumn => e
  puts e.message
end
# the race: the insert is refused as not unique, the second find has the row
db.queue([])
db.queue([])
db.fail_next("D1_ERROR: UNIQUE constraint failed: projects.owner_id, projects.name: SQLITE_CONSTRAINT", "INSERT")
db.queue([{ "id" => 5, "owner_id" => "u1", "name" => "race" }])
raced = Project.where(owner_id: "u1").find_or_create_by!(name: "race")
p raced.id
show(db)
# still nothing: the error is raised
db.queue([])
db.queue([])
db.fail_next("D1_ERROR: UNIQUE constraint failed: projects.id: SQLITE_CONSTRAINT", "INSERT")
db.queue([])
begin
  Project.find_or_create_by(name: "ghost")
rescue Edgeway::RecordNotUnique => e
  puts e.message
end
show(db)

# D1's UNIQUE message is RecordNotUnique (a DatabaseError); others stay DatabaseError
db.fail_next("D1_ERROR: UNIQUE constraint failed: tags.name: SQLITE_CONSTRAINT")
begin
  db.execute("INSERT", [])
rescue Edgeway::RecordNotUnique => e
  puts "not unique: #{e.message}"
  p e.is_a?(Edgeway::DatabaseError)
end
db.fail_next("D1_ERROR: no such table: tags: SQLITE_ERROR")
begin
  db.select_all("SELECT", [])
rescue Edgeway::DatabaseError => e
  p e.is_a?(Edgeway::RecordNotUnique)
  puts e.message
end
show(db)
[
  "D1_ERROR: NOT NULL constraint failed: tags.name: SQLITE_CONSTRAINT",
  "D1_ERROR: FOREIGN KEY constraint failed: SQLITE_CONSTRAINT",
  "D1_ERROR: CHECK constraint failed: stars: SQLITE_CONSTRAINT",
  "D1_ERROR: no such table: tags: SQLITE_ERROR",
].each do |m|
  db.fail_next(m)
  begin
    db.execute("INSERT", [])
  rescue Edgeway::DatabaseError => e
    puts "#{e.class}: #{e.is_a?(Edgeway::RecordNotUnique)}"
  end
end
show(db)
[
  '{"error":"D1_ERROR: Network connection lost.","unavailable":true}',
  '{"error":"D1_ERROR: UNIQUE constraint failed: tags.name: SQLITE_CONSTRAINT"}',
  '{"error":"D1_ERROR: exceeded CPU time limit"}',
].each do |json|
  begin
    db.raise_error_result(JSON.parse(json), "d1: ")
  rescue Edgeway::DatabaseError => e
    puts "#{e.class}: #{e.message}"
  end
end
# INSERT ... RETURNING goes through the same mapping
db.queue([])
db.fail_next("UNIQUE constraint failed: projects.id", "RETURNING")
begin
  Project.create(owner_id: "u9", name: "x")
rescue Edgeway::RecordNotUnique => e
  puts "insert: #{e.message}"
end
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

# dependent: :destroy loads the children and destroys each (their dependents too)
db.queue([{ "id" => 7, "name" => "g" }])
group = Group.find(7)
db.log.clear
db.queue([{ "id" => 11, "name" => "m1", "group_id" => 7 }, { "id" => 12, "name" => "m2", "group_id" => 7 }])
db.queue([{ "id" => 21, "body" => "n", "member_id" => 11 }])
db.queue([])
p group.destroy
p group.persisted?
show(db)
# dependent: :delete_all is one DELETE for the children
team = Team.instantiate({ "id" => 3, "name" => "t" })
p team.destroy
show(db)
# a model without dependents (has_many alone) just deletes its row
Todo.instantiate({ "id" => 5, "title" => "x" }).destroy
show(db)
# an unknown dependent value is refused at the declaration
begin
  class Thing < ApplicationModel
    has_many :parts, dependent: :nullify
  end
rescue ArgumentError => e
  puts e.message
end

# foreign_key: and primary_key:
class Account < ApplicationModel
  attribute :uid, :string
  attribute :name, :string
  has_many :memberships, foreign_key: :member_ref
  has_many :logins, foreign_key: :account_uid, primary_key: :uid
  has_many :sessions, dependent: :destroy, foreign_key: :account_uid, primary_key: :uid
  has_many :audits, dependent: :delete_all, foreign_key: :account_uid, primary_key: :uid
  has_many :broken, foreign_key: :account_uid, primary_key: :nope
end

class Membership < ApplicationModel
  attribute :member_ref, :integer
  belongs_to :account, foreign_key: :member_ref
end

class Login < ApplicationModel
  attribute :account_uid, :string
end

class Session < ApplicationModel
  attribute :account_uid, :string
  has_many :tokens, dependent: :delete_all
end

class Token < ApplicationModel
  attribute :session_id, :integer
end

class Audit < ApplicationModel
  attribute :account_uid, :string
end

class Broken < ApplicationModel
  attribute :account_uid, :string
end

class Device < ApplicationModel
  attribute :owner_uid, :string
  belongs_to :account, foreign_key: :owner_uid, primary_key: :uid
end

puts "-- foreign_key and primary_key"
db.returning = true
account = Account.instantiate({ "id" => 4, "uid" => "u-1", "name" => "a" })
account.memberships.to_a
show(db)
account.logins.to_a
show(db)
# belongs_to with a foreign_key: integer column, find by id
db.queue([{ "id" => 4, "uid" => "u-1", "name" => "a" }])
m = Membership.instantiate({ "id" => 1, "member_ref" => 4 })
p m.account.uid
show(db)
db.queue([{ "id" => 4 }])
db.queue([{ "id" => 6, "member_ref" => 4 }])
m2 = Membership.create(member_ref: 4)
show(db)
db.queue([])
m3 = Membership.create(member_ref: 9)
p m3.errors
show(db)
# a String foreign key on the parent's uid
device = Device.new(owner_uid: "u-1")
p device.owner_uid
db.queue([{ "id" => 4, "uid" => "u-1", "name" => "a" }])
p device.account.name
show(db)
db.queue([])
begin
  device.account
rescue Edgeway::RecordNotFound => e
  puts e.message
end
show(db)
begin
  Device.new.account
rescue Edgeway::RecordNotFound => e
  puts e.message
end
show(db)
db.queue([{ "id" => 4 }])
db.queue([{ "id" => 2, "owner_uid" => "u-1" }])
p Device.create(owner_uid: "u-1").errors
show(db)
db.queue([])
p Device.create(owner_uid: "zz").errors
show(db)
p Device.create.errors
show(db)
# the default key still comes from the class name
Todo.instantiate({ "id" => 2 }).comments.to_a
show(db)
# dependents with custom keys
db.queue([{ "id" => 31, "account_uid" => "u-1" }])
p account.destroy
show(db)
# an unknown primary key is refused when the association is used
begin
  account.broken.to_a
rescue Edgeway::UnknownColumn => e
  puts e.message
end
show(db)

# Model.batch: writes are queued and sent as one BATCH; reads run at once
db.queue([{ "id" => 1, "title" => "p", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
bt = Todo.find(1)
db.log.clear
db.queue([{ "id" => 8, "title" => "x" }])
results = Edgeway::Model.batch do
  bt.update!(title: "batched")
  Todo.where(done: true).delete_all
  p Edgeway::Model.batching?
  Todo.where(done: false).destroy_all
end
p Edgeway::Model.batching?
p results
show(db)
# the queue is sent only at the end of the block: the log shows no UPDATE yet
Edgeway::Model.batch do
  bt.update!(title: "later")
  puts "in block: #{db.log.size} logged"
end
show(db)
# an empty batch sends nothing
p Edgeway::Model.batch { 1 + 1 }
p db.log
# a block that raises sends nothing and the error propagates; the queue is reset
begin
  Edgeway::Model.batch do
    bt.update!(title: "lost")
    raise "boom"
  end
rescue => e
  puts "raised #{e.message}"
end
p Edgeway::Model.batching?
p db.log
bt.update!(title: "plain")
show(db)
# nested batches join the outer one
p(Edgeway::Model.batch do
  bt.update!(title: "outer")
  Edgeway::Model.batch { Todo.where(done: true).delete_all }
  bt.update!(title: "after")
end.size)
show(db)
# a create is refused, before any SQL
begin
  Edgeway::Model.batch do
    bt.update!(title: "queued")
    Todo.create!(title: "new", position: 1)
  end
rescue ArgumentError => e
  puts e.message
end
p Edgeway::Model.batching?
p db.log
# a failure when the batch is sent: RecordNotUnique, state reset, the next batch works
db.fail_next("D1_ERROR: UNIQUE constraint failed: todos.title: SQLITE_CONSTRAINT", "DELETE")
begin
  Edgeway::Model.batch do
    bt.update!(title: "dup")
    Todo.where(done: true).delete_all
  end
rescue Edgeway::RecordNotUnique => e
  puts "not unique: #{e.message}"
end
p Edgeway::Model.batching?
show(db)
p Edgeway::Model.batch { Todo.where(done: true).delete_all }.size
show(db)
# destroy with dependents is one BATCH: the children's DELETEs, then the parent's
db.queue([{ "id" => 7, "name" => "g" }])
group = Group.find(7)
db.log.clear
db.queue([{ "id" => 11, "name" => "m1", "group_id" => 7 }])
db.queue([{ "id" => 21, "body" => "n", "member_id" => 11 }])
group.destroy
show(db)
team = Team.instantiate({ "id" => 3, "name" => "t" })
team.destroy
show(db)
# a failing batch leaves the parent persisted
team = Team.instantiate({ "id" => 3, "name" => "t" })
db.fail_next("D1_ERROR: boom", "DELETE FROM teams")
begin
  team.destroy
rescue Edgeway::DatabaseError => e
  puts e.message
end
p team.persisted?
show(db)

# strong parameters: only Parameters that went through permit are assigned
raw = Edgeway::HTTP::Parameters.new({ "title" => "t", "position" => "1" })
[-> { Todo.new(raw) }, -> { Todo.new(title: "a", position: 1).update(raw) }, -> { Todo.create!(raw) }].each do |f|
  begin
    f.call
  rescue Edgeway::ForbiddenAttributes => e
    puts "ForbiddenAttributes: #{e.message}"
  end
end
scoped = Edgeway::HTTP::Parameters.new({ "todo[title]" => "t", "todo[position]" => "1", "todo[done]" => "1" })
begin
  Todo.new(scoped.require(:todo))
rescue Edgeway::ForbiddenAttributes
  puts "require alone is not permitted"
end
ok = Todo.new(scoped.require(:todo).permit(:title, :position))
p [ok.title, ok.position, ok.done]
p Todo.new("title" => "s", :position => 2).title

# models inside a module: an association finds the model by its full name,
# the owner's namespace first, then the top level
module Blog
  class Post < ApplicationModel
    attribute :title, :string
    has_many :comments
    has_many :teams
  end

  class Comment < ApplicationModel
    attribute :post_id, :integer
    belongs_to :post
  end
end
p Blog::Post.table_name
p Edgeway::Model::Base.model_named("comments", "Blog::Post")
p Edgeway::Model::Base.model_named("teams", "Blog::Post")
p Edgeway::Model::Base.model_named("comments", "Post")
begin
  Edgeway::Model::Base.model_named("ghosts", "Blog::Post")
rescue ArgumentError => e
  puts e.message
end
db.log.clear
db.queue([])
Blog::Post.instantiate({ "id" => 4, "title" => "p" }).association("comments").to_a
db.queue([{ "id" => 4, "title" => "p" }])
Blog::Comment.instantiate({ "id" => 9, "post_id" => 4 }).parent_of("post")
show(db)

# eager_load: one LEFT JOIN for the whole list, the association answered from memory
db.log.clear
db.queue([
  { "p_id" => 1, "p_title" => "a", "p_done" => 0, "p_priority" => "normal", "p_position" => 1, "p_created_at" => "t", "p_updated_at" => "t",
    "c0_id" => 10, "c0_body" => "x", "c0_todo_id" => 1, "c0_created_at" => nil, "c0_updated_at" => nil },
  { "p_id" => 1, "p_title" => "a", "p_done" => 0, "p_priority" => "normal", "p_position" => 1, "p_created_at" => "t", "p_updated_at" => "t",
    "c0_id" => 11, "c0_body" => "y", "c0_todo_id" => 1, "c0_created_at" => nil, "c0_updated_at" => nil },
  { "p_id" => 2, "p_title" => "b", "p_done" => 1, "p_priority" => "low", "p_position" => 2, "p_created_at" => "t", "p_updated_at" => "t",
    "c0_id" => nil, "c0_body" => nil, "c0_todo_id" => nil, "c0_created_at" => nil, "c0_updated_at" => nil }
])
todos = Todo.where(done: false).order(:title).limit(5).eager_load(:comments).to_a
show(db)
p todos.map { |t| t.title }
p todos.map { |t| t.comments.to_a.map { |c| c.body } }
show(db)

# belongs_to: the parent comes with the child
db.queue([
  { "p_id" => 10, "p_body" => "x", "p_todo_id" => 1, "p_created_at" => nil, "p_updated_at" => nil,
    "c0_id" => 1, "c0_title" => "a", "c0_done" => 0, "c0_priority" => "normal", "c0_position" => 1, "c0_created_at" => "t", "c0_updated_at" => "t" }
])
comments = Comment.eager_load(:todo).to_a
p comments.map { |c| c.todo.title }
show(db)

begin
  Todo.eager_load(:ghosts).to_a
rescue ArgumentError => e
  puts e.message
end

# several associations: one LEFT JOIN each. Two has_manys repeat each child
# once per row of the other, so each parent gets each child once, by id
class Shelf < ApplicationModel
  attribute :name, :string
  has_many :books
  has_many :pens
end

class Book < ApplicationModel
  attribute :shelf_id, :integer
  belongs_to :shelf
  has_many :pages
end

class Pen < ApplicationModel
  attribute :shelf_id, :integer
end

class Page < ApplicationModel
  attribute :book_id, :integer
end

def shelf_row(id, name, bid, pid)
  { "p_id" => id, "p_name" => name,
    "c0_id" => bid, "c0_shelf_id" => bid.nil? ? nil : id,
    "c1_id" => pid, "c1_shelf_id" => pid.nil? ? nil : id }
end

db.log.clear
db.queue([
  shelf_row(1, "s1", 10, 20), shelf_row(1, "s1", 10, 21),
  shelf_row(1, "s1", 11, 20), shelf_row(1, "s1", 11, 21),
  shelf_row(2, "s2", nil, 22),
  shelf_row(3, "s3", nil, nil)
])
shelves = Shelf.where(name: "x").limit(3).eager_load(:books, :pens).to_a
show(db)
p shelves.map { |s| s.books.to_a.map { |b| b.id } }
p shelves.map { |s| s.pens.to_a.map { |b| b.id } }
show(db)

# chaining accumulates, and naming one twice joins it once
db.log.clear
db.queue([])
Shelf.eager_load(:books).eager_load(:pens, :books).to_a
show(db)

# has_many and belongs_to together
db.queue([
  { "p_id" => 10, "p_shelf_id" => 1, "c0_id" => 1, "c0_name" => "s1", "c1_id" => 100, "c1_book_id" => 10 },
  { "p_id" => 10, "p_shelf_id" => 1, "c0_id" => 1, "c0_name" => "s1", "c1_id" => 101, "c1_book_id" => 10 },
  { "p_id" => 11, "p_shelf_id" => nil, "c0_id" => nil, "c0_name" => nil, "c1_id" => nil, "c1_book_id" => nil }
])
books = Book.eager_load(:shelf, :pages).to_a
show(db)
p books[0].shelf.name
p books.map { |b| b.pages.to_a.map { |pg| pg.id } }

begin
  Shelf.eager_load(:books, :ghosts).to_a
rescue ArgumentError => e
  puts e.message
end

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

# build copies the equality conditions only
rec = Todo.where(position: 3, priority: "high").where(id: [9, 10]).where(position: 1..5).where("title = ?", "q").build(title: "b")
p [rec.position, rec.priority, rec.title, rec.id]
rec = Todo.where(position: [7]).where(priority: ["low"]).build
p [rec.position, rec.priority]

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

# D1 allows 100 bound parameters per statement
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

puts Edgeway::Model.query_stats.log_text
puts Edgeway::Model.query_stats.queries
stats_db = Edgeway::DB::MemoryAdapter.new
stats_db.record_meta(JSON.parse('{"rows_read":3,"rows_written":1,"duration":2,"served_by_region":"WEUR","served_by_primary":false}'))
stats_db.record_meta(JSON.parse('{"rows_read":4,"rows_written":0,"duration":0.456,"served_by_region":"ENAM","served_by_primary":true}'))
stats = stats_db.query_stats
puts [stats.queries, stats.rows_read, stats.rows_written, stats.duration_ms, stats.served_by_region, stats.served_by_primary].inspect
puts stats.log_text
batch_db = Edgeway::DB::MemoryAdapter.new
batch_db.record_meta(JSON.parse('{"rows_read":30,"rows_written":3,"duration":1.5,"served_by_region":"","served_by_primary":true}'))
puts batch_db.query_stats.log_text
big_db = Edgeway::DB::MemoryAdapter.new
big_db.record_meta(JSON.parse('{"rows_read":2147483647,"rows_written":5,"duration":1}'))
big_db.record_meta(JSON.parse('{"rows_read":10,"rows_written":5,"duration":1}'))
puts big_db.query_stats.log_text

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
puts Edgeway::Model.query_stats(:analytics).log_text
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
