# The desktop export tool

A second way to run this code: a self-contained app that reads a Confluence site
and writes a static archive — no server, no Postgres, no browser session, no
credentials on somebody else's machine.

Some people do not want a mirror. They want their content in a folder.

The first requirement is that the server does not notice. That constrains every
choice below, and where a choice would have made the desktop tool easier at the
server's expense, the desktop tool takes the harder road.

## What the two builds share

| | Module | Why |
| --- | --- | --- |
| shared, unchanged | `Confluence.Source`, `Confluence.HttpSource`, `Confluence.DemoSource` | the pipeline talks to a behaviour and gets plain DTOs |
| shared, unchanged | `Sync.Renderer` | `export_view` → sanitised HTML, link rewriting, macros |
| shared, unchanged | `Export.Markdown` | HTML → Markdown, front matter, attachment links |
| shared, unchanged | `Export.Site.{Content,HTML,Chrome}` | page documents, archive layout, theme shell |
| shared, unchanged | `Export.Zip` | streaming archive writer |
| shared, unchanged | `Blobs.{Key,LocalStore}` | attachments as files |
| shared, unchanged | `Mirror.{Page,Space,Attachment,Comment}` structs, `Web.Skins`, `Mirror.URLs` | plain data and pure functions |
| shared behind a seam | `Export.Site` | reads its rows through `Export.Site.Catalogue` |
| shared, different adapter | persistence | the server's own schema, migrations and contexts; `{:array, _}` becomes JSON text |
| forked | ingest loop | a small pipeline, not `Sync` |
| absent | `Mirror.Search`, `Authorization`, `Accounts`, `Oban`, `Endpoint`, admin | the tool has one user, no permissions, no queue, no web layer |

The expensive part — turning Confluence's HTML into something a static archive
can serve — is already database-free, and it is shared.

## The boundary is the build, not the adapter

There is a tempting design in which one repository serves both engines and a
strategy is chosen at runtime by asking the repo which adapter it has. It is the
wrong trade here, for three reasons.

It is a branch the server never takes, in code the server ships. It costs every
test on both sides, because neither build exercises the other's queries.

It solves the wrong problem. Query builders are the easy half; the hard half is
*types* — `pages.labels` is `{:array, :string}` and `ecto_sqlite3` raises on
`{:array, _}` at load time. A strategy that varies SQL but not schemas does not
compile.

It gives up the strongest guarantee available: that the server's binary does not
contain the desktop code at all.

`MIX_ENV` gives that guarantee for free. `:desktop` is a fourth environment
alongside dev, test and prod. It compiles `lib_desktop/`, pulls `ecto_sqlite3`,
and boots a different supervision tree. Dev, test and prod never see any of it.

## Step 0 — the compile-only spike

Do this before designing a schema. It takes an hour and it replaces assumptions
with a list.

```elixir
# mix.exs
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(:desktop), do: ["lib", "lib_desktop"]
defp elixirc_paths(_), do: ["lib"]
```

Add an empty `lib_desktop/desktop/application.ex`, then:

```
MIX_ENV=desktop mix compile
```

Everything that fails to compile names a dependency on something the desktop
build does not have. That output is the real reuse list — `Skins.validate!/0`,
`Settings`, `SiteSettings`, `Publishing`, any module that reaches for `Repo` at
call time rather than through a seam. Do not guess this list; produce it.

The spike is the deliverable of the first day, and it is thrown away.

## Layout

```
lib_desktop/
  desktop/
    application.ex          the tree: repo, blobs, rates, one task supervisor
    repo.ex                 use Ecto.Repo, otp_app: :confluence_phx_mirror
    supervisor.ex           the ingest pipeline, one run at a time
    paths.ex                the per-user data directory and everything under it
    ingest.ex               Source → Renderer → rows
    ingest/page.ex          one page, end to end
    ingest/attachment.ex    bytes to the blob store
    catalogue.ex            Export.Site.Catalogue over SQLite
    export.ex               Catalogue → Export.Site → zip
```

Two modules carry all the risk, and both are small: `Ingest` and `Catalogue`.
Everything else is configuration.

## Configuration

`mix.exs` gains four things, all additive:

```elixir
{:ecto_sqlite3, "~> 0.17", only: :desktop},
{:burrito, "~> 1.0", only: :desktop, runtime: false},

mod: {application_module(Mix.env()), []},

defp application_module(:desktop), do: ConfluencePhxMirror.Desktop.Application
defp application_module(_), do: ConfluencePhxMirror.Application
```

