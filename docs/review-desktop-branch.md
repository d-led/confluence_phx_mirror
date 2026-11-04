# Review: `desktop` → `main`

Written after the work was finished, by reading the whole diff against `main`
rather than the last commit. What follows is (1) what the diff is, (2) every
change that reaches the deployment and what could go wrong with it, (3) what is
provably untouched, (4) what to watch on the first deploy, and (5) what was
verified and what was not.

    git fetch origin main
    git diff --stat origin/main...HEAD      # 96 commits, 157 files, +19 307 −384

Two halves, and only one of them is deployed:

| half | files | lines | deployed |
| --- | --- | --- | --- |
| `lib/`, `config/`, `priv/`, `.github/`, `scripts/` | 82 | +3 392 −324 | **yes** |
| `lib_desktop/`, `src-tauri/`, docs for the window | 75 | ~+15 900 | no — compiled only for `MIX_ENV=desktop` |

`lib/` never names a `Desktop.*` module. A release built from this branch does
not contain any of `lib_desktop/`.

## 1. Production-facing changes, and what could go wrong

### `Mail.Budget.reserve/1` — the ledger's clock moved from SQL to Elixir

`current_date` and `now()` became `Date.utc_today/0` and `DateTime.utc_now/0`
(for SQLite, which has neither). Same statement, same partial `ON CONFLICT`.

* Could go wrong: if the app's clock and the database's disagree across midnight,
  a message can land in the neighbouring day's allowance. Bounded by one day's
  limit and by `mail_sends` being a ledger, not a queue.
* Watch after deploy: send a test message and read the day's count on `/admin`.
* Covered by: `test/confluence_phx_mirror/mail/` (9 tests, both engines).

### `Query.paged/3` — an offset with no limit is now no window at all

Five places applied `limit_if(limit)` and `offset(n)` separately. Postgres reads
`OFFSET n` on its own; SQLite calls it a syntax error. Now the two go together or
neither does.

* Could go wrong **on Postgres**: a caller that passes `offset:` without
  `limit:` used to skip `n` rows and now gets all of them. Checked every caller
  — the admin users and groups lists, the catalogue screens, the API's
  `start`/`limit` pairs and the identities window — all pass both, or neither.
* Covered by: the admin, catalogue, API and identities suites on both engines.

### `Mirror.Page.changeset/2` — a slug with no ASCII words is `""`, not `NULL`

A Cyrillic or CJK title has no segment to slugify. The column stays nullable on
Postgres; the value written is now `""` instead of `NULL`.

* Could go wrong: a query or view that treats `NULL` and `""` differently. None
  does — `grep -rn 'is_nil(p.slug)\|slug IS NULL' lib/` is empty, and
  `slug_match?/2` and the URL helper already rendered both the same.

### `Mirror.Attachment.confluence_id` — an id type that accepts both spellings

`field :confluence_id, Ecto.IdString` where it was `:string`. `type/0` is
`:string`, so the Postgres column, dumps and loads are unchanged; the type only
refuses less (a store with integer affinity hands a numeric id back as a number).

* Could go wrong: nothing on Postgres — `cast/1` and `load/1` accept the binary
  they always accepted.

### `Mirror.all_nodes/1` — `has_children` is normalised to a boolean

`EXISTS` is `true`/`false` on Postgres and `1`/`0` on SQLite. The normaliser
runs on both and leaves Postgres's value alone.

* Could go wrong: a third spelling would crash the match. There are two, and both
  are tested.

### `Sites.check/0` — an unrecorded database is recorded on the first write

`verify!/0` (boot, and before every sync) still records or raises; the new
`check/0` answers `:unrecorded | :ok | :no_schema | {:conflict, …}` for a window
that has nobody to ask. On the deployment the database is already recorded, so
`check/0` returns `:ok` and `verify!/0` raises the same message it always did.

* Could go wrong: only on a *fresh* deployment database, where the recording is
  now deferred from boot to the first write. Nothing reads the row before a
  write, and `mix mirror.site` still prints it.

### `.github/workflows/ci.yml` — a second job, `test-sqlite`

Runs `scripts/test-sqlite.sh` beside the Postgres job, not after it.

* Could go wrong: a required check that flakes. SQLite has one writer, so the
  script runs `--max-cases 1`; it is slow (minutes) and deterministic. If the
  job proves flaky on the runner, it can be dropped without touching `lib/`.
* Not yet proven: the job has not run on GitHub — only locally on macOS arm64.

### `Sync.start_run/5` — a retried job continues its run

An attempt that failed leaves its row; the retry of the same `job_id` resumes it
(`stats["attempts"]` counts up, the failure moves to `stats["failed_attempts"]`).
One press is one job is one run — and the failing attempt's log lines stay under
the run they belong to.

* Could go wrong **on Postgres**: a job re-run much later — a manual retry through
  `/admin/jobs` a day after the failure — would find the old failed row and
  continue it, so the run's `started_at` is the first attempt's. Only the newest
  failed run of that `job_id` is chosen, and Oban ids are not reused, so this
  cannot cross jobs.
