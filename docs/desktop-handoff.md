# Desktop export tool — hand-off

State of the branch `desktop` (`origin/desktop`, draft PR #3, 29 commits ahead of
`main`). Written after a long session that fixed several things and broke two; both
of those are recorded here so they are not repeated.

## What works, and how it was proven

| thing | evidence |
| --- | --- |
| One repo, one schema, either storage | `MIX_ENV=test` schemas report `{:array, :string}` / `{:array, :integer}`; `MIX_ENV=desktop` reports `Schema.JSONList` |
| All 46 migrations build on SQLite | `ALL APPLIED`, 46/46, on an empty file; 29 tables |
| The same 46 build on Postgres | dropped and rebuilt from scratch: 46 migrations, `search_vector` column, 8 GIN indexes |
| Desktop ingest writes the server's rows | demo space: 37 pages, 1 space, labels/ancestors round-trip as lists |
| The release boots and serves | `desktop ui: http://127.0.0.1:<port>/`, `Node.alive? == false`, `ensure_all_started` → `:ok` |
| Server suite | 1917 passed, 7 excluded, 0 failed (on a clean database, one suite at a time) |

## What is broken or unfinished

1. **CI is red** — `.sobelow-skips` was deleted, so 13 findings that it used to
   suppress are now reported. See "Sobelow" below.
2. **3 commits are unpushed** (`03f6c05`, `2a0600f`, `4e14c95`), and
   `lib/confluence_phx_mirror_web/router.ex` has an uncommitted inline skip.
3. **Site and email do not persist.** `settings.json` contains only
   `secret_key_base` — `Settings.store/1` has never run, because three `CM_*`
   environment variables make `readiness/0` return `:ready`, so the setup form is
   never the path taken. This is the "I configured ten times and nothing stuck"
   bug, and it is a design fault, not a typo.
4. **The real Endpoint is not wired into the tool.** An attempt hung inside the
   `:browser` pipeline and was reverted (see "Traps").
5. **No `.app` yet.** `bundle.active` is `false`; with it on, `cargo build` fails in
   tauri-build's resource phase with `Permission denied (os error 13)`.

## Decisions, and why

- **The tool runs the server's code.** One `ConfluencePhxMirror.Repo`, adapter
  chosen at *compile* time (`Application.compile_env`), database path at *start*
  time. `lib/` must never name a `Desktop.*` module — that containment is what
  keeps the server build untouched.
- **One schema, one migration set.** `priv/repo/migrations` builds both storages;
  `ConfluencePhxMirror.Migration` holds the six constructs that differ. The
  Postgres-only DDL (generated `tsvector`, `pg_trgm`, `ALTER COLUMN`, the slug
  rewrite) is *guarded*, not translated.
- **No `settings.json`.** The workspace is fixed and collocated — the database and
  `blobs/` side by side under `~/Library/Application Support/confluence-export`.
  Secrets go to the OS keyring under a **constant** key; everything else belongs in
  the server's `settings` table. Nothing is configured, so nothing can fail to
  persist.
- **Search is FTS5 later.** `Mirror.Search` uses Postgres `tsvector`; it is reached
  only by `SearchLive` and two API controllers, so it is one module to port, not a
  thread through the app.
- **Cypress cannot drive the Tauri window** — it is a native `WKWebView`, not a
  browser. Test the app through `scripts/start-desktop.sh --in-browser` (identical
  routes, same sidecar), and keep one `tauri-driver` smoke test for the window
  handshake.

## Traps, each of which cost hours

1. **A Mix release is distributed by default**, with a fixed node name. One such
   node per machine: a sidecar left by an earlier run takes the name, the new one
   dies before printing its address, and the window aborts with "the sidecar
   stopped before it said where it listens". `rel/env.sh.eex` set
   `RELEASE_DISTRIBUTION=sname` *unconditionally*; it is now a default
   (`${RELEASE_DISTRIBUTION:-sname}`) so `none` is obeyed.
2. **`.sobelow-skips` is keyed `file:line:hash`.** Inserting 21 lines above a
   finding invalidates it and fails CI. Twice. Use inline `# sobelow_skip ["Rule"]`
   on **the line sobelow reports** — for a pipeline, that is `pipeline :api do`,
   not the `plug` inside it.
3. **Migrations must run before anything queries the catalogue.** `Spaces.init/1`
   asks for spaces as it starts; on a fresh install there were no tables. `Setup`
   is now a child immediately after the repo, does its work in `start_link`, and
   returns `:ignore`.
4. **An old catalogue must not be migrated onto the new schema.** It is renamed to
   `catalogue.db.before-shared-schema-<ts>` (kept, not deleted) and a fresh one is
   created.
5. **`comments.parent_id` is a foreign key.** Insert comments without it, then
   resolve parents by `confluence_id` — the server's own rule.
6. **Never run two suites against one test database.** Backgrounded `mix test`
   processes from earlier turns stayed alive and produced flaky failures that
   looked like code bugs. Check `pgrep -fl "mix test"` before running.

## Next, in order

1. **Sobelow, to green.** 13 findings, in three classes, all false positives:
   `Traversal.FileModule` (paths from `Application.app_dir/2`), `XSS.Raw` (HTML
   `Sync.Renderer` already sanitised), `Config.CSRF` on the read-only API. The
   `Config.CSRF` one is done and verified — it took the finding count from 14 to
   13. Apply the same inline form to the rest, running `mix sobelow --exit` after
   each file. For the six `.heex` sites, first confirm sobelow honours a skip
   comment inside HEEx; if it does not, that is the one place a registry entry is
   unavoidable and it must carry a reason.
2. **Collocated paths.** `Settings.root/0` returns the fixed directory — no file
   read, no `choose_root/1`. Keyring key becomes a constant.
3. **Site and email into the database.** They are read at boot for `HttpSource`,
   which is *before* the repo starts, so they must be read by a step after
   migrations — the same shape as `Setup`.
4. **The real Endpoint in the tool**, once the tool has the tables its `:browser`
   pipeline needs. It hung rather than erroring; the suspicion is the `pool_size: 1`
   SQLite pool, with `AutoAdmin` and `SiteContext` each wanting a connection while
   the request holds one. Read a logged run before changing anything.
5. **Cypress harness** against `--in-browser`, with a demo *connector* (HTTP, not an
   in-process seed) so the same suite can run against the container image.
6. **The `.app`**: `bundle.active` back on, resources mapped, then
   `cargo tauri build --bundles app`. Unsigned bundles are quarantined by Gatekeeper,
   so signing and notarisation are part of shipping, not a config flag.

## Verifying anything, fast

```sh
MIX_ENV=dev     mix compile --warnings-as-errors     # server untouched
MIX_ENV=desktop mix compile --warnings-as-errors     # tool builds
pgrep -fl "mix test" | wc -l                          # must be 0
mix test                                              # 1917 / 0
mix sobelow --exit                                    # security gate
RELEASE_DISTRIBUTION=none _build/desktop/rel/confluence_phx_mirror/bin/confluence_phx_mirror start
                                                      # must print `desktop ui: …`
scripts/start-desktop.sh                              # the app itself
```
