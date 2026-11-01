# Changelog

## Unreleased

### Changed

- `edgeway test` runs the tests as wasm32-wasi on a local D1 (wrangler's `getPlatformProxy`, in memory) when the `test:` section of `config/database.yml` has `adapter: d1`;
  each test drops every table and applies the migrations again. Other adapters keep the native build with SQLite.
  Needs Node.js 24 or later and wrangler in `node_modules`.
- Apps made by `edgeway new` use `adapter: d1` for `test:`, and their CI installs wrangler instead of libsqlite3-dev.

## v0.2.0

### Added

- Views: ERB templates in `app/views`. `<%= %>` escapes unless the value is `raw(text)` / `text.html_safe`, and `render html:` escapes anything but a `SafeHTML`. An action that renders nothing renders its template when there is one (else 204 as before), and `render` raises `Edgeway::MissingTemplate` when its template is missing ([#1](https://github.com/y-yagi/edgeway/pull/1)).
- `edgeway generate scaffold`: a model, its migration, a JSON API controller and their tests, and `r.resources` added to `config/routes.rb`.
  `generate model` and `scaffold` stop if the table's create migration exists ([#2](https://github.com/y-yagi/edgeway/pull/2)).
- Apps made by `edgeway new` get `bin/test`, a GitHub Actions workflow and a `.ruby-version`.
- D1:
  - `NotNullViolation`, `InvalidForeignKey` and `CheckViolation` (500), and `DatabaseUnavailable` (503 with `Retry-After: 1`) for D1's transient errors ([#4](https://github.com/y-yagi/edgeway/pull/4)).
  - Raw SQL (`find_by_sql`, `Edgeway::Model.select_all`, `Edgeway::Model.execute`), and `where` with Arrays (`IN`), Ranges and SQL fragments.
    More than 100 bound parameters in a statement raises `ArgumentError` (`limit` and `offset` don't count) ([#5](https://github.com/y-yagi/edgeway/pull/5)).
  - `Edgeway::Model.query_stats` and a `db=… rows_read=… rows_written=… db_ms=…` log line per request ([#6](https://github.com/y-yagi/edgeway/pull/6)).
  - `:binary` and `:bigint` attribute types; a rowid beyond 32 bits works. `Edgeway::Model.blob` binds a BLOB in raw SQL,
    and `Edgeway::Model.cast(:bigint, value)` reads a large integer from a raw row ([#7](https://github.com/y-yagi/edgeway/pull/7)).
  - Several databases: `databases:` in `config/database.yml` and `self.database = :name`; `database:` for `select_all`/`execute`,
    `query_stats(:name)`, and `db(:name)` in tests ([#9](https://github.com/y-yagi/edgeway/pull/9)).
  - Read replication through the Sessions API: `sessions: true`, with the bookmark in an `X-D1-Bookmark` header
    (added to `Vary` and, with CORS, to the allowed and exposed headers); only `GET`/`HEAD` start from it, other methods always start `first-primary` ([#10](https://github.com/y-yagi/edgeway/pull/10)).
  - `Edgeway::Model.exec` for D1's `exec()` ([#11](https://github.com/y-yagi/edgeway/pull/11)).

### Changed

- `edgeway build` passes Spinel's `--incremental`; `--release` builds as one unit, and the generated `bin/deploy` and CI use it ([#8](https://github.com/y-yagi/edgeway/pull/8)).
- The Spinel that Edgeway and the `mise.toml` of `edgeway new` pin is `ec0ad13e4` (was `530ba2b17`) ([#3](https://github.com/y-yagi/edgeway/pull/3), [#8](https://github.com/y-yagi/edgeway/pull/8)).
- A Time in a query is bound as ISO 8601 UTC with milliseconds (`2026-10-28T05:00:00.000Z`), as timestamps are stored ([#5](https://github.com/y-yagi/edgeway/pull/5)).

## 0.1.0

- First release.