* Covered by: `test/confluence_phx_mirror/sync/retried_run_test.exs`.

### `Sync.Log.add/3` — a console write cannot fail its caller

`Logger` re-raises a handler's crash, and a handler that writes to a closed pipe
raises `:badarg` inside whichever process logged — which is how a sync died.
The write is now a boundary: a line that cannot reach the console still reaches
the ring.

* Could go wrong: a real `Logger` fault would now be silent. What the screens
  read is the ring and the run's record, so the loss is a console line.
* Covered by: `test/confluence_phx_mirror/sync/log_test.exs`
  (`Test.GoneConsole` raises from `log/2`).

### `Sync`: three errors that were being swallowed (audit)

Found by reading every `rescue`/`catch`/error-to-value branch in `lib/`:

* **A page's read restrictions that could not be read became "no restrictions".**
  `apply_restrictions/2` had `{:error, _reason} -> :ok`, and an empty
  `page_restrictions` set means *anyone signed in may read the page*. A transient
  failure (rate limit, 5xx) therefore finished a restricted page as an open one,
  and the details mark said it was done. The page is now left alone — its old
  restrictions stay, its details are not written, and it stays in the backlog
  for the next run — and the run records the page and the reason.
  * Could go wrong: a source that answers `{:error, …}` for pages it *can* serve
    would now leave those pages without details. `HttpSource` returns
    `{:ok, []}` for a page with no restrictions, so the two are distinguishable.
  * Covered by: `test/confluence_phx_mirror/sync/page_failure_test.exs`.
* **One crashing page killed the whole run, and the record could not say which.**
  The detail pass fans pages out to linked tasks, so a raise in one killed the
  run's process (`{:exit, reason}` never reached the reduce), and the branch that
  would have recorded it wrote `page: nil`. Each page's work is now wrapped: a
  crash is that page's error, with its frames (`stats["errors"]["trace"]`), and
  the run goes on.
  * Could go wrong: a systemic failure (a broken store, no disk) now surfaces as
    one error per page instead of one failed run — noisier, but the run reports
    `partial` rather than dying, and the count is visible.
  * Covered by: the same file (a source whose comments call raises).
* **A blob whose age could not be read was "age zero", which is 1970** — the
  sweep deletes by age, so an unreadable timestamp made a file a candidate. The
  store reports `:unknown` and the sweep skips it.
  * Covered by: `test/confluence_phx_mirror/blobs/unreadable_age_test.exs`.

Checked and deliberately left alone: `attachment_controller` collapsing every
lookup failure to 404 (that is what a 404 is for), `build_info` reading a broken
JSON file as "no build information", and the space picker's typeahead answering
`[]` when a keystroke finds nothing — the screen already hides the form and
reports an unreachable site when the listing itself fails, so a second error
branch there would be dead code.

### Still open: a page is visible before its restrictions are known

A page's **row** is written by the listing pass, before the detail pass reads who
may read it, and "no `page_restrictions` rows" means open. So for a brand-new
restricted page the run leaves a window — one run — in which the page exists with
title and storage body but no restrictions. The audit above narrows that window
to "until its details land" (it is retried, and no body is rendered while
`details_synced_at` is nil), but closing it properly needs the visibility rule to
say "restrictions not read yet ⇒ not readable": a `restrictions_synced_at`
column, a backfill from `details_synced_at` so existing pages do not vanish, and
the authorization check to refuse `:unknown`. That is a migration touching every
page's visibility and is not part of this branch.

## 2. What is provably untouched

* **The adapter.** `Repo` reads `Application.compile_env(:confluence_phx_mirror,
  :repo_adapter, Ecto.Adapters.Postgres)`. Only `config/desktop.exs` and
  `config/test.exs` set it, so a release compiles with `Ecto.Adapters.Postgres`
  exactly as before. Same for the two list types.
* **The Postgres DDL in `priv/repo/migrations`.** 17 existing migrations were
  edited; every edit wraps the previous statements in
  `if ConfluencePhxMirror.Migration.postgres?()`. The statements inside are
  character-for-character the ones that were there (compare
  `git diff origin/main...HEAD -- priv/repo/migrations` — every removed line
  reappears, re-indented, inside the guard). Applied versions do not re-run.
