# Hand-off: moving the desktop app onto ExTauri

Status: **rejected, 2026-11-04.** Recorded as a decision, not a plan. The window
stays the hand-written Tauri shell this repo already ships, and the Windows and
Linux bundles get built with `mix release` + Tauri's own bundler.

Read `docs/desktop-tool.md` first for what the app is, then `### Why this was
rejected` below. The rest of this document keeps the investigation — what
[ExTauri](https://github.com/filipecabaco/ex_tauri) (`ex_tauri` 0.7.x, MIT) is,
what the Burrito spike measured, and what the migration would have cost — so that
the decision can be re-examined on evidence rather than re-litigated, and so that
its good ideas (single instance, orphan sweep, a per-launch token) can be taken
without the dependency.

## Why this was rejected

Three facts, in the order they matter:

1. **Burrito is being archived.** `burrito`'s README opens with
   `⚠️ NOTICE: This repo will be _archived_ on November 30th 2026 ⚠️` — 26 days
   after this decision. It does not stop working (the Hex package remains
   installable), but nothing in it will be fixed, and ERTS payloads for new OTP
   releases stop appearing. ExTauri's production path depends on it:
   `bundle.externalBin` **is** the Burrito binary.
2. **Its successor does not cover Windows.** `ampoule`, by the same author and
   actively developed (0.1.13, commit `cf3c399` on 2026-11-02), packs a release
   that runs the BEAM as WebAssembly on OTP 28 — on macOS and Linux. ExTauri's
   own README: *"macOS and Linux (Windows stays on Burrito)"*. So the platform we
   most needed help with is the one no maintained packager covers.
3. **It cannot build on our toolchain anyway.** Measured: Burrito downloads ERTS
   for the exact OTP patch of the build machine from its own CDN, and
   `OTP-29.1.2` is a 404 (as is Homebrew's `28.5.0.8`). Details in "Spike result".

Our current path is `mix release` + Tauri's bundler, both maintained, and gives
all three platforms. Trading 385 lines of shell we control for a hard dependency
on a repository that closes within the month, in exchange for a Windows path it
does not have, is the wrong trade.

**What we take from the investigation instead** (no dependency needed):

- **Single instance.** Two copies of the tool are two servers, two Oban workers
  and two writers on one `catalogue.db`. Their shell's answer is a single-instance
  guard; ours can be the port the tool already prefers — a second copy that finds
  43100 answered by *our* `/health` refuses to start instead of quietly asking the
  OS for another port.
- **The per-launch token** (`ExTauri.Token`), if the loopback surface is ever to
  be closed to other local processes. Note the trade-off recorded below: `/api/mcp`
  is a paste-able URL.
- **The orphan sweep** — lower value here, because our release already stops when
  the window's pipe closes (see "The window owns the process" in
  `docs/desktop-tool.md`), which covers quit, crash and `kill -9`.

Revisit only if ampoule gains Windows **and** Burrito's absence stops mattering.

## Why

The window half of this project is ~800 lines we maintain by hand:

| file | lines | what it does |
| --- | --- | --- |
| `src-tauri/src/main.rs` | 385 | sidecar path lookup, spawn, stdout parsing, splash page, failure page, log file, window lifecycle |
| `scripts/package.sh` | 297 | assets, release, bundle, carrying the release in, boot check, zip |
| `scripts/lib/bundle.sh` | 27 | `ditto` the release into `Contents/Resources/rel` |
| `.github/workflows/desktop-release.yml` | 149 | one macOS job, one artifact |
| `.github/workflows/desktop-debug.yml` | 124 | one macOS job |
| `lib_desktop/desktop/application.ex` (parent watch) | ~25 | stop the release when the window's stdin closes |

ExTauri owns all of that, plus the three platforms we were about to hand-write
(a Windows `.bat` sidecar, `cmd /C`, `CREATE_NO_WINDOW`, a Job Object; a Debian
`.deb` and an AppImage; a macOS `.app`), plus a per-launch token and a heartbeat
shutdown that replaces our stdin-EOF trick. The saving is not "fewer features" —
it is roughly 400 lines deleted and ~350 lines of cross-platform Rust and shell
that never get written.

## What was verified about ExTauri (source, not marketing)

Cloned at `3f8123a` (2026-11-03, tag `v0.7.1`). Facts below are from that tree.

1. **It is the same architecture we already ship.** A Tauri window starts the
   Elixir release as a sidecar and points a webview at it over loopback HTTP.
   Nothing in `lib/` or `lib_desktop/` changes to "be an ExTauri app" — the whole
   reading surface keeps working because it is just HTTP.

2. **The bundled sidecar is a Burrito single binary.**
   `lib/ex_tauri/install/helpers.ex:171` writes
   `"bundle": {"externalBin": ["../burrito_out/<release_name>"]}`. So
   `mix ex_tauri.build` produces nothing to run unless the release is wrapped by
   Burrito first. The single binary replaces our `rel/` tree inside
   `Contents/Resources`, which is what lets us delete `bundle.sh`, the `ditto`
   step and the `.deb`/`.msi` carrying problem.

3. **`mix ex_tauri.install` overwrites an existing shell.** `setup_tauri_project/2`
   (`helpers.ex:13`) runs `cargo tauri init`, then **writes**
   `src-tauri/Cargo.toml` and `src-tauri/src/main.rs` (`generate_rust_files/1`),
   rewrites `tauri.conf.json` keys, rewrites capabilities, writes
   `assets/vendor/ex_tauri.js`, injects an import into `assets/js/app.js` and a
   `<div id="tauri-bridge">` into the root layout. It is not additive. Plan for a
   deliberate port, not a run-in-place installer.

4. **The generated shell is 1 206 lines of Rust template**
   (`priv/templates/main.rs.eex`) and already does: launch with `PORT`,
   `SECRET_KEY_BASE`, `EX_TAURI_TOKEN` and `:sidecar_env`; wait for the port;
   restart the backend up to three times with backoff; log to
   `app_log_dir()` via `tauri-plugin-log`; show a loading page and a failure page
   with the log path; heartbeat; graceful `stop_sidecar/1`.

5. **The heartbeat does not kill a shell-less release.** Absent
   `EX_TAURI_HEARTBEAT_SOCKET` / `EX_TAURI_HEARTBEAT_PORT_FILE` it listens on a
   per-app path, and "before the first connection the timeout is not enforced"
   (`lib/ex_tauri/shutdown_manager.ex`). Our boot check — start the release from a
   shell, curl `/health` — keeps working.

6. **The token is opt-in.** `ExTauri.Token.Plug` takes `EX_TAURI_TOKEN` from the
   shell, trades the query parameter for an `HttpOnly`/`SameSite=Strict` cookie,
   and 401s everything else. With no plug mounted, nothing changes.

7. **Burrito 1.6.0 pins Zig 0.16.0 exactly.** `lib/burrito.ex:5` is
   `@zig_version_expected %Version{major: 0, minor: 16, patch: 0}`; its README
   still says 0.15.2. CI must install exactly 0.16.0. **This machine has
   0.17.0** (`/opt/homebrew/bin/zig`, Homebrew's current `zig`), so
   `mix release` with a Burrito step fails with "Your Zig version does not match
   the one Burrito requires!". Zig 0.16.0 was fetched from
   <https://ziglang.org/download/> into `/tmp/zig016` for the spike; CI should use
   `mlugg/setup-zig@v2.2.1` pinned to `0.16.0`.

8. **OTP 29 is a warning in ExTauri and a wall in Burrito** — see the spike result
   below. ExTauri's `lib/ex_tauri.ex:88` only warns when the running OTP is not
   27; Burrito is what actually fails, and it fails on the exact OTP *patch*
   version, not the major. `custom_erts` is the only escape, and it wants an
   unpacked OTP release tree (`erts-X.Y.Z/`, `releases/`, `Install`) — a Homebrew
   install is not one.

## Spike result (2026-11-04): Burrito cannot wrap this app on OTP 29

Run on macOS arm64, in a scratch clone of this repo (`/tmp/extauri-spike`), with
Zig 0.16.0 from ziglang.org, and `confluence_export_desktop` as a release with
`steps: [:assemble, &Burrito.wrap/1]`:

```
--> Resolving ERTS: {:precompiled, [version: "29.1.2"]}
--> Downloading https://beam-machine-universal.b-cdn.net/OTP-29.1.2/macos/universal/…
** (RuntimeError) Failed to fetch …! (Got 404) Perhaps we haven't built a
   pre-compiled Erlang for this release yet?
```

What that means, measured:

- Burrito resolves ERTS from its own CDN for the **exact** OTP patch version of
  the build machine. It does not use the local `erts-*` directory.
- `OTP-29.1.2` → **404**. `OTP-28.5.0.8` (what Homebrew's `erlang@28` installs) →
  **404**. `OTP-28.5.0.4`, `28.3.3`, `28.1`, `27.3.4`, `27.2.4`, `27.1.2` → 200.
- So the desktop release must be built on an OTP patch Burrito has published, and
  the list is exact: `28.5.0.4` is the newest usable one as of this writing.
- Nothing in `lib/`, `lib_desktop/` or `mix.exs` is implicated: the release
  assembles and the step fails before the wrapper is compiled.

Consequence for the plan: **the desktop legs build on OTP 28.5.0.4, the server
legs stay on 29.** `mix ex_tauri.dev` and `scripts/start-desktop.sh` skip Burrito,
so day-to-day work is unaffected; only a distributable needs the pinned OTP. That
is a CI setting (`otp-version: 28.5.0.4`) and, for whoever builds a bundle
locally, an exact OTP install (asdf/kerl — Homebrew's `erlang@28` is the wrong
patch).

Still unproven, and the first thing to try next: with `28.5.0.4` installed, does
`Burrito.wrap/1` compile the Zig wrapper and does the resulting binary boot this
app? That is step S1 below.

## Decisions to take before writing code

- **D1 — release name.** Our release is `confluence_phx_mirror`, and the *server*
  deploy (Dockerfile, `scripts/fly-deploy.sh`) uses it. Wrapping that release in
  Burrito would wrap the production server too. Add a second release,
  `confluence_phx_mirror_desktop`, with `[:assemble, &Burrito.wrap/1]`, and set
  `config :ex_tauri, release_name: "confluence_phx_mirror_desktop"`. The two have
  to agree or Burrito's unpack directory and the externalBin path disagree.
- **D2 — the token's scope.** With `plug ExTauri.Token.Plug`, `/__tool` and
  `/admin` become unreachable except from the window — good — but `/api/mcp` is a
  URL a person pastes into an assistant, and a per-launch secret nobody can read
  breaks it. Either guard only the tool's screens (`only: ["/__tool", "/admin"]`,
  status quo for MCP), or leave the plug out (status quo everywhere). Decide
  explicitly; do not mount it "everywhere" and discover MCP is dead.
- **D3 — bundle types per OS.** macOS `app` (+ `dmg`?), Linux `deb` + `appimage`,
  Windows `nsis`. `mix ex_tauri.build --bundles` takes them.
- **D4 — do we keep `ElixirKit.Release.codesign/1`?** It signs 2 700 files of the
  release tree so a macOS bundle passes Gatekeeper's ad-hoc requirement. A Burrito
  binary is one file, linker-signed like any other binary. Recommended: drop it
  for the desktop release (keep it on `confluence_phx_mirror` if the server needs
  it — it does not), which deletes `CONFLUENCE_SIGN_RELEASE` from
  `scripts/package.sh`. Verify by launching the built `.app` on a Mac.
- **D5 — what happens to `scripts/package.sh`.** It stays, thinner: it keeps the
  asset steps, the boot check and the artifact check, and loses the bundle
  assembly to `mix ex_tauri.build`. The old flow is deleted, not kept behind a
  flag — a second path is how the two drift (`docs/desktop-tool.md`, "Packaging").
- **D6 — which OTP the desktop builds on.** Measured: `28.5.0.4` is the newest
  patch Burrito will package; `29.1.2` and `28.5.0.8` are 404. Pin the desktop
  legs to `28.5.0.4` and leave the server legs on whatever they run today, or
  postpone the migration until Burrito publishes OTP 29 payloads. Both are
  defensible; the first is a CI pin, the second is a wait with no date.

## Steps

Every step ends with its own gate. Do not start `n+1` with a red gate.

**S0 — the branch is clean.** `git status` on `desktop` shows only what you meant
to change. The unfinished Windows/Linux work that was planned before this
migration (`.bat` sidecar, `cmd /C`, Job Object, per-OS Tauri configs,
`include_executables_for`) is **not** written, and must not be: ExTauri's shell
and Burrito replace it.

**S1 — finish the Burrito spike.** Half done; see "Spike result" above. What is
left, and it is the gate for everything else:

```sh
# an OTP patch Burrito has a payload for — not Homebrew's erlang@28 (28.5.0.8)
asdf install erlang 28.5.0.4        # or kerl; ~10–15 min
asdf local erlang 28.5.0.4          # in the spike clone only
zig version                          # exactly 0.16.0
MIX_ENV=desktop mix release confluence_export_desktop --overwrite
burrito_out/confluence_export_desktop_aarch64-apple-darwin
```

Gate: the binary exists, and with `HOME` pointing at a throwaway directory and
`PORT=43100` it starts, prints `desktop ui:`, answers `/health`, and stops. If the
Zig wrapper will not compile or the wrapped binary will not boot this app, the
migration stops here and the branch keeps the hand-written shell.

Cheaper alternative if a local OTP install is unwanted: put the same three
commands in a throwaway workflow on `ubuntu-24.04` with `otp-version: 28.5.0.4`,
and read the log — it is the environment that has to work anyway.

**S2 — dependencies and config, desktop environment only.**

- `mix.exs`: `{:ex_tauri, "~> 0.7", only: :desktop}` and
  `{:burrito, "~> 1.6", only: :desktop, runtime: false}`; the
  `confluence_phx_mirror_desktop` release from D1.
- `config/desktop.exs` (never `config.exs` — the server must not see ExTauri):
  `app_name`, `window_title`, `host: "127.0.0.1"`, `port: 43_100`,
  `version: "2.5.1"`, `release_name`, and `sidecar_env: []` — the default injects
  `PHX_SERVER`/`PHX_HOST`, and our endpoint runs `server: false` behind
  `Desktop.Web.Server`, so those two names would only mislead the next reader.
  Keep the default if the endpoint ever gains a listener of its own.

Gate: `MIX_ENV=desktop mix compile --warnings-as-errors` and
`MIX_ENV=prod mix compile` (the server must not have gained a dependency).

**S3 — the listener obeys the port the shell chose.**
`ConfluencePhxMirror.Desktop.Web.Server.choose_port/0` prefers, in order:
`CONFLUENCE_EXPORT_PORT`, `settings.json`, 43_100. Add `PORT` **first** and, when
it came from `PORT`, do not fall back to an OS-assigned port: the shell navigates
to the port it picked, so moving is a window on nothing. Keep printing
`desktop ui: http://127.0.0.1:<port>/` — the shell logs it, and our boot check
reads it.

Tests (behaviour, not implementation):

- given `PORT` is set, when the listener starts then it is bound to exactly that
  port (and `Application.get_env(:confluence_phx_mirror, :desktop_port)` says so);
- given `PORT` is set and taken, when the listener starts then it fails rather
  than moving;
- given `PORT` is absent, the existing preference order still holds.

**S4 — shutdown moves from a pipe to a heartbeat.**
`lib_desktop/desktop/application.ex`: add `ExTauri.ShutdownManager` to the tree,
delete `watch_parent/0` and `await_end_of_input/0`, and delete
`CONFLUENCE_EXPORT_DIE_WITH_PARENT` from the shell (the shell is replaced in S6).
Check the tree order: the manager must be a sibling of the listener, not above it.

Gate: the desktop suite is green, and — by hand — close the window on macOS and
watch the release exit (`pgrep -f confluence_phx_mirror_desktop` is empty a second
later), then `kill -9` the window and check the same.

**S5 — port the generated shell, do not run the installer.**
In a scratch copy of *this* repo (or `/tmp/ex_tauri_spike/example`), run
`mix ex_tauri.install` and diff what it writes against `src-tauri/`. Copy across,
by hand and with a comment on each: `Cargo.toml` (their plugins: `shell`, `log`,
plus whatever `capabilities` they generate), `src/main.rs` (the template),
`tauri.conf.json` (they set a CSP; ours is `csp: null` — LiveView needs
`connect-src ws: wss:` and the assets are same-origin, so take theirs and check
the app renders before changing it), `capabilities/`, `assets/vendor/ex_tauri.js`.

Keep, and re-point: `src-tauri/App.entitlements` (only if D4 says the macOS
bundle still signs), `src-tauri/icons/`, `productName: "Confluence Export"`,
`identifier: "dev.confluence-export.desktop"`.

Delete: `tauri.bundle.conf.json`, `scripts/lib/bundle.sh`.

**Expect the bridge to be inert on `/__tool`.** ExTauri injects its JS hook into
`assets/js/app.js` and its div into the server's root layout — both of which the
tool's own screens do not use, because `Desktop.Web.Page` writes plain HTML
strings. The bridge therefore works on the server's LiveView screens and nowhere
else. That is fine today (we call no desktop API); it is not fine to discover
later. Write it down where the next person looks.

**S6 — the failure page.** Ours shows the release's own last lines inline; theirs
shows what happened and the path of the log. Regression accepted, but check the
log actually contains the release's words on a real failure (start the app with a
catalogue that belongs to another site — `Sites.verify!/0` refuses, and that
refusal is the sentence a person needs).

**S7 — `scripts/package.sh` gets thin.** Keep, in this order: prerequisite check,
`mix deps.get`, `mix assets.install`, `npm ci` when `assets/node_modules` is
missing, tailwind, esbuild ×2, `phx.digest`, the keyring NIF check, then
`mix ex_tauri.build --bundles <D3>`. Keep both checks that earned their place:

- **boot check** — start `burrito_out/<release>_<triple>` with a throwaway `HOME`
  and `PORT`, wait for `desktop ui:`, curl `/health` and `/__tool`, kill it;
- **artifact check** — read the artifact's listing (rather than piping into
  `grep -q`, which SIGPIPEs `unzip` under `pipefail`) and assert the sidecar is
  inside: `unzip -l` the `.app` zip, `dpkg -c` the `.deb`.

