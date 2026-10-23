# Developing the mirror

Working on the code itself: architecture, invariants, tests and quality gates.
Deployment lives in [operations.md](operations.md), settings in
[configuration.md](configuration.md).

## Local setup

```bash
docker compose up -d          # Postgres, Adminer, smtp4dev — local convenience only
mix setup                     # deps, DB, migrations, assets, demo content
mix phx.server
```

`CM_SOURCE=demo` needs no Confluence credentials. Development and test assume an
administrator (`MIRROR_AUTO_ADMIN`), so no sign-in is in the way.

`AGENTS.md` carries the Phoenix/Elixir conventions for this repository; the
invariants below are the ones specific to the mirror.

## Invariants

* **Read-only.** Content only changes through `Sync` reading a source. Never add
  a write path — no edit tables, forms or "demo edit" mix flags.
* **Upstream changes are source DTOs.** `Confluence.Source` is a behaviour with
  `HttpSource` (REST) and `DemoSource`; test doubles live in `test/support` and
  are injected via `Sync.run(mode, source: Module)`.
* **Search is layered.** The reader UI and `/api/v1/search` take structured
  params (`q`, `space`, `label`, `type`, `creator`, `ancestor`, `updated`),
  compiled to internal CQL by `Mirror.Search.Filters`; `q` is parsed by
  `Mirror.Search.TextQuery`. Raw CQL is public only on the
  Confluence-compatible `/wiki/rest/api` surface. Lexemes keep inner dots and
  hyphens because Postgres `simple` treats `roadmap.csv` as one lexeme.
* **Blob root outside the repo.** `var/mirror` in development,
  `tmp/mirror_test` in test; never `priv/static`.
* **Skins without rebuild for sites.** Built-ins are daisyUI
  `@plugin ... daisyui-theme` blocks in `assets/css/app.css`; other skins are
  declarations emitted per request by `Web.Skins` — from
  `config :confluence_phx_mirror, :skins` or from packs
  (`ConfluencePhxMirrorWeb.Skins.Pack` modules listed in `:skin_packs`, e.g.
  `Skins.FreshBlue`). A declaration may carry `dark_colors`, emitted as a
  `prefers-color-scheme` override; `selectable: false` keeps a skin out of the
  reader picker so it is only usable as `:site_skin`. Deeper overrides go in
  `assets/css/author.css`.
* **JS dependencies are real dependencies**: `assets/package.json`, `npm ci`
  wired into `assets.build` / `assets.deploy`. Syntax highlighting uses the
  highlight.js grammar chosen from Confluence's `brush:` attribute.
* **Instants are UTC, everywhere but the screen.** Columns are
  `:utc_datetime`, code writes `DateTime.utc_now() |> DateTime.truncate(:second)`,
  and Confluence timestamps are parsed with `DateTime.from_iso8601/1`, which
  yields the same instant in UTC whatever offset the source used
  (`HttpSource.parse_time/1`). `Web.Time` renders that UTC instant and says so;
  `Web.TimeComponents.local_time/1` emits `<time datetime="…Z">` for
  `assets/js/local_time.js` to rewrite in the browser's zone, because only the
  browser knows it. Never print one zone's wall clock under another's label, and
  never store a zone the mirror cannot vouch for.
* **Config is read at boot.** The dev code reloader does not reload
  `config/*.exs`.

## Architecture

| Layer | Module | Notes |
|---|---|---|
| Source | `Confluence.Source` | Behaviour; `HttpSource` (REST) and `DemoSource` |
| Ingestion | `Sync` | snapshot / incremental / space / page; per-page error isolation |
| Rendering | `Sync.Renderer` | keeps `export_view`, rewrites links, sanitises, converts expand macros to native `<details>` |
| Content | `Mirror` | Ecto queries for pages, trees, backlinks, labels |
| Search | `Mirror.Search` + `Mirror.Search.CQL` | CQL → parameterised SQL over `tsvector` |
| Blobs | `Blobs.Store` / `Blobs.LocalStore` | path-based; S3 can implement the behaviour |
| Jobs | Oban | `Sync.SnapshotWorker`, `Sync.PageWorker`, notification workers |
| Web | controllers + LiveView | reader UI, admin dashboard, REST API, webhooks |
| Accounts | `Accounts` | magic links, proxy auth, API tokens, Phoenix 1.8 `Scope` |
| Audit | `Audit` | append-only; syncs, webhooks, accounts, attachments |

### Sync semantics

A sync is recorded as a `SyncRun` (`running` → `succeeded` / `partial` /
`failed`) with counters and errors. Failures are **per page**: one broken
attachment or comment does not abort the run. Pages missing from a snapshot are
marked deleted (rows are kept for audit), attachments removed in Confluence are
deleted from Postgres and the blob store.

