require_relative "test_helper"

# The fallback target of the namespace lookup has to live at the top level.
class Beacon < Edgeway::Model::Base
  extend Edgeway::Model::Macros
  attribute :post_id, :integer
  attribute :label, :string
end

class ModelAssociationTest < DatabaseTestCase
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

    class Reply < ApplicationModel
    end
  end

  class Beacon < ApplicationModel
    attribute :post_id, :integer
    attribute :label, :string
  end

  class Comment < ApplicationModel
    attribute :body, :string
    belongs_to :todo
  end

  class Group < ApplicationModel
    attribute :name, :string
    has_many :members, dependent: :destroy
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

  # Spinel expands has_many only in a class body, so the class is declared
  # inside the begin and the refusal is kept for the test.
  begin
    class Thing < ApplicationModel
      has_many :parts, dependent: :nullify
    end
    UNKNOWN_DEPENDENT = "accepted"
  rescue ArgumentError => error
    UNKNOWN_DEPENDENT = error.message
  end

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

  module Blog
    class Post < ApplicationModel
      attribute :title, :string
      has_many :comments
      has_many :teams
      has_many :beacons
    end

    class Comment < ApplicationModel
      attribute :post_id, :integer
      belongs_to :post
    end
  end

  BLOG_POST = "ModelAssociationTest::Blog::Post"

  TODO_COLUMNS = "id, title, done, priority, position, created_at, updated_at"
  FIND_TODO_1 = "SELECT #{TODO_COLUMNS} FROM todos WHERE id = ? LIMIT 1 | [1]"
  FIND_ACCOUNT_4 = "SELECT id, uid, name FROM accounts WHERE id = ? LIMIT 1 | [4]"
  FIND_ACCOUNT_BY_UID_U1 = "SELECT id, uid, name FROM accounts WHERE uid = ? LIMIT 1 | [\"u-1\"]"

  EAGER_TODO_COMMENTS = "SELECT todos.id AS p_id, todos.title AS p_title, todos.done AS p_done, todos.priority AS p_priority, todos.position AS p_position, todos.created_at AS p_created_at, todos.updated_at AS p_updated_at, eager_comments.id AS c0_id, eager_comments.body AS c0_body, eager_comments.todo_id AS c0_todo_id FROM (SELECT #{TODO_COLUMNS} FROM todos WHERE done = ? ORDER BY title ASC LIMIT 5) AS todos LEFT JOIN comments AS eager_comments ON eager_comments.todo_id = todos.id ORDER BY todos.title ASC, eager_comments.id | [0]"
  EAGER_COMMENT_TODO = "SELECT comments.id AS p_id, comments.body AS p_body, comments.todo_id AS p_todo_id, eager_todo.id AS c0_id, eager_todo.title AS c0_title, eager_todo.done AS c0_done, eager_todo.priority AS c0_priority, eager_todo.position AS c0_position, eager_todo.created_at AS c0_created_at, eager_todo.updated_at AS c0_updated_at FROM (SELECT id, body, todo_id FROM comments) AS comments LEFT JOIN todos AS eager_todo ON eager_todo.id = comments.todo_id ORDER BY comments.id, eager_todo.id | []"
  EAGER_SHELF_BOOKS_PENS = "SELECT shelfs.id AS p_id, shelfs.name AS p_name, eager_books.id AS c0_id, eager_books.shelf_id AS c0_shelf_id, eager_pens.id AS c1_id, eager_pens.shelf_id AS c1_shelf_id FROM (SELECT id, name FROM shelfs WHERE name = ? LIMIT 3) AS shelfs LEFT JOIN books AS eager_books ON eager_books.shelf_id = shelfs.id LEFT JOIN pens AS eager_pens ON eager_pens.shelf_id = shelfs.id ORDER BY shelfs.id, eager_books.id, eager_pens.id | [\"x\"]"
  EAGER_SHELF_CHAINED = "SELECT shelfs.id AS p_id, shelfs.name AS p_name, eager_books.id AS c0_id, eager_books.shelf_id AS c0_shelf_id, eager_pens.id AS c1_id, eager_pens.shelf_id AS c1_shelf_id FROM (SELECT id, name FROM shelfs) AS shelfs LEFT JOIN books AS eager_books ON eager_books.shelf_id = shelfs.id LEFT JOIN pens AS eager_pens ON eager_pens.shelf_id = shelfs.id ORDER BY shelfs.id, eager_books.id, eager_pens.id | []"
  EAGER_BOOK_SHELF_PAGES = "SELECT books.id AS p_id, books.shelf_id AS p_shelf_id, eager_shelf.id AS c0_id, eager_shelf.name AS c0_name, eager_pages.id AS c1_id, eager_pages.book_id AS c1_book_id FROM (SELECT id, shelf_id FROM books) AS books LEFT JOIN shelfs AS eager_shelf ON eager_shelf.id = books.shelf_id LEFT JOIN pages AS eager_pages ON eager_pages.book_id = books.id ORDER BY books.id, eager_shelf.id, eager_pages.id | []"

  EAGER_ACCOUNT_LOGINS = "SELECT accounts.id AS p_id, accounts.uid AS p_uid, accounts.name AS p_name, eager_logins.id AS c0_id, eager_logins.account_uid AS c0_account_uid FROM (SELECT id, uid, name FROM accounts) AS accounts LEFT JOIN logins AS eager_logins ON eager_logins.account_uid = accounts.uid ORDER BY accounts.id, eager_logins.id | []"
  EAGER_ACCOUNT_MEMBERSHIPS = "SELECT accounts.id AS p_id, accounts.uid AS p_uid, accounts.name AS p_name, eager_memberships.id AS c0_id, eager_memberships.member_ref AS c0_member_ref FROM (SELECT id, uid, name FROM accounts) AS accounts LEFT JOIN memberships AS eager_memberships ON eager_memberships.member_ref = accounts.id ORDER BY accounts.id, eager_memberships.id | []"
  EAGER_DEVICE_ACCOUNT = "SELECT devices.id AS p_id, devices.owner_uid AS p_owner_uid, eager_account.id AS c0_id, eager_account.uid AS c0_uid, eager_account.name AS c0_name FROM (SELECT id, owner_uid FROM devices) AS devices LEFT JOIN accounts AS eager_account ON eager_account.uid = devices.owner_uid ORDER BY devices.id, eager_account.id | []"

  def parent_todo_row
    { "id" => 1, "title" => "p", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }
  end

  def account_row
    { "id" => 4, "uid" => "u-1", "name" => "a" }
  end

  def account
    Account.instantiate(account_row)
  end

  def shelf_row(id, name, book_id, pen_id)
    { "p_id" => id, "p_name" => name,
      "c0_id" => book_id, "c0_shelf_id" => book_id.nil? ? nil : id,
      "c1_id" => pen_id, "c1_shelf_id" => pen_id.nil? ? nil : id }
  end

  def test_has_many_queries_the_children_by_the_parents_id
    parent = Todo.instantiate(parent_todo_row)
    parent.comments.order(:id).to_a
    assert_equal ["SELECT id, body, todo_id FROM comments WHERE todo_id = ? ORDER BY id ASC | [1]"], @database.log
  end

  def test_has_many_create_sets_the_foreign_key_after_checking_the_parent
    @database.queue([{ "id" => 1 }])
    @database.queue([{ "id" => 5, "body" => "b", "todo_id" => 1, "created_at" => "c", "updated_at" => "u" }])
    parent = Todo.instantiate(parent_todo_row)
    comment = parent.comments.create!(body: "b")
    assert_equal "1", comment.todo_id.inspect
    assert_equal [FIND_TODO_1, "INSERT INTO comments (body, todo_id) VALUES (?, ?) RETURNING id, body, todo_id | [\"b\",1]"], @database.log
  end

  def test_a_child_of_a_missing_parent_is_refused
    @database.queue([])
    comment = Comment.create(body: "x", todo_id: 99)
    assert_equal ["todo must exist"], comment.errors
    assert_equal ["SELECT #{TODO_COLUMNS} FROM todos WHERE id = ? LIMIT 1 | [99]"], @database.log
  end

  def test_dependent_destroy_destroys_the_children_and_their_children
    @database.queue([{ "id" => 11, "name" => "m1", "group_id" => 7 }, { "id" => 12, "name" => "m2", "group_id" => 7 }])
    @database.queue([{ "id" => 21, "body" => "n", "member_id" => 11 }])
    @database.queue([])
    group = Group.instantiate({ "id" => 7, "name" => "g" })
    assert_equal true, group.destroy
    assert_equal false, group.persisted?
    expected = [
      "SELECT id, name, group_id FROM members WHERE group_id = ? | [7]",
      "SELECT id, body, member_id FROM notes WHERE member_id = ? | [11]",
      "SELECT id, body, member_id FROM notes WHERE member_id = ? | [12]",
      "BATCH 4",
      "DELETE FROM notes WHERE id = ? | [21]",
      "DELETE FROM members WHERE id = ? | [11]",
      "DELETE FROM members WHERE id = ? | [12]",
      "DELETE FROM groups WHERE id = ? | [7]",
    ]
    assert_equal expected, @database.log
  end

  def test_dependent_delete_all_is_one_delete_for_the_children
    team = Team.instantiate({ "id" => 3, "name" => "t" })
    assert_equal true, team.destroy
    assert_equal ["BATCH 2", "DELETE FROM tasks WHERE team_id = ? | [3]", "DELETE FROM teams WHERE id = ? | [3]"], @database.log
  end

  def test_a_model_without_dependents_deletes_only_its_row
    Todo.instantiate({ "id" => 5, "title" => "x" }).destroy
    assert_equal ["DELETE FROM todos WHERE id = ? | [5]"], @database.log
  end

  def test_an_unknown_dependent_value_is_refused_at_the_declaration
    assert_equal "unknown dependent: nullify", UNKNOWN_DEPENDENT
  end

  def test_has_many_foreign_key_names_the_childrens_column
    account.memberships.to_a
    assert_equal ["SELECT id, member_ref FROM memberships WHERE member_ref = ? | [4]"], @database.log
  end

  def test_has_many_primary_key_names_our_column
    account.logins.to_a
    assert_equal ["SELECT id, account_uid FROM logins WHERE account_uid = ? | [\"u-1\"]"], @database.log
  end

  def test_belongs_to_foreign_key_finds_the_parent_by_id
    @database.queue([account_row])
    membership = Membership.instantiate({ "id" => 1, "member_ref" => 4 })
    assert_equal "u-1", membership.account.uid
    assert_equal [FIND_ACCOUNT_4], @database.log
  end

  def test_belongs_to_foreign_key_checks_the_parent_on_create
    @database.queue([{ "id" => 4 }])
    @database.queue([{ "id" => 6, "member_ref" => 4 }])
    membership = Membership.create(member_ref: 4)
    assert_equal true, membership.persisted?
    assert_equal [FIND_ACCOUNT_4, "INSERT INTO memberships (member_ref) VALUES (?) RETURNING id, member_ref | [4]"], @database.log
  end

  def test_belongs_to_foreign_key_refuses_a_missing_parent_on_create
    @database.queue([])
    membership = Membership.create(member_ref: 9)
    assert_equal ["account must exist"], membership.errors
    assert_equal ["SELECT id, uid, name FROM accounts WHERE id = ? LIMIT 1 | [9]"], @database.log
  end

  def test_a_string_foreign_key_finds_the_parent_by_its_primary_key
    device = Device.new(owner_uid: "u-1")
    assert_equal "u-1", device.owner_uid
    @database.queue([account_row])
    assert_equal "a", device.account.name
    assert_equal [FIND_ACCOUNT_BY_UID_U1], @database.log
  end

  def test_a_string_foreign_key_without_a_parent_raises_not_found
    @database.queue([])
    device = Device.new(owner_uid: "u-1")
    error = assert_raise(Edgeway::RecordNotFound) { device.account }
    assert_equal "accounts uid u-1 not found", error.message
    assert_equal [FIND_ACCOUNT_BY_UID_U1], @database.log
  end

  def test_a_nil_string_foreign_key_raises_not_found_without_a_query
    error = assert_raise(Edgeway::RecordNotFound) { Device.new.account }
    assert_equal "accounts uid  not found", error.message
    assert_equal [], @database.log
  end

  def test_a_string_foreign_key_checks_the_parent_on_create
    @database.queue([{ "id" => 4 }])
    @database.queue([{ "id" => 2, "owner_uid" => "u-1" }])
    device = Device.create(owner_uid: "u-1")
    assert_equal [], device.errors
    assert_equal [FIND_ACCOUNT_BY_UID_U1, "INSERT INTO devices (owner_uid) VALUES (?) RETURNING id, owner_uid | [\"u-1\"]"], @database.log
  end

  def test_a_string_foreign_key_refuses_an_unknown_parent_on_create
    @database.queue([])
    device = Device.create(owner_uid: "zz")
    assert_equal ["account must exist"], device.errors
    assert_equal ["SELECT id, uid, name FROM accounts WHERE uid = ? LIMIT 1 | [\"zz\"]"], @database.log
  end

  def test_a_nil_string_foreign_key_is_refused_on_create_without_a_query
    device = Device.create
    assert_equal ["account must exist"], device.errors
    assert_equal [], @database.log
  end

  def test_the_default_foreign_key_comes_from_the_class_name
    Todo.instantiate({ "id" => 2 }).comments.to_a
    assert_equal ["SELECT id, body, todo_id FROM comments WHERE todo_id = ? | [2]"], @database.log
  end

  def test_dependents_use_the_custom_keys
    @database.queue([{ "id" => 31, "account_uid" => "u-1" }])
    assert_equal true, account.destroy
    expected = [
      "SELECT id, account_uid FROM sessions WHERE account_uid = ? | [\"u-1\"]",
      "BATCH 4",
      "DELETE FROM tokens WHERE session_id = ? | [31]",
      "DELETE FROM sessions WHERE id = ? | [31]",
      "DELETE FROM audits WHERE account_uid = ? | [\"u-1\"]",
      "DELETE FROM accounts WHERE id = ? | [4]",
    ]
    assert_equal expected, @database.log
  end

  def test_an_unknown_primary_key_is_refused_when_the_association_is_used
    error = assert_raise(Edgeway::UnknownColumn) { account.broken.to_a }
    assert_equal "unknown column: nope", error.message
    assert_equal [], @database.log
  end

  def test_a_model_in_a_module_uses_the_last_name_segment_as_its_table
    assert_equal "posts", Blog::Post.table_name
  end

  def test_the_owners_namespace_is_searched_before_the_outer_ones
    assert_equal "ModelAssociationTest::Blog::Comment", Edgeway::Model::Base.model_named("comments", BLOG_POST).name
  end

  def test_an_outer_namespace_is_searched_when_the_owners_has_no_such_model
    assert_equal "ModelAssociationTest::Team", Edgeway::Model::Base.model_named("teams", BLOG_POST).name
  end

  def test_an_outer_namespace_is_searched_before_the_top_level
    assert_equal "ModelAssociationTest::Beacon", Edgeway::Model::Base.model_named("beacons", BLOG_POST).name
  end

  def test_an_owner_without_a_namespace_looks_at_the_top_level_only
    assert_equal "Beacon", Edgeway::Model::Base.model_named("beacons", "Post").name
    error = assert_raise(ArgumentError) { Edgeway::Model::Base.model_named("comments", "Post") }
    assert_equal "no model for comments", error.message
  end

  def test_a_constant_that_is_not_a_model_is_not_found
    error = assert_raise(ArgumentError) { Edgeway::Model::Base.model_named("strings", BLOG_POST) }
    assert_equal "no model for strings", error.message
  end

  # The owner's own name is dropped from the scope: only the namespaces around
  # the owner are searched (on purpose, unlike Rails).
  def test_a_model_nested_in_the_owner_class_is_not_in_the_owners_namespace
    error = assert_raise(ArgumentError) { Edgeway::Model::Base.model_named("replies", "ModelAssociationTest::Todo") }
    assert_equal "no model for replies", error.message
  end

  def test_a_model_next_to_the_owner_is_found_in_the_shared_namespace
    assert_equal "ModelAssociationTest::Comment", Edgeway::Model::Base.model_named("comments", "ModelAssociationTest::Todo").name
  end

  def test_a_name_no_namespace_has_is_refused
    error = assert_raise(ArgumentError) { Edgeway::Model::Base.model_named("ghosts", BLOG_POST) }
    assert_equal "no model for ghosts", error.message
  end

  def test_has_many_reads_the_model_of_the_owners_namespace
    @database.queue([{ "id" => 9, "post_id" => 4 }])
    comments = Blog::Post.instantiate({ "id" => 4, "title" => "p" }).association("comments").to_a
    assert_equal ["ModelAssociationTest::Blog::Comment"], comments.map { |comment| comment.class.name }
    assert_equal ["SELECT id, post_id FROM comments WHERE post_id = ? | [4]"], @database.log
  end

  def test_belongs_to_reads_the_model_of_the_owners_namespace
    @database.queue([{ "id" => 4, "title" => "p" }])
    post = Blog::Comment.instantiate({ "id" => 9, "post_id" => 4 }).parent_of("post")
    assert_equal "ModelAssociationTest::Blog::Post", post.class.name
    assert_equal ["SELECT id, title FROM posts WHERE id = ? LIMIT 1 | [4]"], @database.log
  end

  def test_has_many_reads_the_model_of_an_outer_namespace
    @database.queue([{ "id" => 3, "post_id" => 4, "label" => "l" }])
    beacons = Blog::Post.instantiate({ "id" => 4, "title" => "p" }).association("beacons").to_a
    assert_equal ["ModelAssociationTest::Beacon"], beacons.map { |beacon| beacon.class.name }
    assert_equal ["SELECT id, post_id, label FROM beacons WHERE post_id = ? | [4]"], @database.log
  end

  def test_eager_load_joins_the_children_in_one_query
    @database.queue([
      { "p_id" => 1, "p_title" => "a", "p_done" => 0, "p_priority" => "normal", "p_position" => 1, "p_created_at" => "t", "p_updated_at" => "t",
        "c0_id" => 10, "c0_body" => "x", "c0_todo_id" => 1, "c0_created_at" => nil, "c0_updated_at" => nil },
      { "p_id" => 1, "p_title" => "a", "p_done" => 0, "p_priority" => "normal", "p_position" => 1, "p_created_at" => "t", "p_updated_at" => "t",
        "c0_id" => 11, "c0_body" => "y", "c0_todo_id" => 1, "c0_created_at" => nil, "c0_updated_at" => nil },
      { "p_id" => 2, "p_title" => "b", "p_done" => 1, "p_priority" => "low", "p_position" => 2, "p_created_at" => "t", "p_updated_at" => "t",
        "c0_id" => nil, "c0_body" => nil, "c0_todo_id" => nil, "c0_created_at" => nil, "c0_updated_at" => nil },
    ])
    todos = Todo.where(done: false).order(:title).limit(5).eager_load(:comments).to_a
    assert_equal [EAGER_TODO_COMMENTS], @database.log
    assert_equal ["a", "b"], todos.map { |todo| todo.title }
    assert_equal [["x", "y"], []], todos.map { |todo| todo.comments.to_a.map { |comment| comment.body } }
    assert_equal [EAGER_TODO_COMMENTS], @database.log
  end

  def test_eager_load_of_a_belongs_to_brings_the_parent_with_the_child
    @database.queue([
      { "p_id" => 10, "p_body" => "x", "p_todo_id" => 1, "p_created_at" => nil, "p_updated_at" => nil,
        "c0_id" => 1, "c0_title" => "a", "c0_done" => 0, "c0_priority" => "normal", "c0_position" => 1, "c0_created_at" => "t", "c0_updated_at" => "t" },
    ])
    comments = Comment.eager_load(:todo).to_a
    assert_equal ["a"], comments.map { |comment| comment.todo.title }
    assert_equal [EAGER_COMMENT_TODO], @database.log
  end

  def test_eager_load_of_an_unknown_association_is_refused
    error = assert_raise(ArgumentError) { Todo.eager_load(:ghosts).to_a }
    assert_equal "no association ghosts", error.message
    assert_equal [], @database.log
  end

  def test_eager_load_of_several_associations_gives_each_parent_each_child_once
    @database.queue([
      shelf_row(1, "s1", 10, 20), shelf_row(1, "s1", 10, 21),
      shelf_row(1, "s1", 11, 20), shelf_row(1, "s1", 11, 21),
      shelf_row(2, "s2", nil, 22),
      shelf_row(3, "s3", nil, nil),
    ])
    shelves = Shelf.where(name: "x").limit(3).eager_load(:books, :pens).to_a
    assert_equal [EAGER_SHELF_BOOKS_PENS], @database.log
    assert_equal "[[10, 11], [], []]", shelves.map { |shelf| shelf.books.to_a.map { |book| book.id } }.inspect
    assert_equal "[[20, 21], [22], []]", shelves.map { |shelf| shelf.pens.to_a.map { |pen| pen.id } }.inspect
    assert_equal [EAGER_SHELF_BOOKS_PENS], @database.log
  end

  def test_eager_load_keeps_the_same_child_id_of_two_associations
    @database.queue([shelf_row(1, "s1", 10, 10)])
    shelf = Shelf.eager_load(:books, :pens).to_a[0]
    assert_equal "[10]", shelf.books.to_a.map { |book| book.id }.inspect
    assert_equal "[10]", shelf.pens.to_a.map { |pen| pen.id }.inspect
    assert_equal 1, @database.log.size
  end

  def test_eager_load_gives_each_child_the_parent_they_share
    todo_columns = { "c0_id" => 1, "c0_title" => "a", "c0_done" => 0, "c0_priority" => "normal", "c0_position" => 1, "c0_created_at" => "t", "c0_updated_at" => "t" }
    first = { "p_id" => 10, "p_body" => "x", "p_todo_id" => 1, "p_created_at" => nil, "p_updated_at" => nil }
    second = { "p_id" => 11, "p_body" => "y", "p_todo_id" => 1, "p_created_at" => nil, "p_updated_at" => nil }
    @database.queue([first.merge(todo_columns), second.merge(todo_columns)])
    comments = Comment.eager_load(:todo).to_a
    assert_equal ["a", "a"], comments.map { |comment| comment.todo.title }
    assert_equal "[1, 1]", comments.map { |comment| comment.todo.id }.inspect
    assert_equal [EAGER_COMMENT_TODO], @database.log
  end

  def test_eager_load_joins_a_has_many_on_its_primary_key
    @database.queue([{ "p_id" => 4, "p_uid" => "u-1", "p_name" => "a", "c0_id" => 8, "c0_account_uid" => "u-1" }])
    accounts = Account.eager_load(:logins).to_a
    assert_equal [EAGER_ACCOUNT_LOGINS], @database.log
    assert_equal "[8]", accounts[0].logins.to_a.map { |login| login.id }.inspect
    assert_equal [EAGER_ACCOUNT_LOGINS], @database.log
  end

  def test_eager_load_joins_a_has_many_on_its_foreign_key
    Account.eager_load(:memberships).to_a
    assert_equal [EAGER_ACCOUNT_MEMBERSHIPS], @database.log
  end

  def test_eager_load_joins_a_belongs_to_on_the_parents_primary_key
    @database.queue([{ "p_id" => 2, "p_owner_uid" => "u-1", "c0_id" => 4, "c0_uid" => "u-1", "c0_name" => "a" }])
    devices = Device.eager_load(:account).to_a
    assert_equal [EAGER_DEVICE_ACCOUNT], @database.log
    assert_equal "a", devices[0].account.name
    assert_equal [EAGER_DEVICE_ACCOUNT], @database.log
  end

  def test_chained_eager_loads_accumulate_and_join_a_repeated_name_once
    Shelf.eager_load(:books).eager_load(:pens, :books).to_a
    assert_equal [EAGER_SHELF_CHAINED], @database.log
  end

  def test_eager_load_of_a_belongs_to_and_a_has_many_together
    @database.queue([
      { "p_id" => 10, "p_shelf_id" => 1, "c0_id" => 1, "c0_name" => "s1", "c1_id" => 100, "c1_book_id" => 10 },
      { "p_id" => 10, "p_shelf_id" => 1, "c0_id" => 1, "c0_name" => "s1", "c1_id" => 101, "c1_book_id" => 10 },
      { "p_id" => 11, "p_shelf_id" => nil, "c0_id" => nil, "c0_name" => nil, "c1_id" => nil, "c1_book_id" => nil },
    ])
    books = Book.eager_load(:shelf, :pages).to_a
    assert_equal [EAGER_BOOK_SHELF_PAGES], @database.log
    assert_equal "s1", books[0].shelf.name
    assert_equal "[[100, 101], []]", books.map { |book| book.pages.to_a.map { |page| page.id } }.inspect
    assert_equal [EAGER_BOOK_SHELF_PAGES], @database.log
  end

  def test_eager_load_names_every_unknown_association
    error = assert_raise(ArgumentError) { Shelf.eager_load(:books, :ghosts).to_a }
    assert_equal "no association ghosts", error.message
    assert_equal [], @database.log
  end

  def test_build_copies_the_equality_conditions_only
    relation = Todo.where(position: 3, priority: "high").where(id: [9, 10]).where(position: 1..5).where("title = ?", "q")
    record = relation.build(title: "b")
    assert_equal "[3, \"high\", \"b\", nil]", [record.position, record.priority, record.title, record.id].inspect
  end

  def test_build_does_not_copy_a_list_of_values
    record = Todo.where(position: [7]).where(priority: ["low"]).build
    assert_equal "[nil, \"normal\"]", [record.position, record.priority].inspect
  end
end
