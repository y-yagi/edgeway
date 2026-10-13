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
  def create = render json: Todo.create!(params.require(:todo).permit(:title, :done)), status: :created
end
```

Params must go through `permit` before a model takes them: `Todo.new`, `create`, `update` and their bang forms raise `Edgeway::ForbiddenAttributes` (a 500, the details only in the log) for `params` or for `params.require(:todo)` alone. A Hash is assigned as is.

```ruby
# Unique per owner, as UNIQUE (owner_id, name) in the table:
class Project < ApplicationModel
  attribute :owner_id, :string
  attribute :name, :string
  validates :name, presence: true, uniqueness: { scope: :owner_id }   # scope: a Symbol or an Array
end

# The record if there is one, else a new saved one (find_or_create_by! raises RecordInvalid
# instead of answering the unsaved record). It also works on a relation, which sets owner_id too.
Project.where(owner_id: uid).find_or_create_by(name: "default")
```

`uniqueness:` is a query, so two requests can both pass it. What guarantees it is the table's `UNIQUE` index: a write it refuses raises `Edgeway::RecordNotUnique` (a `DatabaseError`), which `find_or_create_by` handles by finding the row the other request made. Left alone, it is answered 409 `{"error":"record not unique"}`; the database's message (table and columns) goes only to the log. A controller can `rescue_from Edgeway::RecordNotUnique` to answer otherwise.

```ruby
# order adds terms, reorder replaces them: ORDER BY updated_at DESC, id DESC
Todo.order(:updated_at, :desc).order(:id, :desc)
Todo.order(:title).reorder(:id)

# One DELETE (no records, no dependents); the number of rows deleted. limit/offset raise ArgumentError.
Todo.where(done: true).delete_all
# Loads the records and destroys each, so dependents run; the destroyed records.
Todo.where(done: true).destroy_all

# destroy deletes the comments first (dependent: :destroy runs their own dependents; :delete_all is one DELETE).
# The comments' SELECTs run at once and all the DELETEs go in one Model.batch (below), so it is atomic.
class Todo < ApplicationModel
  has_many :comments, dependent: :destroy
end
```

`Edgeway::Model.batch` makes several writes atomic. D1 has no interactive transactions, but its `batch()` runs a list of statements as one SQL transaction, so the writes in the block are queued and sent together at the end: all of them are applied, or none (a failure raises, such as `RecordNotUnique`). It answers the results, one `{"changes" => n, "last_insert_id" => id}` per write.

```ruby
Edgeway::Model.batch do
  from.update!(balance: from.balance - 10)
  to.update!(balance: to.balance + 10)
  Transfer.where(expired: true).delete_all
end
```

Only writes (`update`, `destroy`, `delete_all`) are in the batch. Reads run at once and don't see the queued writes. A `create` is refused with `ArgumentError`, because it needs the new row's id, and the counts of a queued write are not known (`delete_all` answers 0). A block that raises sends nothing, and a nested `batch` joins the outer one.

`has_many` and `belongs_to` take `foreign_key:` and `primary_key:` for columns that don't follow the `todo_id` / `id` convention. `has_many` uses `foreign_key:` on the other model and `primary_key:` on this one; `belongs_to` uses `foreign_key:` on this model and `primary_key:` on the parent. A foreign key is an integer unless you declare it first, which is how to make a String one:

```ruby
class Device < ApplicationModel
  attribute :owner_uid, :string                                 # declared first, so it stays a String
  belongs_to :account, foreign_key: :owner_uid, primary_key: :uid
end

class Account < ApplicationModel
  attribute :uid, :string
  has_many :devices, foreign_key: :owner_uid, primary_key: :uid, dependent: :destroy
