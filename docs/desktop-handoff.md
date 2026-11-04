# Desktop export tool — hand-off

State of the branch `desktop` (`origin/desktop`, draft PR #3).

Everything in "What works" is green: `mix lint` passes with **no sobelow
findings and no skip registry**, and the suite is 1917/1917 on an idle machine.

**The window is the mirror.** It opens on the server's own home page and every
screen behind it is the server's own screen — the directory, a page, the search
page, `/admin` and the settings page under it — served by the same endpoint,
mounted in the tool's loopback listener. What is left in `lib_desktop/` is the
connection, the run that copies a space into the catalogue, and the archive.

## What works, and how it was proven

| thing | evidence |
| --- | --- |
| One repo, one schema, either storage | `MIX_ENV=test` schemas report `{:array, :string}` / `{:array, :integer}`; `MIX_ENV=desktop` reports `Schema.JSONList` |
| All 46 migrations build on SQLite | `ALL APPLIED`, 46/46, on an empty file; 29 tables |
| The same 46 build on Postgres | dropped and rebuilt from scratch: 46 migrations, `search_vector` column, 8 GIN indexes |
| Desktop ingest writes the server's rows | demo space: 37 pages, 1 space, labels/ancestors round-trip as lists |
| The release boots and serves | `desktop ui: http://127.0.0.1:<port>/`, `Node.alive? == false`, `ensure_all_started` → `:ok` |
| The tool remembers its site, and reaches it | with `CM_CONFLUENCE_SITE`, `CM_ATL_EMAIL` and `CM_ATL_TOKEN` exported, a boot answers `/__tool/state` → `{"missing":["site"],"readiness":"needs"}` and `/` → the connection form (200, not a redirect); `POST /__tool/setup` → 303 and `ready`; a second boot is still `ready` and `/` → 200, the mirror's home; `eval` then shows `api_token` (the value typed in, from the keychain), the recorded `base_url`/`email`, and `:source` = `HttpSource` |
| The tool exports what it mirrored | `POST /__tool/export` → 303, then `/__tool/export` says `Ready` and `/__tool/export/site.zip` answers 200 `application/zip`; the zip holds `index.html` (`<title>dled`), `search.html`, `assets/search-index.js`, `labels/…`, `spaces/MFS/pages/…html` and `.md` — and the same file is on disk under the workspace |
| The tool *reads* what it mirrored | the mirror's own screens do, over the same rows: `/` (44 pages, the space list, the latest changes), `/spaces/MFS` and a page under it — there is no second renderer and no published folder to go stale |
| Every screen can be left | the server's shell is on every page it serves (brand → `/`, the search box, the space switcher, the theme menu, the account menu), and the tool's own screens carry a bar (Desktop · Mirror · Admin · Spaces · Runs · Export · Connection); only the first-run form stands alone, because its way on is its own button |
| The launcher never starts a stale release | `start-desktop.sh` builds `_build/desktop/rel` **and** the window on every run (2.7 s + 4.3 s warm) — see trap 10 |
| The launcher shows everything it does | no redirect, no `&`, no log file, no `mktemp`: numbered steps with `ok in Ns`, the sidecar run with `exec` so its output is the terminal's, the window's status printed and passed on; `grep` for a redirect or a background job finds none, and `--where` streamed the compiler's own `Compiling 5 files (.ex)` as it ran |
| The desktop tree is formatted and warning-free | `mix format --check-formatted lib_desktop/…` → 0, `MIX_ENV=desktop mix compile --warnings-as-errors` → 0, five forced modules in **7.7 s** — see trap 14 for what once made the same build 481 s |
| The tool is type-checked, in its own environment | `MIX_ENV=desktop mix dialyzer` → **Total errors: 0**. It found one real contract bug first (see trap 16). Dialyxir is now a `:desktop` dependency too — `runtime: false`, so the release does not carry it |
| **The window opens on the mirror** | `GET /` answers 200 with the server's home page — heading `dled`, `1 spaces · 44 pages`, the space list and the latest changes — not a status screen |
| **Every reading screen is the server's** | `/`, `/spaces`, `/spaces/MFS`, `/labels`, `/people`, `/recent`, `/about`, `/profile` all 200, rendered by the server's controllers and LiveViews |
| **The admin area is the server's, one click away** | `/admin`, `/admin/settings`, `/admin/jobs`, `/admin/mail`, `/admin/webhooks`, `/admin/users`, `/admin/identities`, `/admin/groups`, `/admin/permissions`, `/admin/audit`, `/admin/trash`, `/admin/spaces`, `/admin/upstream`, `/admin/sync-log` — 14/14 answer 200, and the account menu carries the Admin cog because `:auto_admin` makes the one reader an administrator |
| **LiveView really connects** | in the window's own origin: `liveSocket.isConnected() === true`, `[data-phx-main]` present, 8 hooks registered, and typing in the admin settings filter patches the page (verified over `/live/websocket` → 400 for a plain GET, which is the socket route answering instead of 404) |
| The tool's own screens are still one origin | `/__tool`, `/__tool/state`, `/__tool/spaces`, `/__tool/mirror`, `/__tool/export` answer 200 under the same port; `/__tool/setup` is what an unconfigured `/` shows |
| The store's own limits are named, not hit | `Resources.database/0` asks a file for its size; `Mirror.maybe_page/2` omits `LIMIT NULL` and `OFFSET` without `LIMIT`; `Accounts.matches_identity/1` asks a JSON list with `json_each`; and `/search` says *"This mirror has no full-text index: search needs the Postgres build"* instead of raising in a reader's face |
| The window loads a current bundle | `start-desktop.sh` builds the stylesheet, the scripts and the digest on every run (it used to ship whatever `priv/static` happened to hold — the console said `unknown hook found` for the hooks the shell needs) |
| A refused run lands somewhere that explains it | `POST /__tool/mirror` with a run already going → 303 `/__tool/mirror` (the run that blocked it), not a silent bounce to the list; `Jobs.start_mirror/3` answers `{:error, :busy | :no_worker | :nothing_to_do}` instead of dropping the result |
| A task supervisor that refuses says so | `Spaces` and `Jobs` now match `Task.Supervisor.start_child/2`: a refusal becomes an error on the screen, where before the refresh stayed "loading" and the run stayed "running" forever |
| It is an app you can double-click | `cargo tauri build --bundles app` → `Confluence Export.app`, **50.33 MiB**, carrying the whole release at `Contents/Resources/rel/confluence_phx_mirror` (49 MB). `open` it: the window starts **its own bundled** sidecar on a fresh port, `/` answers "Not connected yet / Still needed: site", and quitting the window stops the sidecar (no port left behind) |
| Server suite | 1917 passed, 7 excluded, 0 failed (on a clean database, one suite at a time) |

## What is unfinished

1. **Search has no index in the tool.** `Mirror.Search` is SQL over a generated
   `search_vector` column and its GIN indexes; the tool's store is a file with
   neither. The screen now says so — *"This mirror has no full-text index: search
   needs the Postgres build"* — instead of raising. Doing it properly means an
   FTS5 table the sync keeps in step, which is a feature, not a translation.
2. **Mirroring is the tool's own pipeline.** The server's sync goes through Oban
   and `Sync.Gate`, whose lease is a Postgres `ON CONFLICT` statement; the tool
   copies a space straight into the catalogue (`Desktop.Mirror`), which is the
   path that is proven on SQLite. `/admin/jobs` therefore lists the jobs a
   deployment would run and stays empty here: the tool's runs are `/__tool`.
3. **The two `Sync.Scheduler` clocks are not started.** `/admin/settings` still
   shows the interval; nothing in this build reads it.
4. **The `.app` is unsigned.** It runs from this machine; a copy that travels is
   quarantined by Gatekeeper until it is signed and notarised.
5. **`lib_desktop/` has no unit tests**, and CI neither compiles nor dialyses
   `MIX_ENV=desktop`. The tool is verified by running it and by
   `MIX_ENV=desktop mix dialyzer`, not by a test file.
6. **The suite is flaky under load.** `DBConnection` checkout timeouts become
   `OwnershipError`s in six unrelated files; they pass alone. Not fixed.

## What was asked for, and where it stands

The user's words, in order, and the honest answer to each. Everything not listed
here as done is open.

| asked | state |
| --- | --- |
| "green CI" | **done** — three workflows green on push and PR, sobelow 0 with no skip registry, credo `--strict` 0 |
| "keep the web version working at all times" | **done** — `lib/` changed only for portable SQL and for moving sobelow findings into `.ex` owners |
| "minimal additional code, almost no change to the web app" | **done** — the tool is `lib_desktop/`, compiled only for `MIX_ENV=desktop` |
| "make the start-desktop build! Don't start stale code" | **done** — both halves on every run; trap 10 |
| "why isn't it prefilling the environment variables as before?" | **done** — the form is prefilled from `CM_*`, and those values are suggestions, not answers |
| "you forgot the token" | **done** — the secret is stored before the config is re-applied |
| "AND WHERE IS THE FUCKING MAIN VIEW???" | **done** — `/site` publishes and serves the mirror |
| "the confluence url was a local IP" | **done** — the site is only ever what this workspace recorded |
| "stop all the redirects in start-desktop.sh / don't fail silently" | **done** — no redirect, no `&`, no log file; numbered steps, real statuses |
| "each screen must have a link to proceed — there's no BACK BUTTON" | **done** — the server's own shell is on every page the mirror serves (brand, search, switcher, theme, account menu with Admin), and the tool's own screens carry a bar |
| "show the screen always; show the folder selection at the beginning; pre-fill the token" | **done** — an unconfigured `/` answers 200 with the connection form, the form prefills site, account, token and folder, and `POST /__tool/setup` carries the folder through (422 when it cannot be written) |
| "are you swallowing errors?" | **done** — publish failures are a screen and a log line; `Jobs` and `Spaces` no longer ignore a refused `start_child` (a run that never started used to look like a run in progress); a refused start redirects to the screen that explains it |
| "can you start producing better quality? Use dialyzer" | **done** — `MIX_ENV=desktop mix dialyzer`: **Total errors: 0**, after it found the `:page` contract bug (trap 16) |
| "a meaningful desktop app" | **done** for the tool: it mirrors, exports and navigates — and the reading surface is the whole mirror UI, admin included. Open: search (item 1) and signing |

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
- **The main view is the server's own.** One listener, two routers: `/__tool`
  and below is the tool's own, everything else is `ConfluencePhxMirrorWeb.Endpoint`
  *mounted* (`Endpoint.call/2`), not started — so there is one origin, one cookie
  jar and one `Host` for the pages, the websocket and the connection form. The
  alternative it replaces — exporting the mirror to `<workspace>/site/` and
  serving it with `Plug.Static` — was a second renderer of the same content and a
  folder that went stale between runs. Sessions, authentication and the admin
  area came along with the endpoint, and that is the point: `:auto_admin` makes
  the one reader an administrator, so the cockpit is one click from the mirror.
- **The endpoint is mounted, not started, because the port is not known until it
  is.** Bandit owns the listen socket on an ephemeral port and the window reads
  that port from the sidecar's output; the endpoint's `url` (used for absolute
  links) is therefore written *before* the supervisor starts, with the port the
  listener is about to get.
- **A saved connection takes effect immediately.** `configure/1` stores the
  secret first and re-applies the runtime configuration after, because the token
  reaches the credential store only in that call: applied before it, the client
  keeps whatever it had — the previous token, or none.
- **Search is FTS5 on this build.** `Mirror.Search.Lite` is the whole store-
  specific half: `search/3` still answers CQL with a sentence, and
  `structured/2` and `text/2` are an FTS5 `MATCH` over a `pages_fts` table kept
  in step by triggers. `mix test` cannot reach it — `ecto_sqlite3` is a `:desktop`
  dependency, so the suite has no SQLite driver. `LiteTest` covers the query
  language (what a reader types becomes `MATCH` syntax); the statement itself is
  exercised by running the desktop build, which is what the rows above record.
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
   written): it fails under the load and passes alone, 8/8. The same applies to
   any two `mix` processes: they serialise on the `_build` lock and the second
   looks hung, which is how time gets spent debugging a build that was only
   waiting.
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
10. **The window runs its own copy of the release.** `bundle.resources` in
    `tauri.conf.json` copies `_build/desktop/rel` into
    `src-tauri/target/debug/rel/` when *cargo* builds, and `main.rs` prefers the
    bundled copy (`resource_dir()`), or the one named by
    `CONFLUENCE_EXPORT_SIDECAR`. `start-desktop.sh` compared mtimes against
    `_build/...` only, so an Elixir-only change rebuilt that release, skipped the
    cargo step, and the window kept starting the copy it made hours earlier —
    measured: bundled binary 00:12, `_build` binary 07:29, same size, different
    code. The symptom is fixed code behaving like old code. The script now builds
    both on every run.
