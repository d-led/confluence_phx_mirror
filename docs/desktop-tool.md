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
| shared, unchanged | `Web.Endpoint`, `Web.Router`, every LiveView, every controller, the admin area | the screens are the server's, served from a mount in the tool's own listener |
| shared behind a seam | `Export.Site` | reads its rows through `Export.Site.Catalogue` |
| shared, different adapter | persistence | the server's own schema, migrations and contexts; `{:array, _}` becomes JSON text |
| shared, different spelling | `Resources.database/0`, `Mirror.maybe_page/2`, `Accounts.matches_identity/1` | a catalogue vs a file; `LIMIT NULL`/`OFFSET` without `LIMIT`; `text[]` overlap vs `json_each` |
| forked | ingest loop | a small pipeline, not `Sync` |
| absent | `Mirror.Search` | the tool's store has no `search_vector` column, and the screen says so rather than failing |

The expensive part — turning Confluence's HTML into something a static archive
can serve — is already database-free, and it is shared. So is the whole reading
surface, because the tool mounts the server's endpoint rather than reimplementing
it (see "Screens" below).

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

## Getting it

The app is published as `Confluence Export.app`, zipped, by
`.github/workflows/desktop-release.yml`: every push builds one, kept 90 days, and
a `v*` tag attaches the same build to a release. Three ways in:

```sh
# the newest build of a branch, installed into ~/Applications
curl -fsSL https://raw.githubusercontent.com/d-led/confluence_phx_mirror/main/install-desktop.sh | sh

# from a checkout: the same build, written to _build/desktop/package/
scripts/package.sh

# or, if you would rather not run a downloader's script
open https://nightly.link/d-led/confluence_phx_mirror/workflows/desktop-release/main/confluence-export-macos.zip
```

**It is not signed, and it will not be.** Signing a macOS app that carries an
Erlang runtime needs a paid Apple Developer account, which this project does not
have. So the download is a plain unsigned bundle, and macOS objects to the first
launch of a copy it did not see you make:

* **Installed with `install-desktop.sh`:** nothing to do. `curl` does not set the
  quarantine flag the way a browser does, and the installer clears it anyway
  before it prints where the app went — on the copy it just installed, and
  nowhere else.
* **Downloaded in a browser:** unzip it, drag it to `/Applications`, then either
  right-click → **Open** once, or clear the flag yourself:

  ```sh
  xattr -rd com.apple.quarantine "/Applications/Confluence Export.app"
  ```

  macOS 15 and later removed the right-click bypass for unsigned apps: the
  System Settings → Privacy & Security → *Open Anyway* button is the equivalent,
  and the `xattr` line works the same as it always has.

## Layout

```
lib_desktop/
  desktop/
    application.ex          the tree: the server's, less what has no peer here
    setup.ex                migrations before the first query
    settings.ex             the site, the account and the folder, from a file
    credentials.ex          the token, in the OS keychain (NIF, see native/)
    credentials/keyring.ex  the real store
    credentials/memory.ex   the test double
    archive.ex              the export: Export.site_archive → one file
    jobs.ex                 the one mirror run, so a screen can follow it
    mirror.ex               Source → Renderer → rows, straight into the catalogue
    spaces.ex               the source's space list, fetched off the request
    web/server.ex           the loopback listener, on an ephemeral port
    web/dispatch.ex         /__tool here, the server's endpoint everywhere else
    web/tool.ex             the tool's own screens: connection, spaces, run, export
    web/page.ex             those screens' markup, as strings
```

Everything under `web/` is small on purpose; the reading surface is not here at
all, because it is the server's (`lib/confluence_phx_mirror_web/`).

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

## Screens

There is one origin. `Desktop.Web.Dispatch` answers `/__tool` and everything under
it from the tool's own small router, and hands every other path to
`ConfluencePhxMirrorWeb.Endpoint` — mounted, not started, so the window's pages,
its websocket and the tool's form share a port, a cookie jar and a `Host`.

What that buys is that the window opens on the mirror: `/` is the server's home
page, `/spaces` its directory, `/admin` its cockpit, `/admin/settings` the same
settings page an operator changes a theme on. Nothing is re-rendered, so nothing
can drift.

