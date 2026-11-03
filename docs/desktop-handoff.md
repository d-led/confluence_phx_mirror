# Desktop export tool — hand-off

State of the branch `desktop` (`origin/desktop`, draft PR #3).

Everything in "What works" is green: `mix lint` passes with **no sobelow
findings and no skip registry**, and the suite is 1917/1917 on an idle machine.

## What works, and how it was proven

| thing | evidence |
| --- | --- |
| One repo, one schema, either storage | `MIX_ENV=test` schemas report `{:array, :string}` / `{:array, :integer}`; `MIX_ENV=desktop` reports `Schema.JSONList` |
| All 46 migrations build on SQLite | `ALL APPLIED`, 46/46, on an empty file; 29 tables |
| The same 46 build on Postgres | dropped and rebuilt from scratch: 46 migrations, `search_vector` column, 8 GIN indexes |
| Desktop ingest writes the server's rows | demo space: 37 pages, 1 space, labels/ancestors round-trip as lists |
| The release boots and serves | `desktop ui: http://127.0.0.1:<port>/`, `Node.alive? == false`, `ensure_all_started` → `:ok` |
| The tool remembers its site, and reaches it | with `CM_CONFLUENCE_SITE`, `CM_ATL_EMAIL` and `CM_ATL_TOKEN` exported, a boot answers `/state` → `{"missing":["site"],"readiness":"needs"}` and `/` → 302 `/setup`; `POST /setup` → 303 and `ready`; a second boot is still `ready` and `/` → 200; `eval` then shows `api_token` (the value typed in, from the keychain), the recorded `base_url`/`email`, and `:source` = `HttpSource` |
| The tool exports what it mirrored | `POST /export` → 303, then `/export` says `Ready` and `/export/site.zip` answers 200 `application/zip`, 272 903 bytes; the zip holds 123 files — `index.html` (`<title>dled`), `search.html`, `assets/search-index.js`, `labels/…`, `spaces/MFS/pages/…html` and `.md` — and the same file is on disk under `<workspace>/confluence-mirror-exports/` |
| Server suite | 1917 passed, 7 excluded, 0 failed (on a clean database, one suite at a time) |

## What is broken or unfinished

1. **The real Endpoint is not wired into the tool.** An attempt hung inside the
   `:browser` pipeline and was reverted (see "Traps").
2. **No `.app` yet.** `bundle.active` is `false`; with it on, `cargo build` fails in
   tauri-build's resource phase with `Permission denied (os error 13)`.
3. **`lib_desktop/` is outside the format gate.** `.formatter.exs` inputs are
   `{config,lib,test}`, so the tool's own modules are credo-checked but never
   formatted; `Settings.validate_site/1` shows it (a `case` on the same line as
   the `do`). Adding `lib_desktop/**/*.ex` there is a one-line change and a
   reformat commit.

## Decisions, and why

- **The tool runs the server's code.** One `ConfluencePhxMirror.Repo`, adapter
  chosen at *compile* time (`Application.compile_env`), database path at *start*
  time. `lib/` must never name a `Desktop.*` module — that containment is what
  keeps the server build untouched.
- **One schema, one migration set.** `priv/repo/migrations` builds both storages;
  `ConfluencePhxMirror.Migration` holds the six constructs that differ. The
  Postgres-only DDL (generated `tsvector`, `pg_trgm`, `ALTER COLUMN`, the slug
  rewrite) is *guarded*, not translated.
- **The folder is fixed, and the site lives in one small file beside it.** The
  database and `blobs/` sit under `~/Library/Application Support/confluence-export`,
  and `settings.json` next to them records exactly two things — the site and the
  account. This replaces "everything else belongs in the server's `settings`
  table": that table is the *catalogue* of a deployment's audited settings, and
  its own docs say a value read once at boot (the source, the credentials) is
  not one of them. Putting the tool's site there would either add a key the
  server must then ignore or add a desktop-only table to the server's schema.
  The secret still goes to the OS keyring, now under a constant key, so losing
  the file costs the address, not the token.
- **Nothing in the tool falls back to `CM_*` for its site.** A variable in a
  shell is not something the window can change, and when it satisfies
  `readiness/0` it makes the form that *would* save a site unreachable — which is
  how a workspace gets configured ten times and remembers none of it. The
  environment is still what the form *offers* (`Settings.suggested_site/0`,
  `suggested_email/0`, prefilled but not saved), because a provisioned machine
  should not have its URL typed by hand; it just does not count as an answer. The
  token keeps its environment fallback: it is a fallback, not a shadow, because
  the keyring wins when it has one.
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
2. **A sobelow skip has three shapes, and only two work.** `.sobelow-skips` is
   keyed `file:line:hash` — `phash2(type, variable, file, line)` — so inserting a
   line above a finding invalidates it and fails CI. Twice. Inline
   `# sobelow_skip ["Rule"]` on **the line sobelow reports** works in `.ex` files
   only: it is rewritten into a module attribute before parsing, so in a `.heex`
   template it is inert text and the finding simply moves to the next line
   (verified). A template finding therefore has to be removed rather than
   suppressed: give the raw output an owner in an `.ex` module (`skin_style/1`,
   `confluence_body/1`) and skip that one function.
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
   looked like code bugs. Check `pgrep -fl "mix test"` before running. Two at
   once also break `site_export_link_test.exs` (a build that must be seen half
   written): it fails under the load and passes alone, 8/8.
7. **`bin/… stop` needs a node name.** The sidecar runs with
   `RELEASE_DISTRIBUTION=none` (trap 1), and `stop` is an RPC: it answers
   "Cannot run --rpc-eval if the node is not alive (set --name or --sname)" and
   the sidecar keeps running. `start-desktop.sh --in-browser` used to call it
   with `|| true`, leaking a process per launch; it now keeps the PID it started
   (the release script `exec`s the VM, so `$!` is the sidecar) and kills that.
   By hand: `lsof -nP -iTCP:<port> -sTCP:LISTEN -t | xargs kill`.
8. **The exporter had Postgres-only SQL, in places that only show on SQLite.**
   `LIMIT NULL` is "no limit" in Postgres and a datatype mismatch in SQLite
   (`Authorization.readable_spaces/2` emitted it whenever no `:limit` was
   asked for), and `left(x, n)` does not exist in SQLite at all
   (`Export.Site.Search`). Both now use what the two engines agree on — no
   `LIMIT` clause, and `substr/3`. The migration DDL had been made portable;
   the queries had not, because nothing ran them on the file until the tool
   could export.
9. **A rate-limit test can race the clock, not the code.** `RateLimit` is Hammer's
   ETS backend, whose default `:fix_window` is aligned to the wall clock: two
   deliveries in one test can land either side of a boundary, and then the
   second counts from zero ("expected 429, got 202"). It failed CI once on a
   commit with no server change. The webhook tests now ask for a day-wide
   window — they are about the cap, not about expiry.

## Next, in order

1. **The real Endpoint in the tool**, once the tool has the tables its `:browser`
   pipeline needs. It hung rather than erroring; the suspicion is the `pool_size: 1`
   SQLite pool, with `AutoAdmin` and `SiteContext` each wanting a connection while
   the request holds one. Read a logged run before changing anything.
2. **Cypress harness** against `--in-browser`, with a demo *connector* (HTTP, not an
   in-process seed) so the same suite can run against the container image.
3. **The `.app`**: `bundle.active` back on, resources mapped, then
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
                                                      # and stop it by the port owner (trap 7):
                                                      # lsof -nP -iTCP:<port> -sTCP:LISTEN -t | xargs kill
scripts/start-desktop.sh                              # the app itself
```
