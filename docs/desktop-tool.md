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

### One dependency the tool's build cannot have

`argon2_elixir` — the Argon2id hasher behind issued API tokens — has no Windows
build: its Makefile has no Windows branch at all, so there is no `-shared` and the
result is named `.so`, and the link dies with `undefined reference to WinMain`.
There is no newer release. The tool must build on Windows, so `:desktop` leaves
the library out, and `config/desktop.exs` says so by naming no hasher.

The difference is one module: `Accounts.TokenHash.Hasher`. Where the library is
compiled it is Argon2id, unchanged; where it is not, `hash/1` stores a word that no
token can match (deliberately not a weaker digest, which would verify) and
`verify/2` answers `false` for any digest it cannot compute — the same answer a
wrong token gets. The tool issues no tokens: one local reader, no sign-in, no API
clients. `test_desktop/` pins both halves of that.

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

The app is published by `.github/workflows/desktop-release.yml`: every push
builds one per platform, kept 90 days, and a `v*` tag attaches the same builds to
a release. One line installs it, the same line on macOS and Linux and its
PowerShell twin on Windows:

```sh
# macOS (Apple silicon): Confluence Export.app into ~/Applications
# Linux (x86_64): the tool into ~/.local/share/confluence-export, launcher in ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/d-led/confluence_phx_mirror/main/install-desktop.sh | sh
```

```powershell
# Windows (x64): into %LOCALAPPDATA%\Programs\Confluence Export, with a Start Menu entry
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/d-led/confluence_phx_mirror/main/install-desktop.ps1 | iex"
```

The scripts take the newest build of `main` through `nightly.link`, and they say
what they did: what arrived, where it went, what is missing (the Linux one asks
the loader whether GTK 3 and WebKitGTK 4.1 are there, and names the `apt` line if
they are not). Neither reads standard input, neither retries more than three
times, and each ends with a sentence rather than a stack. What they unpack is two
layers, because `nightly.link` wraps the artifact in a zip of its own and the
macOS and Linux artifacts **are** archives — a line that assumed one layer
installed nothing and said the app was missing, which is how this was found.

From a checkout, or by hand:

```sh
# the same build, written to _build/desktop/package/
scripts/package.sh

# or, if you would rather not run a downloader's script
open https://nightly.link/d-led/confluence_phx_mirror/workflows/desktop-release/main/confluence-export-macos.zip
```

**It is not signed, and it will not be.** Signing a macOS app that carries an
Erlang runtime needs a paid Apple Developer account, which this project does not
have. That is not the same as unusable: the linker ad-hoc signs every arm64
binary it produces (`flags=0x20002(adhoc,linker-signed)`), which is what the
platform requires before it will execute one at all. What blocks a download is
the **quarantine flag**, and it blocks it early — before any approval dialog,
which is why right-click → *Open* is not a way through for a bundle that was
never notarised. Clear the flag:

```sh
xattr -rd com.apple.quarantine "/Applications/Confluence Export.app"
```

Where that is needed, and where it is already done:

* **Installed with `install-desktop.sh`:** nothing to do. `curl` does not set the
  flag the way a browser does, and the installer clears it on the copy it just
  made if it ever arrives with one — on that copy, and nowhere else.
* **Downloaded in a browser:** unzip it, drag it to `/Applications`, then run the
  line above. Terminal is not quarantined itself, so it can clear the flag for
  anything you point it at. (macOS 27 here; the Control-click bypass has been
  gone since 15, and for a never-notarised app it was never the reliable route.)
* **Built from source:** `scripts/package.sh`, which leaves the app in
  `_build/desktop/package/` — no download, no flag.

**It asks once for the keychain.** The token that signs in to Confluence is kept
in the login keychain, not in a file, so the first launch of a *copy* — a build
downloaded, an app dragged to a new folder — gets the system's question about the
item `confluence-export`, because an ad-hoc signature gives macOS no identity to
recognise a copy by. Answer *Always Allow* once and it never asks again. The
window is already open when the question appears: the token is read after the
listener has printed the address the window is opened on, not before it, which is
what makes the question answerable instead of a tool that looks dead.