Two things are the tool's own, and they are the tool's own because a deployment
does not have them:

| path | what | why not the server's |
| --- | --- | --- |
| `/__tool/setup` | where the site is, and the token that reaches it | a release takes these from `CM_*` and `SECRET_KEY_BASE`; the tool has a window to ask in, and stores the secret in the OS keychain |
| `/__tool/spaces`, `/__tool/mirror` | the space list, and a run that copies a space into the catalogue | the server's sync goes through Oban and a sync gate written in Postgres; the tool's copies straight into the catalogue, which is the path that is proven on SQLite |
| `/__tool/export` | the archive, as one file | the deployment's is a download from an admin screen; the tool's is a file that lands beside the catalogue |

The admin area is reachable because the tool has one reader and the window is the
only way in: `:auto_admin` makes that reader an administrator, so `/admin` is one
click from the mirror. The account menu carries one extra entry (`Desktop…` →
`/__tool`) when `:desktop_tool` is set, which only `config/desktop.exs` does — for
a deployment nothing renders and nothing changes.

Unconfigured, `/` answers with the connection form rather than redirecting: a
first run has one screen worth showing, and the form is a page, not a detour.

## Boot

`Desktop.Application` is the server's list, less what has nothing to coordinate
here:

```elixir
children = [
  ConfluencePhxMirror.Repo,
  ConfluencePhxMirror.Desktop.Setup,          # migrations, before the first query
  {Phoenix.PubSub, name: ConfluencePhxMirror.PubSub},
  ConfluencePhxMirror.Mirror.Counters,
  ConfluencePhxMirror.MetricsHistory,
  ConfluencePhxMirror.Resources,
  ConfluencePhxMirrorWeb.Telemetry,
  ConfluencePhxMirror.Sites.Guard,
  ConfluencePhxMirror.Mcp.Markdown,
  ConfluencePhxMirror.SpaceDirectory,
  {Task.Supervisor, name: ConfluencePhxMirror.Export.TaskSupervisor},
  ConfluencePhxMirror.Export.Artifact,
  ConfluencePhxMirrorWeb.Presence,
  ConfluencePhxMirror.RateLimit,
  rate_limiter_spec(),
  ConfluencePhxMirror.Confluence.Traffic,
  {Oban, Application.fetch_env!(:confluence_phx_mirror, Oban)},
  ConfluencePhxMirror.Sync.Log,
  ConfluencePhxMirror.Sync.Runs,
  {Task.Supervisor, name: ConfluencePhxMirror.Desktop.TaskSupervisor},
  ConfluencePhxMirror.Desktop.Jobs,
  ConfluencePhxMirror.Desktop.Spaces,
  ConfluencePhxMirrorWeb.Endpoint,            # server: false — the listener is below
  {ConfluencePhxMirror.Desktop.Web.Server, port: port}
]
```

Left out, each for a reason: `DNSCluster` (one node, no peers), the two
`Sync.Scheduler` clocks (the tool mirrors when somebody presses the button), and
`Sync.StartupPull` (a first run has no credentials yet).

`Blobs.LocalStore` is not in that list because it is not a process: it is a
plain module that `Blobs.Store` dispatches to through `impl/0`. The desktop build
only has to point `Store` at it, with a root under the data directory.

The endpoint runs with `server: false`. It still starts everything it owns — the
configuration cache, the socket transports, the static manifest, the drainers —
and `Desktop.Web.Server` accepts the connections and calls `Endpoint.call/2`.
That is also why the port is chosen before the supervisor starts: the endpoint
reads its URL once, when it starts, and a screen generating an absolute link
needs the port the listener will actually get.

Oban runs on `Oban.Engines.Lite`, because the store is a file; the queues are one
process each, because one SQLite connection cannot feed fourteen consumers.

`ConfluencePhxMirrorWeb.Skins.validate!/0` is called first, as the server does,
so a misspelt skin name stops the boot rather than quietly serving the default.
After the tree is up the tool does what the server does — load `Settings` and
`SiteSettings` once, configure the mailer, settle jobs left `executing` by the
last shutdown.

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
