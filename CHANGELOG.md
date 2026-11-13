# Changelog

## Unreleased

### Added

- `edgeway generate` takes a `binary` field type.
- `config/edgeway.yml` with `platform:` (only `cloudflare` for now, and the default without the file). `edgeway new` writes it.

### Changed

- A route to a controller that is not defined, or to an action that is not a public method of it (private methods and `Edgeway::Controller::Base`'s own public methods are not actions), is a build error, not a 404 at run time.
- `edgeway build` and `edgeway test` now load the app's files in CRuby to read the routes (`edgeway routes` loads only `config/routes.rb`).
  The library files that use Spinel's `ffi_*` declarations can't load there and are skipped, so an app file that uses their classes when it is loaded fails the build.

### Fixed

- `Edgeway::Model.batch` left with `break` or `return` now sends the queued writes and ends the batch. Before, the writes were lost and every later write was queued and never run.

## v0.3.0

### Added

- Rate limiting: `rate_limit` in controllers, over a Cloudflare Rate Limiting binding. A request over the limit gets a 429.
  The limit and period are set in `[[ratelimits]]` of `wrangler.toml` ([#22](https://github.com/y-yagi/edgeway/pull/22)).
- Cache store: `Edgeway.cache` (`read`, `write`, `fetch`, `delete`, `exist?`) over Workers KV, memory, or nothing,
  picked per environment in `config/cache.yml` ([#20](https://github.com/y-yagi/edgeway/pull/20)).
- HTTP caching helpers in controllers: `stale?`, `fresh_when`, `expires_in` and `no_store` ([#19](https://github.com/y-yagi/edgeway/pull/19)).
- Outbound HTTP: `Edgeway::HTTP.get`, `post`, `put`, `patch` and `delete` ([#18](https://github.com/y-yagi/edgeway/pull/18)).
- Test helpers in `Edgeway::UnitTest`: `stub_http`, `stub_http_error`, `http_requests`, `stub_rate_limit` and `rate_limit_checks` ([#18](https://github.com/y-yagi/edgeway/pull/18), [#22](https://github.com/y-yagi/edgeway/pull/22)).
- Static assets: apps made by `edgeway new` serve `public/` as Workers Static Assets ([#16](https://github.com/y-yagi/edgeway/pull/16)).
- Structured logging: `Edgeway.logger` has `debug`, `info`, `warn` and `error`, and `LOG_LEVEL` sets the lowest level written.
  Workers Logs records one entry per log line with its fields, and new apps enable `[observability]` ([#17](https://github.com/y-yagi/edgeway/pull/17)).

### Changed

- `Edgeway.logger` writes JSON lines instead of `[edgeway] ...` text. A custom logger set with `Edgeway.logger=` must take `(message, fields = {})` ([#17](https://github.com/y-yagi/edgeway/pull/17)).
- `edgeway test` runs the tests on a local D1 when the `test:` section of `config/database.yml` has `adapter: d1` (needs Node.js 24 or later and wrangler).
  Apps made by `edgeway new` use it ([#15](https://github.com/y-yagi/edgeway/pull/15)).

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