Delete `embed_release/0`, `assemble/0` and the `ditto` zip.

**S8 — workflows.** `desktop-release.yml`: a matrix over
`macos-latest` / `ubuntu-22.04` / `windows-latest`, each installing Elixir, Rust,
Zig 0.16.0 (`mlugg/setup-zig@v2.2.1` with `version: 0.16.0`) and `cargo-tauri`, each running`scripts/package.sh` and uploading one artifact per OS
(`confluence-export-macos`, `confluence-export-linux`, `confluence-export-windows`);
the tag job attaches all three with the tag in the name. `desktop-debug.yml`:
build the window and boot the release on all three (no bundling), so a Windows
compile error is found in minutes, not at release time.

Follow the reference project's shape (`console-chess`: `matrix.include` with a
per-OS artifact name; `ex.tbp.monty`: one artifact per platform in the README
table).

**S9 — docs and links.** `docs/desktop-tool.md` §"Getting it" and the README gain
a three-row table of download links (`nightly.link/.../desktop-release/<branch>/<artifact>.zip`)
and per-platform install lines. `install-desktop.sh` is macOS-only by
construction (it writes to `~/Applications`); either make it refuse politely on
other platforms or add a sibling. Deleting the claim is better than a script that
half-works.

## Gates, in one place

| # | gate | where |
| --- | --- | --- |
| 1 | Burrito's CDN has a payload for our OTP patch | **measured: 29.1.2 and 28.5.0.8 are 404; 28.5.0.4 works** |
| 2 | the Zig wrapper compiles and the wrapped binary boots this app on 28.5.0.4 | S1 |
| 3 | `MIX_ENV=desktop mix compile --warnings-as-errors`; `MIX_ENV=prod mix compile` unchanged | S2 |
| 4 | listener binds `PORT`; new tests green | S3 |
| 5 | window close and `kill -9` both stop the release | S4, by hand |
| 6 | the window renders LiveView under their CSP | S5, by hand |
| 7 | failure page names the log; the log holds the release's words | S6, by hand |
| 8 | `scripts/package.sh` on macOS: boot check + artifact check | S7 |
| 9 | the same script green on Linux and Windows in CI | S8 |
| 10 | `mix test` (Postgres), `scripts/test-sqlite.sh`, `mix lint`, `mix complexity` | before every commit |