**One token per site, and never one site's token for another.** The keychain item
is `confluence-export` with the site as its account — `workspace:https://…`, the
base URL normalised so a trailing slash or a capital letter is the same site — so
a token is only ever *found* for the address it was stored for. Change the site in
the connection form and the token field is required: it will not carry the
previous site's token over, and the field is never prefilled with it, because a
secret in a page's HTML is a secret in a screenshot and in the browser's next
submission. The item's account is the address rather than a hash, so it can be
found and deleted by hand in Keychain Access. A token stored by an older build
(one entry for the whole machine) moves to its site on the next launch.

**When it does not start, it says so — in a sentence, not in a log.** The window
opens on the reason instead of the app disappearing. The shell matches what the
release said against the handful of situations a person can act on, and leads
with that one, distinct for each: *Confluence Export is already running* (close
the other window), *this folder belongs to a different site*, *the folder is in
use* (a backup, a synced drive), *the saved token could not be read* (unlock the
keychain), *this copy of the app is incomplete* (download it again), *it stopped
while starting*, *it is taking longer than it should*, *the window has nothing to
show*. Nothing else is guessed: an unrecognised failure is reported as the
general "it stopped" rather than as a cause somebody would act on wrongly.

The release's own output is not thrown away, it is **folded**: *What the app
said* is one click below, the same text is appended to
`~/Library/Logs/dev.confluence-export.desktop/sidecar.log`, and the page names
that file. A technical blob in a person's face is not an explanation; behind a
summary it is the answer for whoever is debugging.

A launch also has a bound. The waiting page changes its own sentence at five and
forty seconds, and at sixty the window becomes that failure page rather than
claiming to be starting for ever — a spinner nobody can end is how a person is
left guessing. Before the window is pointed at the release's address, the shell
asks that address to accept a connection; a server that died between announcing
itself and the first request becomes *the window has nothing to show* instead of
the webview's own error page.

**One workspace, one copy.** A second copy is refused in words (see *already
running* above) before it opens anything: two copies would be two servers, two
job workers and two writers on one `catalogue.db`, and SQLite's answer to that is
a lock fight rather than a feature. The port the tool prefers is the check — the
second copy asks the first one who it is (a response header this app sets) and
stops if the answer is *Confluence Export*, while a port taken by anything else
still falls back to an OS-assigned one.

**Its own log is a file, not a pipe.** The release also keeps
`<workspace>/logs/desktop.log` (rotated at 5 MB, three archives), and that is
where its `Logger` output goes from boot on. It is not a preference: the
window's console is a pipe, the shell stops reading it when the window closes,
and the next write to a pipe nobody reads raises `:badarg`
(`:erlang.display_string`, cause `:epipe`) **in whichever process logged** — a
sync once died that way, in a page's task, several frames below anything it had
done. A file has no reader to lose, and `Sync.Log.add/3` treats the console as
optional for the same reason.

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
    jobs.ex                 the mirror run as a job: enqueue, read the run, cancel it
    catalogue.ex            what the window reads from the catalogue (pages per space)
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
| `/__tool/spaces`, `/__tool/mirror` | the space list, and the press that starts or stops the mirror | a release starts a sync from its admin screens; a window has no admin screen of its own to open, so the press lives here. What it *starts* is the server's: a `SpaceWorker` on the `sync` queue, with a `sync_runs` row and a `Sync.cancel/2` |
| `/__tool/cancel` | stop what the tool started: the run in flight and the queue behind it | the deployment's cancel is a button on `/admin/jobs`, which a window can reach — this is the same call, with the queue emptied first so a bulk run stops being a bulk run |
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

### The port

The window's server prefers **43_100**, the same number every launch, and it is
overridable in two places, in this order:

| how | for |
| --- | --- |
| `CONFLUENCE_EXPORT_PORT=43101` | a script, a service, a second copy |
| `"port": 43101` in `settings.json` | a person who double-clicks the app and has no shell |

43_100 rather than 4_000 (a server someone started by hand) or 42_800 (the
neighbouring Monty tool). A fixed number is the point: the MCP endpoint is a URL
an assistant is pointed at **once**, and a port that changes per launch is a
client re-pointed at every launch. A value that is not a port is logged and
ignored — refusing to start over a typo would take the tool away from the one
person who could fix it.

A fixed port is also a port a second copy cannot have, so when it is taken — by
another copy or by anything else — the operating system picks one instead and the
announcement carries it:

```
port 43100 is taken; asking the operating system for another one — the address is
announced on stdout and shown behind the account menu
```