end
```

## Usage

```sh
gem install edgeway                  # not published yet; use it with path: for now (see examples/todo-api/Gemfile)
edgeway new myapp
cd myapp && bin/setup                   # mise, bundle, pnpm and the local D1 migrations
bin/build                               # edgeway build: writes build/app.wasm and build/edgeway/ (the JS)
pnpm exec wrangler dev
edgeway routes
bin/deploy                              # bin/build, remote D1 migrations, then pnpm exec wrangler deploy
```

An app uses [pnpm](https://pnpm.io/) for wrangler (`package.json`, `bin/setup`, `mise.toml`); `edgeway new` names it in one place (`Edgeway::CLI::PackageManager`). `SPINEL=/path/to/spinel bin/build` uses a Spinel other than the one on `PATH`. `bin/deploy` applies pending remote D1 migrations (`wrangler d1 migrations apply <name>-db --remote`) before deploying.

### Generators

Inside an app made by `edgeway new`, `edgeway generate` (or `edgeway g`) writes the files and never overwrites one:

```sh
edgeway generate model Todo title:string done:boolean   # app/models/todo.rb, db/migrations/0001_create_todos.sql, test/models/todo_test.rb
edgeway generate controller Todos index show             # app/controllers/todos_controller.rb, test/controllers/todos_test.rb
```

Field types are `string` (the default), `text`, `integer`, `float`, `boolean` and `datetime`. A model gets `timestamps` and an `id`, `created_at` and `updated_at` column. The migration is numbered one above the highest in `db/migrations`. Each action of a controller is a stub that renders `{}`. `config/routes.rb` is not changed: the command prints the route to add (`r.resources :todos`).

`edgeway build` needs Spinel and the WASI SDK. An app made by `edgeway new` has a `mise.toml` for both (`mise install`): Spinel comes from the [mise-spinel](https://github.com/y-yagi/mise-spinel) plugin and is put on `PATH`, and the WASI SDK is pointed at by `WASI_SDK`. Without mise, set `SPINEL` (or put `spinel` on `PATH`) and `WASI_SDK`. `SPINEL` wins over `spinel` on `PATH`, which is how to use a Spinel checkout instead of a release. See `examples/todo-api` for an example (checked with its `check.sh`).

## Configuration

Two files configure the database, each for its own side:

- `config/database.yml` is Edgeway's: for each environment (`edgeway build --env ENV`), the adapter (`d1`, or `memory` for tests) and the name of the D1 binding the app uses. It is compiled into the wasm.
- `wrangler.toml` is Cloudflare's: which D1 database the binding is (`database_name`, `database_id`), the migrations, and the Worker. `binding` in it must match `binding` in `config/database.yml`.

`database_id` is not a secret: it only names the database, and using it takes an API token of the account, so it is committed with `wrangler.toml` as Cloudflare's own examples do. Secrets the app needs go in Worker secrets (`pnpm exec wrangler secret put NAME`), which the app reads with `Edgeway.config("NAME")`.

Not every Worker variable reaches the app: only the framework's own settings (`JWT_ISSUER`, `JWT_AUDIENCE`, `JWT_LEEWAY`, `JWT_ALGORITHMS`, `JWT_JWKS_URL`) and the variables whose name starts with `APP_` are passed into the wasm. Name your own settings `APP_...` (`APP_PAGE_SIZE = "20"` in `[vars]`, `Edgeway.config("APP_PAGE_SIZE", "20")` in Ruby), and likewise your secrets (`wrangler secret put APP_NAME`). Anything else, such as a key the Worker holds for another purpose, is never visible to the app. `JWT_SECRET` is never passed.

## Authentication

Edgeway verifies JWTs that an external IdP issued (Auth0, Firebase, Cognito, ...) and that come in `Authorization: Bearer`; it does not issue them. Cloudflare Access, which sends its token in `Cf-Access-Jwt-Assertion`, is not supported yet, nor are Cognito access tokens, which carry `client_id` instead of `aud` (Cognito ID tokens work). `sub` is required and must be a non-empty string; `auth_time`, when present, must not be in the future (leeway applies). The signature is checked in JS with WebCrypto, the claims in Ruby:

```ruby
class ApplicationController < Edgeway::Controller::Base
  before_action :authenticate!          # or only: / except:
end

class MeController < ApplicationController
  def show = render json: current_claims   # the token's payload, a Hash
