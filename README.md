# Edgeway

A library for running Ruby compiled to wasm by Spinel on Edge Workers.

```ruby
# config/routes.rb
Edgeway.application.routes.draw do |r|
  r.resources :todos, only: [:index, :show, :create] do |t|
    t.resources :comments, only: [:index, :create]
  end
  r.get "/health", to: "health#show"
end

# app/models/application_model.rb
class ApplicationModel < Edgeway::Model::Base
  extend Edgeway::Model::Macros
end

# app/models/todo.rb
class Todo < ApplicationModel
  attribute :title, :string
  attribute :done, :boolean, default: false
  timestamps
  has_many :comments
  validates :title, presence: true, length: { maximum: 200 }
end

# app/controllers/todos_controller.rb
class TodosController < ApplicationController
  def index = render json: Todo.order(:id).limit(50)

  def create
    todo = Todo.create!(params.require(:todo).permit(:title, :done))
    render json: todo, status: :created
  end
end
```

## Contents

- [Models](#models)
  - [Attribute types](#attribute-types)
  - [Strong parameters](#strong-parameters)
  - [Uniqueness](#uniqueness)
  - [Database errors](#database-errors)
  - [Ordering and deleting](#ordering-and-deleting)
  - [Queries](#queries)
  - [Batch](#batch)
  - [Associations](#associations)
  - [Eager loading](#eager-loading)
  - [Multiple databases](#multiple-databases)
  - [Read replication (Sessions)](#read-replication-sessions)
  - [D1 API coverage](#d1-api-coverage)
- [Views](#views)
- [Usage](#usage)
  - [Generators](#generators)
  - [Building](#building)
  - [Spinel version](#spinel-version)
  - [Known limitations](#known-limitations)
- [Configuration](#configuration)
- [Authentication](#authentication)
- [CORS](#cors)
- [Testing an app](#testing-an-app)
- [Development](#development)
- [License](#license)

## Models

### Attribute types

| Type | Ruby value | SQLite column | In JSON |
| --- | --- | --- | --- |
| `:string`, `:text` | String | TEXT | string |
| `:integer` | Integer (32 bits) | INTEGER | number |
| `:float` | Float | REAL | number |
| `:boolean` | `true`/`false` | INTEGER (1/0) | `true`/`false` |
| `:datetime` | String, ISO 8601 UTC | TEXT | string |
| `:binary` | binary String (`.b`) | BLOB | base64 string |
| `:bigint` | decimal String (`"3000000000"`) | INTEGER | string |

- Integers are 32 bits in a wasm build. A `:integer` value beyond -2147483648..2147483647 casts to `nil`; use `:bigint` for those columns.
  Assigning one is refused by validation ("is out of range"). A row that already holds one (a foreign key to a bigint parent
  declared as `:integer`) loads as `nil`, and saving it fails the same way instead of writing `NULL` over it.
- A `:bigint` holds its value as a String of an optional `-` and digits, without leading zeros (`"-0"` is `"0"`);
  anything else, or a value beyond 64 bits, casts to `nil` ("is invalid"). It is bound as text and SQLite's INTEGER affinity
  stores it as an integer, so `where`, `order` and comparisons work on the number.
  It renders in JSON as a String, which JavaScript clients read exactly.
  D1 hands rows over as JavaScript numbers, so a value beyond 2^53 (9007199254740991) has already lost precision before Ruby sees it.
  Keep such values below 2^53, or store them as `:string`.
- Pass bigint values as Strings: `Todo.find("3000000000")`, `where(id: "3000000000")`, `create!(owner_id: "5000000000")`,
  `Model.execute("... WHERE id = ?", ["3000000000"])`. A Hash holding an Integer literal beyond 32 bits raises `RangeError` in a wasm build
  (a Spinel limitation), so do not write them as Integers.
- `attribute :id, :bigint` makes the primary key a bigint: `find`, `where(id: ...)`, `update`, `destroy` and an insert
  (`RETURNING id`) work past 2^31, and `id` is a String. A foreign key to it is `attribute :owner_id, :bigint`
  (declare it before `belongs_to` and it keeps its type).
- Rows from raw SQL (`Model.select_all`) hold what the database gave: in a wasm build an INTEGER beyond 32 bits is a Bignum,
  and `render json:` of it raises. Select it as text (`SELECT CAST(id AS TEXT) AS id ...`) or pass it through `Edgeway::Model.cast(:bigint, value)`.
- A `:binary` attribute holds a binary String. Assigned from Ruby, a String keeps its bytes (`Document.new(body: bytes)`), and so does a `{"$blob" => base64}` Hash.
  It is bound as a BLOB (`where(body: bytes)` too), and renders in JSON as a base64 String.
  In a request body the value is that base64 String, so a GET then PATCH round trip is stable: params assigned through `permit` are decoded,
  and invalid base64 fails validation ("is invalid"). `{"$blob": ...}` objects are not supported in a request body (nested objects are dropped).
  `presence` counts a binary String blank only when empty, and `length` counts bytes.
  A BLOB crosses between wasm and JS as `{"$blob": "<base64>"}`, as raw bytes would be cut at a NUL.
  In raw SQL (`Model.select_all`, `Model.execute`, `where("...", value)`) bind a BLOB with `Edgeway::Model.blob(bytes)`,
  and a BLOB column comes back as `{"$blob" => base64}`.
- `Model.execute` answers `"last_insert_id"` as an Integer, or as a decimal String when the rowid is beyond 32 bits.

### Strong parameters

Params must go through `permit` before a model takes them.

`Todo.new`, `create`, `update` and their bang forms raise `Edgeway::ForbiddenAttributes`
(a 500, the details only in the log) for `params` or for `params.require(:todo)` alone.
A Hash is assigned as is.

### Uniqueness

```ruby
# Unique per owner, as UNIQUE (owner_id, name) in the table:
class Project < ApplicationModel
  attribute :owner_id, :string
  attribute :name, :string
  # scope: a Symbol or an Array
  validates :name, presence: true, uniqueness: { scope: :owner_id }
end

# The record if there is one, else a new saved one
# (find_or_create_by! raises RecordInvalid instead of answering the unsaved record).
# It also works on a relation, which sets owner_id too.
Project.where(owner_id: uid).find_or_create_by(name: "default")
```

`uniqueness:` is a query, so two requests can both pass it. What guarantees it is the table's `UNIQUE` index:

- A write it refuses raises `Edgeway::RecordNotUnique` (a `DatabaseError`),
  which `find_or_create_by` handles by finding the row the other request made.
- Left alone, it is answered 409 `{"error":"record not unique"}`;
  the database's message (table and columns) goes only to the log.
- A controller can `rescue_from Edgeway::RecordNotUnique` to answer otherwise.

### Database errors

All are `Edgeway::DatabaseError`; the database's message goes only to the log.

- `NotNullViolation`, `InvalidForeignKey` and `CheckViolation` (a constraint the app broke):
  answered 500 `{"error":"internal error"}`, like any other `DatabaseError`.
- `DatabaseUnavailable` (D1 lost its connection, was reset or is overloaded):
  answered 503 `{"error":"database unavailable"}` with `Retry-After: 1`.
- A controller can `rescue_from` any of them to answer otherwise.
  `rescue_from Edgeway::DatabaseError` also catches `DatabaseUnavailable` and `RecordNotUnique`,
  so it replaces their default 503 and 409.
- D1 retries read-only queries itself. Edgeway never retries a query, a write or a batch.
- A write that got a 503 may still have been applied:
  only an idempotent request (a GET, or a write the app made idempotent) is safe to retry.
- Timeouts and CPU or memory limits stay a plain `DatabaseError` (500).

### Ordering and deleting

```ruby
# order adds terms, reorder replaces them: ORDER BY updated_at DESC, id DESC
Todo.order(:updated_at, :desc).order(:id, :desc)
Todo.order(:title).reorder(:id)

# One DELETE (no records, no dependents); the number of rows deleted.
# limit/offset raise ArgumentError.
Todo.where(done: true).delete_all

# Loads the records and destroys each, so dependents run; the destroyed records.
Todo.where(done: true).destroy_all

# destroy deletes the comments first
# (dependent: :destroy runs their own dependents; :delete_all is one DELETE).
# The comments' SELECTs run at once and all the DELETEs go in one Model.batch (below),
# so it is atomic.
class Todo < ApplicationModel
  has_many :comments, dependent: :destroy
end
```

### Queries

```ruby
Todo.where(id: [1, 2])                    # id IN (?, ?)
Todo.where(position: 1..5)                # position >= ? AND position <= ?
Todo.where(position: (3..))               # position >= ?
Todo.where("title LIKE ?", "%x%")         # (title LIKE ?)
Todo.where("done = 1")

Todo.find_by_sql("SELECT * FROM todos WHERE done = ?", [true])   # records
Edgeway::Model.select_all("SELECT COUNT(*) AS n FROM todos", [])  # row Hashes
Edgeway::Model.execute("DELETE FROM todos WHERE done = ?", [true]) # {"changes" => n, "last_insert_id" => id}
Edgeway::Model.exec("DELETE FROM tags\nDELETE FROM todos")        # nil
```

- `where(column: value)` is `=`, `IS NULL` for `nil`. Every form chains, and works with `order`, `limit`, `count`, `delete_all`, `eager_load` and `todo.comments.where(...)`.
- An Array is `IN`; each value is cast by the column type. An empty Array matches nothing (`1 = 0`).
  A `nil` in an Array also matches `NULL`: `(position IN (?) OR position IS NULL)`.
- A Range is `>=` and `<=` (`<` for `1...5`); an endless or beginless Range has one side.
  Spinel can't build a Range of Times: use ISO 8601 Strings (`"2026-10-28"..."2026-10-29"`) or a fragment.
- A String is a raw SQL fragment, in parentheses and ANDed with the rest; its binds follow it.
  It is raw SQL: put user input in the binds, never interpolate it.
  Its binds are not cast by column type: only booleans (1/0) and Times (ISO 8601) are converted.
  An Array bind raises `ArgumentError` (not expanded): use `where(column: [...])`.
- `build`/`create`/`find_or_create_by` on a relation copy only the plain equality conditions.
- `find_by_sql` makes records of the rows, so select the model's columns (`SELECT *` or each of them): a missing one is `nil`.
- `Model.select_all` and `Model.execute` take `?` placeholders. Booleans are bound as 1/0, and a Time as ISO 8601 UTC (`2026-10-28T05:00:00.000Z`, as timestamps are stored), also in `where` values.
  `execute` is a write, so inside `Model.batch` it is queued (and answers 0 counts).
- `Model.exec` is D1's `exec()`: one or more statements with no binds, and it answers `nil`. Meant for one-off maintenance, as D1 says.
  A statement must fit on one line (D1 splits the text at newlines); `a; b` on one line also works. Empty SQL raises `ArgumentError`.
  When a statement fails, none of them stay applied (seen on local D1; the SQLite adapter in tests does the same).
  D1's error message names the first line, not the one that failed.
  It can't run inside `Model.batch` (`ArgumentError`), and fails on a database with `sessions: true` (`DatabaseError`): a D1 session has no `exec()`.
- D1 allows 100 bound parameters per statement: more raises `ArgumentError`, in every adapter (`limit` and `offset` are literals, not binds).
  `where(id: ids)` with over 100 ids needs chunking.

### Query stats

`Edgeway::Model.query_stats` (it raises `ConfigurationError` without a connection) is what D1 reported for the queries of the current request
(a wasm instance serves one request, so it starts at zero):

- `queries`: the number of successful D1 calls (a `Model.batch` is one). A failed call and its time are not counted.
- `rows_read`, `rows_written`: the sums of D1's `meta`, capped at 2147483647 (32-bit; the log line shows a capped count with a trailing `+`).
- `duration_ms` (Float): the sum of D1's `meta.duration`.
- `served_by_region` and `served_by_primary`: from the last call (`""` and `true` when D1 doesn't say, as in `wrangler dev`).

When a request ran any query, `Edgeway::Server` logs one line after it, also for a request that raised and was rescued:

```
[edgeway] db=3 rows_read=12 rows_written=1 db_ms=2.46
```

The Memory and SQLite adapters report zeros and log nothing.

### Batch

`Edgeway::Model.batch` makes several writes atomic.

D1 has no interactive transactions, but its `batch()` runs a list of statements as one SQL transaction,
so the writes in the block are queued and sent together at the end:
all of them are applied, or none (a failure raises, such as `RecordNotUnique`).
It answers the results, one `{"changes" => n, "last_insert_id" => id}` per write.

```ruby
Edgeway::Model.batch do
  from.update!(balance: from.balance - 10)
  to.update!(balance: to.balance + 10)
  Transfer.where(expired: true).delete_all
end
```

- Only writes (`update`, `destroy`, `delete_all`) are in the batch. Reads run at once and don't see the queued writes.
- A `create` is refused with `ArgumentError`, because it needs the new row's id.
- The counts of a queued write are not known (`delete_all` answers 0).
- A block that raises sends nothing, and a nested `batch` joins the outer one.

### Associations

`has_many` and `belongs_to` take `foreign_key:` and `primary_key:` for columns
that don't follow the `todo_id` / `id` convention.

- `has_many` uses `foreign_key:` on the other model and `primary_key:` on this one.
- `belongs_to` uses `foreign_key:` on this model and `primary_key:` on the parent.

A foreign key is an integer unless you declare it first, which is how to make a String one:

```ruby
class Device < ApplicationModel
  attribute :owner_uid, :string   # declared first, so it stays a String
  belongs_to :account, foreign_key: :owner_uid, primary_key: :uid
end

class Account < ApplicationModel
  attribute :uid, :string
  has_many :devices, foreign_key: :owner_uid, primary_key: :uid, dependent: :destroy
end
```

### Eager loading

`eager_load(:name, ...)` loads one or more `has_many` or `belongs_to` for the whole list with one query,
always a `LEFT JOIN` per association (there is no separate preload query).
Calls accumulate (`eager_load(:a).eager_load(:b)` is `eager_load(:a, :b)`).
It chains with `where`, `order` and `limit`, which apply to the model's own records:

```ruby
Todo.where(done: false).order(:id).limit(20).eager_load(:comments).each do |todo|
  todo.comments.to_a   # from memory, no query
end

Todo.eager_load(:comments, :tags)   # several at once, still one query
```

- Joining two `has_many` repeats rows per parent; each parent still gets each child once, in id order.
- An unknown name raises `ArgumentError`.
- Only `to_a` and what is built on it (`each`, `map`, `size`) read the loaded records;
  `comments.where(...)`, `count` and `first` query as usual.

### Multiple databases

A model uses the primary database unless it names another, declared in `config/database.yml` (see "Configuration"):

```ruby
class Event < ApplicationModel
  self.database = :analytics   # inherited by subclasses
  attribute :name, :string
end

Event.create!(name: "signup")
Edgeway::Model.select_all("SELECT COUNT(*) AS n FROM events", [], database: :analytics)
Edgeway::Model.execute("DELETE FROM events", [], database: :analytics)
```

- Every query and write of a model goes to its database, including `find_by_sql`.
  `Model.select_all` and `Model.execute` use the primary unless given `database:`.
- Associations between models on different databases work as separate queries.
  A `has_many` with `dependent:` to a model on another database raises `ArgumentError` on `destroy`, before any query: it can't be atomic.
  `eager_load` across databases raises `ArgumentError`: a `JOIN` can't cross them.
- A `Model.batch` belongs to the database of its first write; a write for another one raises `ArgumentError`
  (D1 batches are per database). Use one `batch` per database.
- `Edgeway::Model.query_stats(:analytics)` is that database's stats. The request log has one line per database that ran queries,
  and the extra ones start with `database=analytics`.

### Read replication (Sessions)

With D1 read replication enabled for a database (dashboard, or `PUT` its settings), reads can be served by a replica near the user.
A replica may lag, so D1's Sessions API keeps a request sequentially consistent through a bookmark. Opt in per database in `config/database.yml`:

```yaml
production:
  adapter: d1
  binding: DB
  sessions: true
  databases:
    analytics:
      binding: ANALYTICS
      sessions: true
```

`sessions:` must be `true` or `false` (anything else fails the build), and does nothing with the `memory` adapter.
Every query and `Model.batch` of such a database then goes through `env.DB.withSession(...)`, created on first use and kept for the request.

- A `GET` or `HEAD` starts `first-unconstrained`, so it may read a replica. Other methods start `first-primary`.
- The response has `X-D1-Bookmark: DB=<bookmark>, ANALYTICS=<bookmark>`: a `BINDING=bookmark` pair for each session the request used (also with one database).
- A client that sends that header back as it is on its next request starts that session from the bookmark and so reads its own writes. A binding that is not in the header starts from the constraint above. A bookmark is D1's and opaque; one that does not look like it (not lowercase hex and `-`, or over 128 characters) is ignored, and not echoed.
- A database the request did not use keeps the bookmark the client sent for it in the response, so the client just stores the latest header value whole and sends it back.
- Responses of an app with sessions get `Vary: X-D1-Bookmark`.
- With CORS on, `X-D1-Bookmark` is exposed to the page and allowed in preflights (no need to add it to `CORS_HEADERS` or `CORS_EXPOSE_HEADERS`).
- `Edgeway::Model.query_stats(:analytics)` has `served_by_primary` and `served_by_region` of the last query, to see which one answered (`true` and `""` in `wrangler dev`, which has no replicas).

### D1 API coverage

| D1 Worker API | In Edgeway |
| --- | --- |
| `prepare().bind().all()` | every query, `find_by_sql`, `Model.select_all`, and inserts (`INSERT ... RETURNING id`) |
| `prepare().bind().run()` | updates and deletes, `Model.execute` |
| `batch()` | `Model.batch` (and `destroy` with dependents) |
| `exec()` | `Model.exec` |
| `withSession()`, `getBookmark()` | `sessions: true` ([Read replication](#read-replication-sessions)) |
| `result.meta` | `Model.query_stats` and the `db=…` log line |
| `first()`, `raw()` | not used: `find_by`/`first` send `LIMIT 1` through `all()`, which also keeps `meta`; `raw()` made the JSON smaller but rebuilding the rows in Ruby cost as much as it saved |
| `dump()` | not supported (alpha databases only) |

Time Travel, export/import and migrations are `wrangler d1` commands, outside the Worker API.

## Views

```ruby
# app/controllers/todos_controller.rb
class TodosController < ApplicationController
  def index
    @todos = Todo.order(:id).limit(50)
    # renders app/views/todos/index.html.erb
  end
end
```

```erb
<%# app/views/todos/index.html.erb %>
<ul>
<% @todos.each do |t| -%>
  <li><%= t.title %></li>
<% end -%>
</ul>
```

Spinel has no `eval`, so `edgeway build` (and `edgeway test`) compile `app/views/**/*.html.erb` into Ruby
(`build/views.rb`, `tmp/views.rb`): each template becomes a method of its controller,
so it sees the action's `@variables`, `params` and the controller's methods.

- `<%= expr %>` is HTML-escaped (`Edgeway::View.escape`), `<%== expr %>` is not.
  `<% code %>`, `<%# comment %>`, `<%%` (a literal `<%`) and `-%>` (drops the newline after the tag) work as in ERB.
- An action that renders nothing renders its template, or answers 204 when it has none.
- `render :name` / `render "name"` renders another template of the controller, `render html: text` a string;
  both take `status:` and `layout: false`.
  A name with no template raises `Edgeway::MissingTemplate` (a 500).
- `app/views/layouts/application.html.erb` wraps every HTML response, at `<%= yield %>`. `edgeway new` writes one.
- HTML responses are `Content-Type: text/html; charset=utf-8` with `X-Content-Type-Options: nosniff`.
- A template's directory names its controller (`app/views/admin/posts/` is `Admin::PostsController`);
  one without a controller is a build error, and so is a syntax error in a template,
  which Spinel reports in the generated file (its `# app/views/...:LINE` comments point back).

Not supported yet: partials (`render partial:`), layouts other than `application`, and templates other than `.html.erb`.

## Usage

```sh
gem install edgeway

edgeway new myapp

# mise, bundle, pnpm and the local D1 migrations
cd myapp && bin/setup

# the app's tests, natively (needs libsqlite3-dev, see "Testing an app")
bundle exec edgeway test        # or bin/test [FILE...] in a generated app

# edgeway build: writes build/app.wasm and build/edgeway/ (the JS).
# A development build: Spinel's --incremental caches the generated C in units,
# so a rebuild recompiles only what changed (no inlining across units)
bin/build

pnpm exec wrangler dev
edgeway routes

# bin/build --release (one unit, without --incremental), remote D1 migrations,
# then pnpm exec wrangler deploy
bin/deploy
```

`edgeway` commands: `new`, `build`, `test`, `generate` (`g`), `routes`, `version` (`edgeway help` lists them).

Before `bin/deploy`:

1. Log in (`pnpm exec wrangler login`).
2. Create the D1 database (`pnpm exec wrangler d1 create <name>-db`).
3. Put its `database_id` in `wrangler.toml`.

`bin/setup` prints these steps when they are missing.

- A generated app's Gemfile takes `edgeway` and `spinel_test-unit` from RubyGems.
- A generated app's `.github/workflows/ci.yml` installs libsqlite3-dev, Ruby (from `.ruby-version`, which `edgeway new` writes with the Ruby that ran it), and mise's tools, then runs `bin/test` and `bin/build --release`.
- An app uses [pnpm](https://pnpm.io/) for wrangler (`package.json`, `bin/setup`, `mise.toml`);
  `edgeway new` names it in one place (`Edgeway::CLI::PackageManager`).
- `SPINEL=/path/to/spinel bin/build` uses a Spinel other than the one on `PATH`.
- `bin/deploy` applies pending remote D1 migrations (`wrangler d1 migrations apply <name>-db --remote`) before deploying.

### Generators

Inside an app made by `edgeway new`, `edgeway generate` (or `edgeway g`) writes the files and never overwrites one:

```sh
# app/models/todo.rb, db/migrations/0001_create_todos.sql, test/models/todo_test.rb
edgeway generate model Todo title:string done:boolean

# app/controllers/todos_controller.rb, test/controllers/todos_test.rb
edgeway generate controller Todos index show

# the model's files, a JSON API controller (index, show, create, update, destroy) and its test
edgeway generate scaffold Todo title:string done:boolean
```

- Field types are `string` (the default), `text`, `integer`, `float`, `boolean` and `datetime`.
- A model gets `timestamps` and an `id`, `created_at` and `updated_at` column.
- The migration is numbered one above the highest in `db/migrations`.
- Each action of a controller is a stub that renders `{}`.
- `config/routes.rb` is not changed by `model` and `controller`: the command prints the route to add (`r.resources :todos`).
- `model` and `scaffold` stop if a `db/migrations/*_create_todos.sql` already exists (a rerun would add a second table).
- `scaffold` singularizes its name (`scaffold Todos` is `Todo`), checks that none of its files exist before it writes one, and adds `r.resources :todos` as the last line of the `routes.draw` block, so that it does not shadow an earlier `/todos/search`. It leaves a route that is already there alone, and prints the route and the reason instead if there is no `routes.draw do |r|` block with a closing `end`.
- The scaffold's controller permits the given fields (`params.require(:todo).permit(...)`), and with no fields it takes no params.

### Building

`edgeway build` needs Spinel and the WASI SDK.

- An app made by `edgeway new` has a `mise.toml` for both (`mise install`):
  Spinel comes from the [mise-spinel](https://github.com/y-yagi/mise-spinel) plugin and is put on `PATH`,
  and the WASI SDK is pointed at by `WASI_SDK`.
- Without mise, set `SPINEL` (or put `spinel` on `PATH`) and `WASI_SDK`.
- `SPINEL` wins over `spinel` on `PATH`, which is how to use a Spinel checkout instead of a release.

See `todo-api` in [edgeway-examples](https://github.com/y-yagi/edgeway-examples) for an example (checked with its `check.sh`).

### Spinel version

Edgeway needs a Spinel newer than the 2026.09.12 release
(that release refuses `send` with a computed name, which `Callbacks#run_before_actions` uses).

- `mise.toml` (Edgeway's own and the one `edgeway new` writes) pins a commit of [matz/spinel](https://github.com/matz/spinel),
  `ec0ad13e4`, which mise-spinel builds from source.
  A commit rather than `master`, so that an install is the Spinel that was tested.
- The WASI SDK (`wasi-sdk-34`) is installed first,
  because mise-spinel builds Spinel's wasm32-wasi runtime only when it finds one.
- Changing the pin means re-running `rake test` and `todo-api/check.sh` in [edgeway-examples](https://github.com/y-yagi/edgeway-examples).

### Known limitations

- Only the subset of Ruby that Spinel supports can be used.
- `has_many` does not work with namespaced models (`Admin::Post`);
  `belongs_to` and `has_many` look models up by their full name, and that case is not handled.
- Cloudflare Access is not supported in this release: its token comes in `Cf-Access-Jwt-Assertion`,
  and only `Authorization: Bearer` is read (see [Authentication](#authentication)).
- Tests run natively, not in wasm: D1 and JSPI (`Edgeway::Cloudflare::JWTVerifier`) are not covered by them,
  and the production wasm never loads the SQLite adapter (see [Testing an app](#testing-an-app)).
- Not verified on a production Cloudflare deploy yet: CPU and wall time on a cold start and on a JWKS cache miss.
  Everything was checked under `wrangler dev`.

## Configuration

Two files configure the database, each for its own side:

- `config/database.yml` is Edgeway's: for each environment (`edgeway build --env ENV`),
  the adapter (`d1`, or `memory` for tests) and the name of the D1 binding the app uses. It is compiled into the wasm.
- `wrangler.toml` is Cloudflare's: which D1 database the binding is (`database_name`, `database_id`),
  the migrations, and the Worker. `binding` in it must match `binding` in `config/database.yml`.

Another database goes under `databases:` of an environment, with its own binding in `wrangler.toml`:

```yaml
production:
  adapter: d1
  binding: DB
  databases:
    analytics:
      binding: ANALYTICS
```

Its migrations are in `db/analytics/migrations` (`migrations_dir` of its `[[d1_databases]]`; apply them per database).
A name is lowercase letters, digits and `_`, and not `primary`; `binding:` is required.
The extra databases use the environment's adapter.
`sessions: true` next to `binding:` (in the environment for the primary, in the entry for another) turns on D1 Sessions for it; see "Read replication (Sessions)".

`database_id` is not a secret: it only names the database, and using it takes an API token of the account,
so it is committed with `wrangler.toml` as Cloudflare's own examples do.
Secrets the app needs go in Worker secrets (`pnpm exec wrangler secret put NAME`),
which the app reads with `Edgeway.config("NAME")`.

Not every Worker variable reaches the app. Only these are passed into the wasm:

- the framework's own settings (`JWT_ISSUER`, `JWT_AUDIENCE`, `JWT_LEEWAY`, `JWT_ALGORITHMS`, `JWT_JWKS_URL`)
- the variables whose name starts with `APP_`

Name your own settings `APP_...` (`APP_PAGE_SIZE = "20"` in `[vars]`, `Edgeway.config("APP_PAGE_SIZE", "20")` in Ruby),
and likewise your secrets (`wrangler secret put APP_NAME`).
Anything else, such as a key the Worker holds for another purpose, is never visible to the app.
`JWT_SECRET` is never passed.

## Authentication

Edgeway verifies JWTs that an external IdP issued (Auth0, Firebase, Cognito, ...) and that come in `Authorization: Bearer`;
it does not issue them.

- Cloudflare Access, which sends its token in `Cf-Access-Jwt-Assertion`, is not supported in the first release,
  nor are Cognito access tokens, which carry `client_id` instead of `aud` (Cognito ID tokens work).
- `sub` is required and must be a non-empty string.
- `auth_time`, when present, must not be in the future (leeway applies).

The signature is checked in JS with WebCrypto, the claims in Ruby:

```ruby
class ApplicationController < Edgeway::Controller::Base
  before_action :authenticate!   # or only: / except:
end

class MeController < ApplicationController
  def show = render json: current_claims   # the token's payload, a Hash
end
```

Without a valid `Authorization: Bearer <token>`, the request is answered 401 with a fixed body:

- no token: `{"error":"authentication required"}` with `WWW-Authenticate: Bearer` (`Edgeway::Unauthorized`)
- a bad token: `{"error":"invalid token"}` with `WWW-Authenticate: Bearer error="invalid_token"` (`Edgeway::InvalidToken`)

`rescue_from` them to answer differently.
The reason ("token expired", "unknown kid", ...) is only in the log (stderr), never the token,
so a client learns nothing from the wording.

Settings are Worker variables in `wrangler.toml`, and the secret is a Worker secret (`.dev.vars` locally):

| Variable | |
|---|---|
| `JWT_ALGORITHMS` | allowed algorithms, comma-separated (default `RS256`; `HS256/384/512`, `RS*`, `PS*`, `ES256/384`, `EdDSA`). `none` is never accepted |
| `JWT_JWKS_URL` | the IdP's JWKS, for the asymmetric algorithms. Must be `https` (`http` only for `localhost`, `127.0.0.1`, `[::1]`), otherwise the request is answered 500. Cached for 10 minutes, fetched again when a `kid` is unknown (at most every 30 seconds); an expired JWKS is never used, so when the fetch fails the answer is 500. The fetch has a 5 second timeout, follows no redirect, needs status 200 and a body of at most 64 KB. A token needs a `kid`; a JWK with `key_ops` must list `verify` |
| `JWT_SECRET` | the shared secret, for `HS*` (a secret; it never enters the wasm). At least 32 bytes for `HS256`, 48 for `HS384`, 64 for `HS512` (UTF-8 bytes, RFC 7518 3.2), otherwise the request is answered 500 |
| `JWT_ISSUER`, `JWT_AUDIENCE` | **required**: `iss` and `aud` of the token must match. If either is empty the request is answered 500 (a misconfiguration, details only in the log), never let through; a token without `iss` or `aud` is 401. Without them a token the IdP issued for another API would pass: Firebase's signing keys are shared by all Firebase projects (so any project's user token), and an Auth0 Management API token of the same tenant. Applies to every algorithm, `HS*` too |
| `JWT_LEEWAY` | seconds of clock skew allowed for `exp`, `nbf`, `iat` and `auth_time` (default 5; `0` for none; a whole number up to 300, anything else is answered 500) |

- `exp` is required, and a token with a `crit` header is refused (no extension is understood, RFC 7515 4.1.11).
- In tests, use `Edgeway::Auth::StubVerifier` (`edgeway/http/auth/stub`; see `test/auth.rb`).
- Like D1, this needs JSPI.
- An example is `GET /me` in `todo-api` of [edgeway-examples](https://github.com/y-yagi/edgeway-examples).

> **Note:** the todos/tags/comments endpoints of `todo-api` (in [edgeway-examples](https://github.com/y-yagi/edgeway-examples))
> are intentionally public, to keep the example small.
> A real app should `before_action :authenticate!` and scope records by the token's `sub`
> (for example an `owner_uid` attribute, queried with `where("owner_uid" => current_claims["sub"])` and set on create).
> See the comment in `todo-api/app/controllers/application_controller.rb`.

## CORS

A browser app on another origin needs CORS to call the API with `Authorization: Bearer`.
Edgeway does it in the Worker, before the app:

- A preflight (`OPTIONS` with `Origin` and `Access-Control-Request-Method`) is answered without starting the app,
  so it needs no `OPTIONS` routes.
- The headers are also added to responses the Worker makes itself (the 500 of a trap),
  so the browser sees the real status.

Settings are Worker variables in `wrangler.toml`:

| Variable | |
|---|---|
| `CORS_ORIGINS` | allowed origins, comma-separated, compared as exact strings with the request's `Origin` (`https://app.example, http://localhost:3000`; no trailing slash). `*` allows any origin. Unset or empty means CORS is off: nothing is added and `OPTIONS` goes to the app. The origin `null` (sandboxed iframes, `file:` pages) is never allowed, even with `*` |
| `CORS_HEADERS` | request headers a preflight allows (default `Authorization, Content-Type`). Listed one by one, as `*` does not cover `Authorization`. `X-D1-Bookmark` is added when a database has `sessions: true` |
| `CORS_MAX_AGE` | seconds a browser may cache a preflight (default `600`). Not a non-negative integer: every request is answered 500, as with a bad JWT setting |
| `CORS_EXPOSE_HEADERS` | response headers the page may read (`Access-Control-Expose-Headers`, e.g. `X-Total-Count`); none by default, except `X-D1-Bookmark` when a database has `sessions: true` (it is also merged into the app's own `Access-Control-Expose-Headers`) |

- A preflight from an allowed origin is answered 204 with `Access-Control-Allow-Origin` (the request's origin),
  `Access-Control-Allow-Methods` (`GET, HEAD, POST, PUT, PATCH, DELETE`), `Access-Control-Allow-Headers` and `Access-Control-Max-Age`.
- A preflight from another origin is 403 `{"error":"origin not allowed"}`.
- Other responses get `Access-Control-Allow-Origin` when the `Origin` is allowed, and `Origin` is added to `Vary`.
- Cookies (credentials) are not supported: `Access-Control-Allow-Credentials` is never sent,
  and a token that `fetch` puts in `Authorization` does not need it.

Serving the frontend from the same origin as the API avoids CORS altogether.

## Testing an app

```sh
bundle exec edgeway test [ARGS]   # ARGS go to spinel_test-unit
bin/test [FILE...]                # in a generated app: the same, all of test/ without FILE
```

`edgeway test` is the only supported way to run an app's tests.

- `spinel_test-unit` is the test framework (on RubyGems;
  `edgeway new` puts `gem "spinel_test-unit", "~> 0.1", group: :test` in the Gemfile).
- It rewrites `tmp/test_app.rb` (git-ignored; `build/` belongs to `edgeway build`) on every run,
  listing the app's files in build order, because Spinel resolves `require` at compile time.
  Running `spinel_test-unit` directly fails when that file is missing and uses a stale one when app files changed.

### Writing tests

- Tests `require "edgeway/test"` in `test/test_helper.rb`.
- Model tests inherit `Edgeway::UnitTest` (the database, no requests).
- `Edgeway::IntegrationTest` inherits it and adds `get`/`post`/..., `json` and `assert_response`.
- Both inherit `SpinelTest::Unit::TestCase`.

Each test runs against a real in-memory SQLite database (`Edgeway::DB::SQLiteAdapter`, through Spinel's FFI)
with `db/migrations/*.sql` applied in file name order, so requests really write and read rows.
Each database under `databases:` (in any environment) gets its own, with `db/NAME/migrations`; `db(:analytics)` answers it, and `db` the primary.

### SQLite

Running the tests requires SQLite (sqlite3). This needs the SQLite library at link time:
`libsqlite3-dev` on Debian/Ubuntu, `sqlite-devel` on Fedora (preinstalled on macOS).

- `edgeway test` first tries to link `-lsqlite3` with `$CC` (or `cc`/`gcc`/`clang`) and stops with the fix if that fails.
- Point `LIBRARY_PATH` at a directory holding `libsqlite3.so` if it lives elsewhere.
- Set `EDGEWAY_SKIP_PRECHECK=1` to skip the check.

Edgeway's own tests use `MemoryAdapter`, which stores nothing; `SQLiteAdapter` is Spinel-only (`test/spinel/*.rb`).

### Differences from production

The tests are native builds, while production is wasm32-wasi on Workers.

- D1 (`Edgeway::Cloudflare::D1Adapter`) and JSPI are not exercised,
  and neither is a JWT's signature check (use `Edgeway::Auth::StubVerifier`).
- `SQLiteAdapter` is loaded only by `edgeway/test`: `edgeway build` never requires `edgeway/db/sqlite`,
  because libsqlite3 can't be linked into the wasm.
- SQLite and D1 (itself SQLite) take the same SQL, but D1's own limits
  (such as the number of bound parameters) are not reproduced.

## Development

```sh
# mise install (Spinel, the WASI SDK) and bundle install
bin/setup

# needs libsqlite3-dev (test/spinel/sqlite.rb);
# runs test/*.rb under CRuby and as Spinel native builds, and compares with .expected
bundle exec rake test

# CRuby only
bundle exec rake test:cruby
```

CI runs `rake test` (both legs, the CLI and the JS tests) on Ubuntu and macOS, with Spinel from `mise.toml`.
To test against a Spinel checkout instead of the release, set `SPINEL` in a `mise.local.toml` (see `mise.toml`).

## License

MIT