and the `elixirc_paths/1` clause above.

`config/desktop.exs` is picked up by the standard environment import at the foot
of `config/config.exs`. It configures the repo with a file under the user's data
directory, not `var/`:

```elixir
config :confluence_phx_mirror,
  ecto_repos: [ConfluencePhxMirror.Repo],
  repo_adapter: Ecto.Adapters.SQLite3

config :confluence_phx_mirror, ConfluencePhxMirror.Repo,
  database: Path.join(data_dir, "catalogue.db"),
  journal_mode: :wal,
  pool_size: 1

# The same directory holds the mirrored attachments.
config :confluence_phx_mirror, :blob_store, ConfluencePhxMirror.Blobs.LocalStore
config :confluence_phx_mirror, :blob_root, Path.join(data_dir, "blobs")
```

There is one repo module, not two. Which *adapter* it uses is decided when an
environment compiles — `use Ecto.Repo` fixes the adapter into the generated code,
so `MIX_ENV=desktop` builds `ConfluencePhxMirror.Repo` on SQLite and every other
environment builds the same module on Postgres. Where the *database* is, is
start-time configuration: `Desktop.Settings.apply_runtime_config/0` writes
`:database` from the chosen folder before the repo starts, so a release can be
pointed at a different workspace without being rebuilt.

`pool_size: 1` is not timidity. SQLite has one writer, the ingest is the only
writer, and a pool that allows a second connection only discovers the lock
contention later.

`config/runtime.exs` runs for `:desktop` too. Its `config_env() == :prod` blocks
are skipped, but anything unconditional there — a `DATABASE_URL` that
reconfigures the repo, a `SECRET_KEY_BASE` requirement — will still execute and
will override the file above. Guard those reads with the environment rather than
assuming only prod reaches them.

## Boot

`Desktop.Application` is a short list, and it is short on purpose:

```elixir
children = [
  ConfluencePhxMirror.Repo,
  {Task.Supervisor, name: ConfluencePhxMirror.Desktop.TaskSupervisor},
  ConfluencePhxMirror.Desktop.Jobs,
  ConfluencePhxMirror.Desktop.Spaces,
  ConfluencePhxMirror.Desktop.Web.Server
]
```

`Blobs.LocalStore` is not in that list because it is not a process: it is a
plain module that `Blobs.Store` dispatches to through `impl/0`. The desktop build
only has to point `Store` at it, with a root under the data directory.

No `Oban`, no `Endpoint`, no `DNSCluster`, no `Presence`, no `Counter` caches.
`RateLimit` and `Traffic` are ETS; `HttpSource` uses them and they start standalone.

The one boot-time wart is `ConfluencePhxMirrorWeb.Skins.validate!/0`, which the
server calls to fail fast on a misspelt theme name. The archive needs the theme,
so the desktop app calls it too — but it, and `Settings`/`SiteSettings`, hold
`:persistent_term` values the server loads from the database. Desktop loads the
same keys from constants. The spike will say exactly which keys, because the
compiler will point at each read.

## Storage

The desktop uses the server's schema. There is one set of migrations, in
`priv/repo/migrations`, and it builds the same tables on both storages — so the
tool queries `Mirror.Page`, `Mirror.Space` and the rest unmodified, and a context
written for the server is a context the tool can call. A second schema was tried
and deleted: two definitions of one schema drift, and every query would have had
to be written twice.

Two constructs have no SQLite equivalent, and `ConfluencePhxMirror.Migration`
holds both: the `{:array, _}` column type, which SQLite stores as JSON text, and
the Postgres index access methods and extensions. `ConfluencePhxMirror.Schema.JSONList`
is the Ecto half of the same decision — the schemas read `:string_list_type` when
they compile, so a list column and its storage agree by construction, and a
server build still gets `text[]`.

`labels` and `ancestors` are JSON text rather than a join table because the
export path reads them as a list and never filters by them. The archive's label
index is built by walking pages, not by querying labels.

Dates stay `:utc_datetime`. The application is UTC-only by invariant already.

One line of the exporter is not portable: `Export.Site.Search` selects
`fragment("left(coalesce(?, ''), ?)")`, and `left()` does not exist in SQLite.
It becomes `substr(...)`. That function belongs with its query — behind the
seam — so the server keeps `left()` and desktop keeps `substr()`.

## The export seam

`Export.Site` and its children are ~90% of the value and they currently read
through `Repo` and `Authorization`. The seam is one behaviour and one option:

```elixir
defmodule ConfluencePhxMirror.Export.Site.Catalogue do
  @callback spaces(Scope.t()) :: [Space.t()]
  @callback pages(Space.t(), Scope.t()) :: [map()]
  @callback attachments(integer(), Scope.t()) :: [Attachment.t()]
  @callback comments(integer(), Scope.t()) :: [Comment.t()]
  @callback can_read_space?(Scope.t(), Space.t()) :: boolean()
end
```

`Export.Site.archive/3` takes `:catalogue`, defaulting to
`Export.Site.PostgresCatalogue`, which is today's queries moved rather than
rewritten.

The behaviour is written by moving the Postgres implementation first and letting
the compiler find the call sites. That is the point: the existing export tests
are the proof, and they must pass unchanged after the move.

## Ingest

`Sync` cannot be reused, and it should not be bent to fit. It is built on
`SyncRun` rows, `Sync.Gate` leases, Oban uniqueness and per-node counters —
machinery that exists because many workers share one catalogue. The desktop tool
has one worker and one catalogue.

`Desktop.Ingest` is a plain pipeline:

```
spaces(Source) → for each selected space, in order:
  pages(Source) → Task.async_stream, bounded, timeout: :infinity
    → Renderer → Desktop.Page.upsert
    → attachments → Blobs.LocalStore
    → comments
```

Concurrency is bounded by the existing `RateLimit` and `Traffic` modules, so the
tool is a good citizen of the Confluence API for the same reasons the server is.

Two things the mirror does that the tool must copy, because they are what make a
long download survive: write each page as it arrives, and record what has been
done so an interrupted run resumes rather than restarts.

## Testing

Three layers, and the middle one is the reason this design is cheap:

**Desktop unit tests** — `test_desktop/`, their own alias, their own SQLite
database in a temp dir. The schema, the upserts, the resume behaviour, the
`substr` excerpt.

**The parity test** — the one that matters:

> Export the bundled demo snapshot through the server's exporter and through the
> desktop tool's. The zip entry lists are identical, and so is every entry's
> bytes.

Both sides have `DemoSource`, so this costs a fixture and no network. It is what
stops the two implementations drifting, and it will fail the first time somebody
changes one `Export.Site` code path without the other.

**The server's suite**, unchanged, is the regression test for the seam.

`mix complexity` names two paths today. `lib_desktop` joins them, or the new
code is the one place nobody measures.

## Packaging

`Burrito` compiles the app and the runtime into one binary per target.

`Tauri` is a window and a `Command` sidecar: it starts the binary, reads a port
and a one-time token from its stdout, and points a webview at
`http://127.0.0.1:<port>/?token=…`. The same origin the token protects is what
makes `file://` restrictions irrelevant — the archive is written by the app, not
viewed in the webview.

The real packaging risk is not Tauri. It is `exqlite`, a C NIF, under Burrito's
cross-target build. If it fights, build one binary per OS on that OS in CI:
same release, three jobs, no QEMU.

The binary must carry built assets — `priv/static/assets/css/app.css` and the
archive favicon — because there is no npm at runtime.

## Sequence

| | Work | Size | Server touched |
| --- | --- | --- | --- |
| 0 | compile-only spike | 0.5 d | no |
| 1 | `MIX_ENV=desktop` booting a SQLite repo, empty migration | 1 d | no |
| 2 | schema, migrations, `Desktop.Ingest` of the demo snapshot | 1.5 d | no |
| 3 | real ingest through `HttpSource`: spaces, pages, attachments, resume | 2 d | no |
| 4 | extract `Export.Site.Catalogue`; Postgres impl moved, tests unchanged | 1 d | **yes, by move only** |
| 5 | `Desktop.Catalogue` + export + the parity test | 1.5 d | no |
| 6 | Burrito binary | 1 d | no |
| 7 | Tauri shell, port and token | 1 d | no |

Steps 0–3 give a CLI that mirrors a site into SQLite. Steps 4–5 give an
exporter. Steps 6–7 make it double-clickable.

Step 4 is the only one that touches server code, it is a move rather than a
rewrite, and the existing export tests are what proves it.

## Not in v1

Search inside the tool. The archive already ships a matcher that runs from a
folder with no server — `Export.Site.Search.script/0` — and that is the search
the user gets. A local index only earns its place if the tool grows a search
screen over the catalogue before export; then it is an FTS5 virtual table behind
the same seam, never in front of it.

Also absent on purpose: authentication, permissions, admin, multi-user editing,
scheduling, and anything that would let one person's copy see another's.