That sentence matters because **a window has no stdout**: the only place a
person can read the address the port landed on is the account menu → *Assistant
(MCP)*, which opens `/mcp` — a page that prints the URL the request arrived on,
`http://127.0.0.1:<port>/api/mcp`, with the `.vscode/mcp.json` block beside it.
The same page is in the deployment, where the address is the site's own name.

An assistant can read the same facts itself: `confluence_mirror_configuration`
(administrators only) answers with the site, the intervals, the last successful
run and the totals, and — because this build contributes it — the workspace
folder and the address above, taken from the port that was actually granted
rather than the one that was preferred.

### The folder

The tool's home (`/__tool`) shows where the catalogue lives and has one button
for it: **Show the folder in Finder** (`open`, `xdg-open` or `explorer`, whichever
the platform has). It only *reveals* the folder. Deleting the catalogue is how
somebody starts over, and that is a decision to make with the folder in front of
you — one click in here would be one click from an empty mirror with no undo.

Oban runs on `Oban.Engines.Lite`, because the store is a file; the queues are one
process each, because one SQLite connection cannot feed fourteen consumers.

`ConfluencePhxMirrorWeb.Skins.validate!/0` is called first, as the server does,
so a misspelt skin name stops the boot rather than quietly serving the default.
After the tree is up the tool does what the server does — load `Settings` and
`SiteSettings` once, configure the mailer, settle jobs left `executing` by the
last shutdown.

### The window owns the process

Closing the window quits the app, and the release goes with it. That is not a
preference: **there is no tray icon and no menu of ours**, so a process that
outlives its window is one nobody can reach — except by `kill`, or by noticing
the next launch could not have the port.

Two things hold that, and they cover different deaths:

- `RunEvent::WindowEvent { event: Destroyed }` for the window called `main` calls
  `app.exit(0)`, which is the ordinary path: the red button asks, and the app
  answers by stopping the release in `RunEvent::Exit`.
- The window starts the release with `CONFLUENCE_EXPORT_DIE_WITH_PARENT=1` and a
  stdin it owns. `Desktop.Application` then reads that pipe and stops on
  end-of-file. A force-quit, a crash or a `kill -9` never reaches the first path,
  but it does close the pipe, and that is the only signal a killed window can
  still send. It is why a stale release cannot be left holding 43_100.

The variable is opt-in on purpose. `scripts/package.sh` runs the release with an
inherited stdin, which under CI may already be at end-of-file; a release that
watched stdin unconditionally would exit immediately and fail the boot check.

### When the folder and the configuration disagree

The tool does not die of it. A mirror holds one site, so a folder that belongs to
one site and a configuration naming another is refused — every sync goes through
`Sites.verify!/0`, and that is where the refusal lives, because reading cannot
mix two sites and writing can. The boot check reports instead: the disagreement
is logged, kept in `Sites.conflict/0`, and shown at the top of the tool's home
page with both names and the way out (*change the connection*, or start over in a
folder of its own). Saving the connection asks again, so the warning goes away
without a restart.

It is the case a lost `settings.json` produces, and a window that answered it
with a crash dump helped nobody: the deployment keeps `on_conflict: :stop` (a
server has no one to ask), the window passes `on_conflict: :report`.

### Choosing what to mirror

The spaces screen offers three things per row, and they are three different
questions. **Mirror** copies one space and records that choice in the workspace's
configured set. **Forget** appears for a space this catalogue holds — pages or no
pages — and takes it out of that set *and* puts what is here in the trash
(`Trash.forget/2`), which is the only way to get rid of a space nobody wanted;
without it a catalogue could hold a space forever with nothing to press. **Mirror
N configured spaces** is the bulk button, and it copies what the workspace is
configured for, not the listing: a run over everything used to add every one of
those keys to the configuration, which is how a workspace set up for one space
ended up holding — and importing — a hundred others.

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