* **Deploy:** no DDL on Postgres. The only two new migrations are `:ok` on
  Postgres: `create_pages_full_text` (an FTS5 table, SQLite's index) and
  `allow_service_tokens_on_sqlite` (a table rebuild, SQLite's `ALTER COLUMN`).
* **The site guard.** `Sites.Guard` still starts with its default (`:stop`) on
  the server, and `verify!/0` still raises the same message for a database that
  belongs to another site.
* **The sync never deletes.** `Trash.forget/2` is called from two buttons — the
  admin spaces screen and the tool's Forget — and from nothing in `Sync`.
  `sync/space_scope.ex` is unchanged against `main`, so a resync still imports
  only what the workspace is configured for and removes nothing.
* **`config/prod.exs`** gained a comment; **`rel/env.sh.eex`** now defaults
  `RELEASE_DISTRIBUTION` instead of forcing `sname` on the local branch a
  deployment never takes.

## 3. The tool's mirror (not deployed, but the reported bug)

Before this branch's last two commits, the window ran its own copy of the sync
loop: a `Task`, no `oban_jobs` row, no `sync_runs` row, no cancel, dead when the
window closed. A press now enqueues a `SpaceWorker` — the server's worker — and
the window reads the run back:

    press ENG   → oban_jobs row + sync_runs row (mode space, trigger "the desktop tool")
    mirror all  → one job per space, run one after another, "queued: N" while it works
    cancel      → queued jobs cancelled, run cancelled, cancel_requested_at set
    space=NOPE  → 409, "the site has no space called NOPE", nothing enqueued

Proof: a headless run of the tool (sandboxed `HOME`, throwaway catalogue, the
bundled demo source), inspected through the tool's own HTTP screens and the
catalogue's `oban_jobs`/`sync_runs` rows.

### The token belongs to the site, not to the machine

Reported after the above: the token was stored under one constant account, and
the setup form rendered it back into its own `value=` attribute. Change the site
URL in that form, press save, and a token typed for `acme.atlassian.net` is
stored again and then sent to whatever address is in the box.

Three changes, because one was not enough:

* the credential-store account carries the site — `workspace:<normalised base
  URL>`, where `ConfluencePhxMirror.SiteUrl.normalize/1` (new, in `lib/`, unit
  tested) is the one spelling of an address: case, a trailing slash or a
  scheme's own port do not make a second site, while a path does. A token is
  therefore never *found* for an address it was not stored for.
* the secret is resolved against the site **being saved**, so a blank field means
  "keep this site's token", and a changed site answers `{:error,
  :secret_required}` with nothing written — not even the new URL.
* `CM_ATL_TOKEN` counts only for the site in `CM_CONFLUENCE_SITE`: the two
  arrive together, and a provisioned token is not a token for a URL a person
  types.

The form no longer renders the stored secret at all (a secret in a page's HTML is
a secret in a screenshot, in a cache, and in the next submission); blank keeps
it, and the hint says a token belongs to the site above it. A token stored under
the old constant account — this machine's, before the update — is moved to the
site the settings file names, once, at boot (`Settings.adopt_legacy_secret/0`),
and the old entry is deleted.

Proven against the real `Settings` code with the in-memory credential store:

    account for A            "workspace:https://acme.example/wiki"
    account for A + "/"      "workspace:https://acme.example/wiki"   (one site)
    configure A / TOKEN-A    :ok, secret() == {:ok, "TOKEN-A"}
    re-save A, blank         :ok, A keeps its token
    change to B, blank       {:error, :secret_required}
      site unchanged, A's token unchanged, nothing stored for B
    B with TOKEN-B           :ok, secret() == {:ok, "TOKEN-B"}
    back to A, blank         :ok, secret() == {:ok, "TOKEN-A"}
    forget                   this site's token is gone

No part of this is in the deployment: `SiteUrl` is shared `lib/`, and everything
else is `lib_desktop/`.

## 4. On the first deploy, watch

1. `fly logs` for the boot line and for a `Sites` conflict — the one failure that
   would stop a boot, and the one that has not changed.
2. `/admin` once: the run list renders, the database card says Postgres, the
   tablespace footnote is there.
3. A test message through `/admin/settings` (the mail ledger's new clock).
4. One space sync: `sync_runs` gets a row with `trigger`, and `/admin/jobs` shows
   the Oban job.
5. The reader's `/search`: full text still answers, snippets included.

## 5. What was verified, and what was not

Run on this branch:

| check | result |
| --- | --- |
| `MIX_TEST_PARTITION=2 mix test` (Postgres) | **1968 passed, 7 excluded** (the scale suite) |
| `scripts/test-sqlite.sh` (SQLite) | **1900 passed, 75 excluded** (scale + `:postgres_only`) |
| `mix lint` (compile, format, credo strict, sobelow, unused deps) | clean |
| `MIX_ENV=desktop mix compile --warnings-as-errors` | clean |
| `MIX_ENV=desktop mix dialyzer` | **0 errors** |
| the tool, headless: mirror, bulk run, cancel, unknown space | as listed in §3 |
| `actionlint .github/workflows/ci.yml` | clean |

Not verified:

* **`lib_desktop/` has no unit tests.** The tool is proven by running it (above)
  and by dialyzer, not by a test file. Adding a `MIX_ENV=desktop` leg to CI is
  the next item in `docs/desktop-handoff.md`.
* **The new `test-sqlite` CI job has not run on GitHub.** It is the same script
  that is green locally, on a cold `_build/sqlite`.
* **`:postgres_only` is a judgement, not a measurement.** It excludes 68 tests
  from the SQLite job: the deployment's search (CQL, comment hits, Postgres's
  recall inside a word), the manual migrations, and the tablespace card. If one
  of them turns out to hold on SQLite too, the tag should come off — the list is
  `grep -rn postgres_only test/`.
* **Nothing here was deployed.** The deploy checklist above is a plan.
