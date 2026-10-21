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
  `@plugin ... daisyui-theme` blocks in `assets/css/app.css`; site skins come
  from `config :confluence_phx_mirror, :skins` and are emitted per request by
  `Web.Skins`; deeper overrides go in `assets/css/author.css`.
* **JS dependencies are real dependencies**: `assets/package.json`, `npm ci`
  wired into `assets.build` / `assets.deploy`. Syntax highlighting uses the
  highlight.js grammar chosen from Confluence's `brush:` attribute.
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

## Quality gates

```bash
mix precommit            # compile --warnings-as-errors, unused deps, format, credo --strict, sobelow, cover + crap, tests
mix format --check-formatted
mix credo --strict
mix sobelow --config     # security pass, about a second
```

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
feeling. It needs exported coverage data:

```bash
mix test --cover --export-coverage default
mix crap --verbose      # full table; `mix crap` prints only the offenders
```

`precommit` runs it over the application code with the conventional threshold of
`30` (a complexity-5 function with no tests). Only the operator CLIs under
`lib/mix/tasks` stay outside the gate — their argument parsing and shell output
are exercised by hand, not by the suite.

## Changing behaviour

A user-, admin- or operator-facing change is not done until the matching guide
under `docs/` says so: [site-admin-guide.md](site-admin-guide.md),
[operations.md](operations.md), [configuration.md](configuration.md),
[api.md](api.md). Migrations belong in
[operations.md](operations.md#migrate-as-a-deploy-step).