end
```

Without a valid `Authorization: Bearer <token>`, the request is answered 401 with a fixed body: no token is `{"error":"authentication required"}` with `WWW-Authenticate: Bearer`, a bad token is `{"error":"invalid token"}` with `WWW-Authenticate: Bearer error="invalid_token"` (`Edgeway::Unauthorized`, `Edgeway::InvalidToken`; `rescue_from` them to answer differently). The reason ("token expired", "unknown kid", ...) is only in the log (stderr), never the token, so a client learns nothing from the wording. Settings are Worker variables in `wrangler.toml`, and the secret is a Worker secret (`.dev.vars` locally):

| Variable | |
|---|---|
| `JWT_ALGORITHMS` | allowed algorithms, comma-separated (default `RS256`; `HS256/384/512`, `RS*`, `PS*`, `ES256/384`, `EdDSA`). `none` is never accepted |
| `JWT_JWKS_URL` | the IdP's JWKS, for the asymmetric algorithms. Must be `https` (`http` only for `localhost`, `127.0.0.1`, `[::1]`), otherwise the request is answered 500. Cached for 10 minutes, fetched again when a `kid` is unknown (at most every 30 seconds); an expired JWKS is never used, so when the fetch fails the answer is 500. The fetch has a 5 second timeout, follows no redirect, needs status 200 and a body of at most 64 KB. A token needs a `kid`; a JWK with `key_ops` must list `verify` |
| `JWT_SECRET` | the shared secret, for `HS*` (a secret; it never enters the wasm). At least 32 bytes for `HS256`, 48 for `HS384`, 64 for `HS512` (UTF-8 bytes, RFC 7518 3.2), otherwise the request is answered 500 |
| `JWT_ISSUER`, `JWT_AUDIENCE` | **required**: `iss` and `aud` of the token must match. If either is empty the request is answered 500 (a misconfiguration, details only in the log), never let through; a token without `iss` or `aud` is 401. Without them a token the IdP issued for another API would pass: Firebase's signing keys are shared by all Firebase projects (so any project's user token), and an Auth0 Management API token of the same tenant. Applies to every algorithm, `HS*` too |
| `JWT_LEEWAY` | seconds of clock skew allowed for `exp`, `nbf` and `iat` (default 5; `0` for none) |

`exp` is required, and a token with a `crit` header is refused (no extension is understood, RFC 7515 4.1.11). In tests, use `Edgeway::Auth::StubVerifier` (`edgeway/http/auth/stub`; see `test/auth.rb`). Like D1, this needs JSPI. The design is in `docs/jwt-auth.md` and an example is `GET /me` in `examples/todo-api`.

> **Note:** the todos/tags/comments endpoints of `examples/todo-api` are intentionally public, to keep the example small. A real app should `before_action :authenticate!` and scope records by the token's `sub` (for example an `owner_uid` attribute, queried with `where("owner_uid" => current_claims["sub"])` and set on create). See the comment in `examples/todo-api/app/controllers/application_controller.rb`.

## CORS

A browser app on another origin needs CORS to call the API with `Authorization: Bearer`. Edgeway does it in the Worker, before the app: a preflight (`OPTIONS` with `Origin` and `Access-Control-Request-Method`) is answered without starting the app, so it needs no `OPTIONS` routes, and the headers are also added to responses the Worker makes itself (the 500 of a trap), so the browser sees the real status. Settings are Worker variables in `wrangler.toml`:

| Variable | |
|---|---|
| `CORS_ORIGINS` | allowed origins, comma-separated, compared as exact strings with the request's `Origin` (`https://app.example, http://localhost:3000`; no trailing slash). `*` allows any origin. Unset or empty means CORS is off: nothing is added and `OPTIONS` goes to the app. The origin `null` (sandboxed iframes, `file:` pages) is never allowed, even with `*` |
| `CORS_HEADERS` | request headers a preflight allows (default `Authorization, Content-Type`). Listed one by one, as `*` does not cover `Authorization` |
| `CORS_MAX_AGE` | seconds a browser may cache a preflight (default `600`). Not a non-negative integer: every request is answered 500, as with a bad JWT setting |
| `CORS_EXPOSE_HEADERS` | response headers the page may read (`Access-Control-Expose-Headers`, e.g. `X-Total-Count`); none by default |

A preflight from an allowed origin is answered 204 with `Access-Control-Allow-Origin` (the request's origin), `Access-Control-Allow-Methods` (`GET, HEAD, POST, PUT, PATCH, DELETE`), `Access-Control-Allow-Headers` and `Access-Control-Max-Age`; from another origin it is 403 `{"error":"origin not allowed"}`. Other responses get `Access-Control-Allow-Origin` when the `Origin` is allowed, and `Origin` is added to `Vary`. Cookies (credentials) are not supported: `Access-Control-Allow-Credentials` is never sent, and a token that `fetch` puts in `Authorization` does not need it.

Serving the frontend from the same origin as the API avoids CORS altogether.

## Testing an app

```sh
bundle exec edgeway test [ARGS]   # ARGS go to spinel_test-unit
```

`edgeway test` is the only supported way to run an app's tests. It rewrites `tmp/test_app.rb` (git-ignored; `build/` belongs to `edgeway build`) on every run, listing the app's files in build order, because Spinel resolves `require` at compile time. Running `spinel_test-unit` directly fails when that file is missing and uses a stale one when app files changed. Tests `require "edgeway/test"` in `test/test_helper.rb`. Each test runs against a real in-memory SQLite database (`Edgeway::DB::SQLiteAdapter`, through Spinel's FFI) with `db/migrations/*.sql` applied in file name order, so requests really write and read rows. This needs the SQLite library at link time: `libsqlite3-dev` on Debian/Ubuntu, `sqlite-devel` on Fedora (preinstalled on macOS). `edgeway test` first tries to link `-lsqlite3` with `$CC` (or `cc`/`gcc`/`clang`) and stops with the fix if that fails; point `LIBRARY_PATH` at a directory holding `libsqlite3.so` if it lives elsewhere, or set `EDGEWAY_SKIP_PRECHECK=1` to skip the check. Edgeway's own tests use `MemoryAdapter`, which stores nothing; `SQLiteAdapter` is Spinel-only (`test/spinel/*.rb`).

## Development

```sh
bin/setup                      # mise install (Spinel, the WASI SDK) and bundle install
bundle exec rake test          # needs libsqlite3-dev (test/spinel/sqlite.rb); runs test/*.rb under CRuby and as Spinel native builds, and compares with .expected
bundle exec rake test:cruby    # CRuby only
```

CI runs `rake test` (both legs, the CLI and the JS tests) on Ubuntu and macOS, with Spinel from `mise.toml`. To test against a Spinel checkout instead of the release, set `SPINEL` in a `mise.local.toml` (see `mise.toml`).

Only the subset of Ruby that Spinel supports can be used. The limits found so far and the resulting design changes are in `docs/spinel-notes.md`, the Spinel issues that need fixing are in `docs/spinel-issues.md`, and the state of the work is in `docs/progress.md`.

## License

MIT