Snapshots upsert all pages first, then render, so cross-space links resolve even
when the target space appears later in the same run. A source that lists no
pages for a space never marks that space's content deleted — the run is flagged
`partial`.

## Tests

Tests are grouped by the question they answer:

| Level | Files | Question |
| --- | --- | --- |
| Feature (`FeatureCase` + `phoenix_test`) | `test/…_web/features/` | can a reader get from A to B? |
| LiveView | `test/…_web/live_views_test.exs` | what happens when a reader interacts? |
| Controller | `test/…_web/controllers/` | what does one request return? |
| API | `test/…_web/api_test.exs` | what does the JSON surface promise? |
| Unit | `test/…/mirror`, `test/…/sync`, `test/…/blobs` | what does a pure module decide? |

Feature tests use `PhoenixTest`, so they do not care whether a page is a
controller or a LiveView: they visit, click, fill and assert the same way a
reader would, and assert on paths and visible text rather than markup.

Covered: the CQL grammar, the renderer (cross-links, attachments, sanitising,
native expand macros), blob keys/store, full sync + idempotency, updated pages
arriving through a sync, deletions, notifications, magic links, API tokens,
webhook signatures and Presence.

```bash
mix test                 # the suite
mix test test/path_test.exs
mix test --failed
```

Tests start processes with `start_supervised!/1`; wait for a process with
`Process.monitor/1` / `_ = :sys.get_state/1` rather than `Process.sleep/1`.

### Reading at scale

The demo snapshot is a dozen pages, and a page view that quietly loads a whole
space looks like a fast one there. What runs at scale, how to start a server on
generated content of a chosen size, how to read the reports and what the current
numbers are: [performance.md](performance.md).

## Quality gates

One script runs everything and prints one summary; the `mix` aliases below are
what it calls, and are worth running on their own while working:

```bash
scripts/quality.sh              # lint, suite with coverage, CRAP report (what CI runs)
scripts/quality.sh --fast       # static analysis only: no database, no tests
scripts/quality.sh --top 20     # rank more CRAP entries (default 8)

mix lint                        # compile --warnings-as-errors, unused deps, format, credo --strict, sobelow
mix cover                       # the suite with the coverage export the complexity gate needs
mix complexity                  # CRAP over the application code (verbose table)
mix precommit                   # the script, so CI and a laptop agree
```

The script is read-only: it runs `format --check-formatted` and
`deps.unlock --check-unused`, so a report never rewrites a file. Run
`mix format` yourself when it complains.

`mix lint` needs no database and no test run (about two seconds), so it is the
one to keep in a file-watcher or a pre-commit hook. `mix format
--check-formatted`, `mix credo --strict` and `mix sobelow --config` can of
course be run on their own.

Sobelow runs with `skip: true`, so every accepted finding is either a
`# sobelow_skip [...]` comment with its reason at the call site (sanitised HTML,
the parameterised CQL builder, blob keys) or an entry in `.sobelow-skips` for a
reviewed template. Regenerate those entries with
`mix sobelow --config --mark-skip-all` only after reviewing them again. The
reader pipeline answers `Config.CSP` with a real Content-Security-Policy:
scripts only from the mirror itself, inline styles allowed for Confluence's own
markup.

`mix crap` (ex_crap) scores every function by cyclomatic complexity and its test
coverage, so untested complexity becomes a ranked queue instead of a vague
feeling. It reads exported coverage data, which is why the complexity step
follows the coverage step:

```bash
mix cover && mix crap --verbose   # full table; `mix crap` prints only the offenders
```

The threshold is the conventional `30` (a complexity-5 function with no tests),
applied to the application code in `lib/confluence_phx_mirror` and
`lib/confluence_phx_mirror_web`. Only the operator CLIs under `lib/mix/tasks`
stay outside the gate — their argument parsing and shell output are exercised by
hand, not by the suite. Keep both trees in the alias: `crap` takes one path, and
Mix refuses to run the same task twice in one invocation, which is why the two
runs go through `cmd`.

The report ranks three ways because they answer different questions: the
per-function list says what to fix, the per-file list says where a file's worst
spot is, and the per-tree line says whether a whole layer needs attention.

## License

The code is under the Mozilla Public License 2.0 ([LICENSE](../LICENSE), and
`package: [licenses: ["MPL-2.0"]]` in `mix.exs`). MPL is file-scoped: a modified
file stays under the MPL, the rest of a system built around it need not. There
are no per-file notices — the repository `LICENSE` is the notice — so new files
need no header; contributions come in under the same licence.

## Changing behaviour

A user-, admin- or operator-facing change is not done until the matching guide
under `docs/` says so: [site-admin-guide.md](site-admin-guide.md),
[operations.md](operations.md), [configuration.md](configuration.md),
[api.md](api.md). Migrations belong in
[operations.md](operations.md#migrate-as-a-deploy-step).