## Risks and how each is closed

| risk | closed by |
| --- | --- |
| Burrito has no ERTS payload for the OTP we build with | **measured** — desktop legs pin `28.5.0.4`; `29.1.2` and `28.5.0.8` are 404 |
| the Zig wrapper will not compile, or the wrapped binary will not boot this app | S1 — the remaining half of the spike, before anything else changes |
| a second OTP in CI drifts from the one the app is developed on | S8 — only the desktop legs pin, and the debug matrix runs the same pin |
| `mix ex_tauri.install` fights our `src-tauri/` | S5 — port by hand, never run it in place |
| the window navigates to a port we did not bind | S3 — `PORT` wins and does not fall back |
| a `kill -9`'d window leaves a release holding the port | S4 — heartbeat, tested by hand on both paths |
| a release started from a shell exits immediately | verified: no heartbeat timeout before the first connection; the boot check in S7 proves it every run |
| MCP clients lose access because of the token | D2 — decided before S5, and `/api/mcp` exercised by hand afterwards |
| the CSP breaks LiveView or the colocated hooks | S5 — load `/`, `/admin`, `/__tool` in the window before changing anything else |
| Windows-specific behaviour is unverifiable locally | S8 — the debug matrix runs on `windows-latest` on every push |
| the two packaging paths drift | D5 — the old path is deleted, not flagged |

## Rollback

An `ex_tauri` migration is one dependency, one release and one shell. The branch
holds both versions until S6 is green: `src-tauri/` before S5 and `package.sh`
before S7 are one `git checkout` away, and nothing in `lib/` or `lib_desktop/`
except the listener's port order (S3) and the supervision tree (S4) is touched.
Do not delete the old shell in the same commit that adds the new one — delete it
when the new one has booted.

## What not to do

- Do not run `mix ex_tauri.install` in this checkout. It rewrites `src-tauri/`,
  `assets/js/app.js` and the root layout.
- Do not put `config :ex_tauri` in `config/config.exs`: the server would compile
  with a desktop dependency it does not have.
- Do not add `&Burrito.wrap/1` to the `confluence_phx_mirror` release. That is the
  release Fly runs.
- Do not copy the release into the bundle by hand again (`bundle.resources`,
  `ditto`, a `.bat` launcher, a Job Object). Those exist because there was no
  single binary; now there is.
- Do not trust "the build succeeded" as evidence the artifact works: read the
  artifact's listing and boot the binary the bundle carries.