11. **A record cannot live in the folder it records.** `Settings.root/0` read the
    settings file, `file/0` built its path from `root/0`, and `read/0` read
    `file/0` — a cycle with no base case, so every call that touched the
    workspace (`--where`, and the app's own boot) spun forever with no output.
    The file's home is the application data directory; in the default case that is
    also the workspace, so the record still sits beside the catalogue, and when a
    folder is chosen the record stays put and points at it.
12. **A missing directory is a directory that changed.** `tauri-build` emits
    `rerun-if-changed` on `src-tauri/capabilities`, which did not exist, so cargo
    marked the crate dirty on every build: two consecutive `cargo build`s both
    printed `Compiling confluence-export` (14.4 s, then 10.7 s). Now the folder
    exists with a capability that grants nothing (the window calls nothing on the
    Rust side), and the second build is `Finished ... in 1.26s`. This is the
    involuntarily-invalidated cache: not the launcher, the missing folder.
13. **A compile-time answer to a runtime question.** `plug Plug.Static, at:
    "/site", from: Archive.dir()` is not a constant, it is a call made while
    compiling; and the folder it returns is a workspace value a person can change
    in the form. `from: {Archive, :dir, []}` (which `Plug.Static` supports) turns
    it into a per-request call, so the served folder follows the form instead of
    the build. The same shape still bites in this tree: `Desktop.Application`
    writes the endpoint's `:url` **before** the endpoint starts, because the
    endpoint reads it once — the port the listener is about to get is a runtime
    answer that a compile-time read would turn into yesterday's.
14. **A slow build is usually two builds, not a compiler bug.** A desktop compile
    took **481 s** with one file "taking more than 10s" forever, and the first
    reading was a livelock in the compiler. It was not: another project was
    compiling on the same machine at the same time (the user's words: "I ran the
    build at the same time — thus the problem"). `mix` processes also serialise on
    the `_build` lock, so the second one only waits. Before believing a compiler
    is stuck: `ps -A -o pid,etime,command | grep beam`, and look for another
    project's `_build` in the command lines.
15. **A killed build can still report success.** `kill` (SIGTERM) on a `mix`
    process is caught: the VM shuts down "gracefully", `mix` exits **0**, and the
    step in `start-desktop.sh` printed `ok in 481s` for a build that had not
    finished. The launcher is honest about the statuses it is given; a build
    stopped by hand never gives it a failing one. Re-run the build after killing
    one, and only kill a build when the build is what is wrong.
16. **A type can require a field nothing reads.** `Renderer.context` required
    `:page`, and no line of the renderer ever read it — links come from `:pages`
    and files from `:attachment_lookup`. Dialyzer believed the contract, which
    made the tool's `rendered_body/3` a function that `no_return`s, and turned
    every function below it into "will never be called". Nothing was wrong at
    run time, which is exactly why only a type check finds it: `:page` is
    `optional` now, and the tool renders from the source's DTO — before the row
    exists — with the same markup the server produces.
17. **A release ships `priv/static` and never builds it.** The window opened on a
    correctly rendered page and the console said `unknown hook found` for
    `Layouts.TopbarMenu`, `HeaderSearchLive.HeaderSearch` and
    `SpaceSwitcherLive.SpaceSwitcher`: the bundle in `priv/static/assets` was
    built before those hooks existed, and `mix release` copies whatever is there.
    Colocated hooks live in the bundle, so a stale bundle is a menu that does not
    open and a search box that does not appear — with no error on the server. The
    launcher now installs the toolchain (once), builds Tailwind, both esbuild
    bundles and the digest on every run. `priv/static/assets/` is gitignored,
    which is exactly why nobody noticed: the file on disk was from another day
    and another environment (`_build/dev/phoenix-colocated/…` appears in its
    source comments).
18. **Tauri will not copy this release into a bundle.** `bundle.resources`
    addressed `../_build/desktop/rel/confluence_phx_mirror` and the resource
    phase died with `Permission denied (os error 13)` — no path in the message,
    no root-owned file, no symlink, 25 GB free, and the same command succeeding
    with `resources: {}`. Bisected by emptying the config, not by guessing. The
    release is now copied in with one `ditto` after the shell is built
    (`scripts/lib/bundle.sh`), into the one place `main.rs` looks for it:
    `resource_dir()/rel/confluence_phx_mirror`, which is
    `Contents/Resources/rel/confluence_phx_mirror`. Two scripts build a bundle
    (`start-desktop.sh --app`, `package.sh`), which is why the copy lives in
    `scripts/lib/`.
19. **A check that could only ever fail.** The publishing workflow's boot check
    asked for `curl "$url/state"`: `/state` belongs to the tool's router under
    `/__tool`, and the address the release prints ends in a slash, so the request
    went to `//state`. Running it locally (`scripts/package.sh`) found it in one
    minute; a tag would have found it after the build. It asks for `/health` and
    `/__tool` now — both halves, and both real.
20. **`grep -q` under `pipefail` is a SIGPIPE, not a match.**
    `unzip -l … | grep -q …` exits 141: `grep` stops at the first match, `unzip`
    writes into a closed pipe, and `set -o pipefail` reports the writer's death as
    the pipeline's failure. The listing is compared with a `case` now. Same trap
    waits in any step that pipes a producer into `grep -q`.
21. **The Keychain is a dialog, and a dialog at boot is a tool that never starts.**
    Reading the token at boot (`Settings.apply_runtime_config/0` →
    `Credentials.fetch/1`) blocks the whole application start until somebody
    answers, and macOS *does* ask — for a copy of the app, because an ad-hoc
    signature gives the ACL nothing stable to trust it by. Measured on a copy in
    `/tmp`: the process sat in `SecKeychainFindGenericPassword` for minutes,
    printed no address, opened no window, and looked exactly like a broken build;
    the boot check passed because it only asks `/health`, which touches nothing.
    The token is read in `after_start/0` now — after the listener has printed the
    address — so the question has a window behind it, and answering *Always
    Allow* fixes it for good. Two traps in one: the boot path had blocking I/O in
    it, and the only way to see it was to run the *shipped* copy instead of the
    build tree.

## Next, in order

1. **One sync, not two.** Make `Sync.Gate`'s lease portable (a row updated with
   `UPDATE … RETURNING`, which both engines have, instead of `ON CONFLICT`) and
   let the tool's mirroring run through the server's workers. That would delete
   `Desktop.Mirror` and `Desktop.Jobs` and put `/admin/jobs` in charge — at the
   cost of proving the whole sync path on SQLite first.
2. **A test environment for `lib_desktop`**, so the tool's behaviour has tests and
   not only evidence rows, and a CI leg that compiles, dialyses and probes
   `MIX_ENV=desktop` (the probe is cheap: boot it, `GET` the screens). The same
   leg is what would put the FTS5 statement itself under test.
3. **Signing and notarisation** for the `.app`. The release half is wired —
   `CONFLUENCE_SIGN_RELEASE=1` makes `mix release` sign every BEAM binary and
   escript with `ElixirKit.Release.codesign/1` (ad-hoc without
   `APPLE_SIGNING_IDENTITY`, a real signature with it), and
   `src-tauri/App.entitlements` carries the four switches the BEAM needs under
   the hardened runtime. It stops there on purpose: **this project has no Apple
   Developer account**, so nothing here will be notarised, and the install path
   is what removes the friction instead — `install-desktop.sh` clears the
   quarantine flag on the copy it just made, and `docs/desktop-tool.md` gives the
   one-line `xattr` for a copy downloaded in a browser. Anything that promised
   more would need the account, not more code.
4. **Cypress harness** against `--in-browser`, with a demo *connector* (HTTP, not an
   in-process seed) so the same suite can run against the container image.

## Verifying anything, fast

```sh
MIX_ENV=dev     mix compile --warnings-as-errors     # server untouched
MIX_ENV=desktop mix compile --warnings-as-errors     # tool builds
MIX_ENV=desktop mix dialyzer                         # the tool's types: 0 errors
mix format --check-formatted                         # includes lib_desktop in its inputs
pgrep -fl "mix test" | wc -l                          # must be 0, and one mix at a time (trap 14)
mix test                                              # the whole suite
mix sobelow --exit                                    # security gate
scripts/start-desktop.sh --where                      # assets, release and window, then the workspace
scripts/start-desktop.sh                              # the debug window from the checkout
scripts/start-desktop.sh --app                        # the .app, built and opened
scripts/package.sh                                    # the .app the workflow publishes, built here
scripts/package.sh --install                          # …and installed into ~/Applications
```

The asset steps print about a second each once the toolchain is installed —
trap 17 is what a skipped one looks like. The release step prints `ok in 30–40s`
on a machine with nothing else building; that is the release copy (49 MB, 2 713
files), not a recompile. The window step prints `ok in 1–3s` when nothing changed
(trap 12 was 11–15 s, every launch).
`--app` is `cargo tauri build --bundles app` (six minutes cold, because it is a
release build of the window with LTO; a minute warm) followed by `open -W`, so
it returns when the window is closed.
By hand, if the app is already up: `RELEASE_DISTRIBUTION=none
_build/desktop/rel/confluence_phx_mirror/bin/confluence_phx_mirror start` prints
`desktop ui: http://127.0.0.1:<port>/`, and it is stopped by the owner of the
port (trap 7): `lsof -nP -iTCP:<port> -sTCP:LISTEN -t | xargs kill`.

To look at the screens without the window, `MIX_ENV=desktop mix run --no-halt`
prints the same address and serves the same routes.

A **copy** of the app is its own test, and the one a download is: unzip the
artifact somewhere else, `open -a` the copy, and find the sidecar it started from
inside *that* copy — `pgrep -fl "<copy>/Contents/Resources/rel"`, then
`lsof -nP -a -p <beam> -iTCP -sTCP:LISTEN`. It should have a loopback port within
a second, and `/health` should answer 200 (verified from `/tmp` on the built
artifact: `desktop ui:` at 0.1 s, `/health` 200, before trap 21 was fixed the
same run had no listener at all). The first launch of a copy also asks for the
keychain item `confluence-export`; while that question is up `/` and `/__tool`
wait for it, which is why `/health` is the one to curl.