**Desktop unit tests** — `test_desktop/`, run by `scripts/test-desktop.sh`:
`MIX_ENV=desktop mix test --no-start`, its own test path (`test_paths/1` in
`mix.exs` keeps the server's helper out of it), and a throwaway `HOME` so the
suite never reads or writes the catalogue somebody has open. What is there today
is the part that is a *contract* rather than a feature: the marker header a
second copy uses to recognise the first, the port decision that makes the app
single-instance, and the screens' answer to a missing file. `--no-start` keeps
those tests about logic: the two applications the code calls into (`bandit` for a
real socket, `req` for the probe) are started by the test helper, and nothing else
is.

The same suite has two hosts: `scripts/test-desktop.sh` locally, and the `Desktop
tool` job in `ci.yml`, which also compiles the tool with warnings-as-errors and
dialyses it. The window shell is tested separately
(`cargo test --manifest-path src-tauri/Cargo.toml`): failure classification, the
failure page, and the address check.

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

`scripts/package.sh` is the whole build, on all three platforms, and it asks for
its prerequisites before it starts anything: `mix`, `cargo` and `npm` are named if
they are absent (the Xcode command line tools too, on macOS), while Hex, rebar and
the Tauri CLI install themselves (`cargo install tauri-cli` — a few minutes, once
per machine). The dependencies are fetched first, because the asset steps read
them.

What it writes depends on the platform, because what a person installs does:

| platform | artifact | where the release lives |
| --- | --- | --- |
| macOS | `Confluence Export.app`, zipped with `ditto` | `Contents/Resources/rel` — `resource_dir()` |
| Linux | `confluence-export-linux.tar.gz`: the window plus `rel/` and a `README.txt` | beside the binary |
| Windows | a folder: `confluence-export.exe` plus `rel\` | beside the binary — `resource_dir()` *is* the executable's directory there |

The release is copied in by hand rather than through Tauri's `bundle.resources`:
Tauri's own copy of that tree (2 700 files, addressed across a `..`) fails in its
resource phase on this toolchain, and one copy puts it exactly where
`src-tauri/src/main.rs` looks it up. On Linux and Windows the window is built with
`--no-bundle` for the same reason — there, the artifact *is* a folder.

Every build ends with the same two gates, on every platform: the release **the
artifact carries** is booted against a throwaway `HOME` and asked for `/health` and
`/__tool`, and the artifact's own listing is read to prove it contains both halves.
A window with no release behind it and a release that cannot serve are the two
failures that look green from a distance, and each has shipped once.

**Burrito was considered and rejected** (`docs/ex-tauri-migration.md`): it packages
a release into one file per platform, which would have replaced the copying above,
but it is being archived on 30 November 2026, its successor does not cover Windows,
and it cannot build on the OTP this app runs on. `mix release` plus Tauri's own
bundler needs no third party and gives all three platforms.

### What Windows does not have

Six things about this build only showed up on the Windows runner, each one found by
the leg that builds it and none of them visible on a Mac:

* a password hasher. `argon2_elixir` has no Windows branch in its Makefile at
  all — it links an executable instead of a library and the job died with
  `undefined reference to WinMain` — so the tool's build leaves it out and
  `TokenHash` reads the hasher from configuration. Without one it stores a word
  (`no-password-hasher-in-this-build`, deliberately not a weaker digest that
  would verify) and `verify/2` answers `false`, which is what a wrong token gets.
  The tool issues no tokens: one local reader, no sign-in, no API clients.
* an icon. `tauri-build` compiles the icon into the executable's resources on
  Windows, and without an `.ico` it stopped with "icons/icon.ico not found;
  required for generating a Windows Resource file" — the repository carried one
  PNG, enough for macOS. `cargo tauri icon` generated the platform set and both
  configs list it.
* `cmd` and POSIX paths. The boot check and the debug job handed the launcher's
  path to `cmd /C`, which does not resolve one: "`_build` is not recognized as an
  internal or external command". The launcher is started directly on all three
  platforms — bash runs a `.bat` through `cmd` itself.
* `cp -R`. The OTP tree holds entries it refuses to write over: it stopped at
  `erts-17.1.1/bin/erl` with "File exists". The copy is a tar stream, which only
  has to reproduce the tree.
* POSIX permission bits. `test -x` on `bin/<name>.bat` says no, because there are
  none to say yes about; on Windows the launcher only has to be *there*.
* `rm -f` on a directory. The artifact *is* the staging folder there, so
  "assembling" it by first removing it said "Is a directory" — Windows removes
  nothing, because `upload-artifact` zips the folder for it.

One more thing is not Windows's: an artifact uploaded from a directory is zipped
as that directory's **contents**, so the Windows download unpacked its three files
loose. The workflow moves the folder under `unpack/` and uploads that, so what a
person unzips is one folder holding `confluence-export.exe`, `rel\` and the note.

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
