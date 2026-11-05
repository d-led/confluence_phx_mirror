#!/usr/bin/env bash
#
# Builds what the desktop workflow publishes, here, so that pushing a tag is not
# the first time anyone finds out what it produces.
#
#   scripts/package.sh             build the app, prove the release inside it
#                                  serves, write the artifact the workflow
#                                  uploads
#   scripts/package.sh --install   …and install that build the way a download
#                                  installs (~/Applications, macOS only)
#
# What the artifact is depends on the platform, because what a person installs
# depends on the platform:
#
#   macOS    `Confluence Export.app`, zipped. It holds the window, the sidecar
#            release with its own Erlang runtime and the icon, so a person
#            unzips it, drags it to `/Applications` and double-clicks. A tarball
#            of loose binaries is not a macOS application.
#   Linux    `confluence-export-linux.tar.gz`: the window binary, the release in
#            `rel/`, and a note saying which GTK/WebKit libraries the window
#            needs. A `.deb` would be nicer and needs a bundle step that copies
#            the release through Tauri's resource phase — the one thing that
#            fails on this toolchain (`scripts/lib/bundle.sh`, first paragraph).
#   Windows  `confluence-export-windows/`: the window `.exe` with `rel\` beside
#            it. `resource_dir()` on Windows is the executable's own directory,
#            so a portable folder is a complete install; the workflow's
#            `upload-artifact` zips it.
#
# The macOS release is signed on the way in (`ElixirKit.Release.codesign/1`),
# because an application whose innards are unsigned is not launchable when
# signed, nor notarisation-ready. Without `APPLE_SIGNING_IDENTITY` that signature
# is ad-hoc: enough to make the mechanics real, not enough to satisfy Gatekeeper
# — that needs a Developer ID and notarisation, which are their own piece of work.
#
# `.github/workflows/desktop-release.yml` builds the same artifacts with the same
# steps; this script is the local half of that promise, not a second opinion
# about it.
#
# The store the tool uses is the real one, so this touches it: `mix release`
# compiles, and the boot check runs that release against a throwaway `HOME` so a
# tool you have open right now is neither locked nor disturbed.
#
# A machine that has never built this asks for four things and is given two of
# them: `mix`, `cargo`, `npm` and the Xcode command line tools are named if they
# are missing, while Hex, rebar and the Tauri CLI (`cargo tauri`) install
# themselves. The point is that the first message a fresh checkout prints is what
# to install, not a build that fails at its last step.

set -euo pipefail

cd "$(dirname "$0")/.."

name=confluence_phx_mirror
release="_build/desktop/rel/$name"
out="_build/desktop/package"

# What the platform calls its own packaging. `uname -s` on Windows is the only
# portable way to ask from a shell: Git Bash on a Windows runner answers
# `MINGW64_NT-10.0-…`.
case "$(uname -s)" in
  Darwin) platform=macos ;;
  Linux) platform=linux ;;
  MINGW* | MSYS* | CYGWIN*) platform=windows ;;
  *)
    echo "unknown platform: $(uname -s)"
    exit 69
    ;;
esac

# The release's own launcher: `bin/<name>` where there are shebangs, and
# `bin/<name>.bat` on Windows, where `mix.exs` asks for both flavours
# (`include_executables_for`). `src-tauri/src/main.rs` looks for the same file.
if [[ $platform == windows ]]; then
  launcher="bin/$name.bat"
  window="src-tauri/target/release/confluence-export.exe"
else
  launcher="bin/$name"
  window="src-tauri/target/release/confluence-export"
fi

# Where the release has to sit for the *installed* window to find it. macOS is
# the only platform that needs it copied by hand: `resource_dir()` is
# `Contents/Resources` there, the executable's own directory on Windows, and
# `../lib/<name>` on Linux — so a portable folder beside the binary is where the
# other two look.
if [[ $platform == macos ]]; then
  app="src-tauri/target/release/bundle/macos/Confluence Export.app"
  # A separate config, merged only here: `bundle.active` in the main one makes the
  # debug window `scripts/start-desktop.sh` opens fail in tauri-build's resource
  # phase, and the debug window has no use for a bundle.
  bundle_config="$PWD/src-tauri/tauri.bundle.conf.json"
  asset="confluence-export-macos.zip"
  stage="$app/Contents/Resources/rel/$name"
elif [[ $platform == windows ]]; then
  # A setup.exe, which is what a person on Windows expects to double-click. Its
  # config carries the release as `bundle.resources` — the copy step that fails on
  # macOS toolchain and needs no workaround here — so the installed window finds
  # `rel\` beside its own executable, which is what `resource_dir()` means there.
  installer_config="$PWD/src-tauri/tauri.bundle.windows.json"
  installer="$out/confluence-export-windows-setup.exe"
  stage="$out/confluence-export-$platform/rel/$name"
  asset="confluence-export-windows"
else
  stage="$out/confluence-export-$platform/rel/$name"
  asset="confluence-export-linux.tar.gz"
fi

install_after=no

usage() {
  echo "scripts/package.sh [--install]"
  echo
  echo "  (no flags)   build, check, and write $out/$asset"
  echo "  --install    …then install that build into ~/Applications (macOS only)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) install_after=yes; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown option: $1"
      usage
      exit 64
      ;;
  esac
done

# One line before and one after each step: a release build is a minute of
# silence otherwise, and when something fails the step that failed is the useful
# thing to know. No redirection — the tools' own output is what explains a
# failure.
steps=0
run() {
  local started=$SECONDS
  steps=$((steps + 1))
  echo
  echo "[$steps] $1"
  shift
  "$@"
  echo "[$steps] ok in $((SECONDS - started))s"
}

# What a build cannot happen without, asked once here rather than discovered
# fifteen steps in as "no such file". The two that can install themselves do it
# below; the rest are a one-line answer about where to get them.
require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "missing: $1 — $2"
  exit 69
}

require mix "Elixir and Mix — https://elixir-lang.org/install.html"
require cargo "the Rust toolchain — https://rustup.rs"
require npm "Node.js — https://nodejs.org (the stylesheet imports npm packages)"

# rustler compiles the keyring NIF with the system toolchain, and a Mac without
# the command line tools fails deep inside `mix release` with a linker error.
if [[ "$(uname -s)" == Darwin ]] && ! xcode-select -p >/dev/null 2>&1; then
  echo "missing: the Xcode command line tools — xcode-select --install"
  exit 69
fi

# `cygpath` turns the launcher's POSIX path into the Windows one the boot check
# hands `cmd`. It is MSYS's, not ours: this script only runs on Windows inside a
# bash — Git for Windows, which is what the runner's `shell: bash` is — and that
# bash ships `cygpath` beside itself. Nothing the *tool* ships needs it: the
# window builds its own paths in Rust. Asked here so a bash without it says which
# tool is missing instead of failing mid-check with "command not found".
if [[ $platform == windows ]]; then
  require cygpath "Git for Windows (MSYS) — https://git-scm.com/download/win"
fi

# Hex and rebar are the package managers the fetch uses, and on a machine that
# has never built an Elixir project `mix deps.get` stops to ask whether to install
# them — a prompt inside a script is a hang. Both are no-ops once present.
run "the Hex package manager (a fresh machine has none)" mix local.hex --force
run "rebar (same, for the projects that build with it)" mix local.rebar --force

# First, because everything after it reads the dependencies: this used to sit
# after the asset steps, which cannot run without them.
run "fetching the dependencies (a fresh clone has none)" \
  env MIX_ENV=desktop mix deps.get

# `cargo tauri` is the Tauri CLI, its own cargo subcommand. Installing it takes
# a few minutes once per machine; failing at the last step with "no such
# command" costs the build that came before it.
if ! cargo tauri --version >/dev/null 2>&1; then
  run "installing the Tauri CLI (a fresh machine has none)" \
    cargo install tauri-cli --version "^2" --locked
fi

# A release that builds but does not boot is not a release, and the workflow
# refuses to publish one. This is that same check, run before anything is
# written: it starts the very release the bundle carries as its resource.
#
# It is the one place in this repository that backgrounds a process, and it has
# to be: the release only says where it listens once it is running, and the point
# is to ask it for a page. `HOME` is a scratch directory because the tool's store
# lives under the user's data directory — a check that took the write lock on the
# catalogue somebody has open would be a check nobody dares run. That holds on
# macOS and Linux; Windows keeps its workspace in a fixed known folder that no
# environment variable moves, so there this check wants no copy of the tool open
# (the single-instance guard would answer before a port did).
boot_check() {
  local home log url pid carried
  home=$(mktemp -d)
  log=$(mktemp)

  # The copy where the *installed* window looks for it, not the one in
  # `_build`: that copy is what ships, so that copy is what gets asked — and on
  # Windows it is the `.bat`, which is the launcher the release ships there.
  carried="$PWD/$stage/$launcher"

  # Windows boots it the way the window does: `cmd`, `call`, a Windows path.
  # Starting the `.bat` from bash instead is a different shape of invocation —
  # bash hands `cmd` a POSIX path, `%~dp0` comes back with backslashes, and the
  # release's launcher is happy. The window gives the same file a path built by
  # Rust, and that is the one that has to work: a separator the batch file inherits
  # turns the release's boot file into one `erl` cannot find ("cannot get boot
  # file"), which is a download that opens on nothing.
  #
  # `cygpath -w` is only the translation from this shell's path to the one `cmd`
  # wants — MSYS's own tool, required above, never something the tool ships.
  if [[ $platform == windows ]]; then
    HOME="$home" RELEASE_DISTRIBUTION=none \
      cmd //c call "$(cygpath -w "$carried")" start >"$log" 2>&1 &
    pid=$!
  else
    HOME="$home" RELEASE_DISTRIBUTION=none "$carried" start >"$log" 2>&1 &
    pid=$!
  fi

  for _ in $(seq 1 60); do
    url=$(sed -n 's/^desktop ui: //p' "$log" | head -1)
    [ -n "$url" ] && break
    sleep 1
  done

  if [ -z "$url" ]; then
    echo "the release never said where it listens:"
    cat "$log"
    kill "$pid" 2>/dev/null || true
    rm -rf "$home" "$log"
    return 1
  fi

  # The address it prints ends with a slash, and `//__tool` is a different path
  # from `/__tool` — one the endpoint answers with a 404.
  url=${url%/}

  # Both halves: the mirror's own health, and the tool's screen, which is the
  # part this build adds. A bundle that serves one and not the other is a
  # download that opens on nothing.
  curl -fsS "$url/health" >/dev/null
  curl -fsS "$url/__tool" >/dev/null
  echo "served $url/health and $url/__tool"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$home" "$log"
}

# The release goes where the installed window looks for it: inside the bundle's
# `Contents/Resources` under `rel/` on macOS (see `scripts/lib/bundle.sh`), and
# beside the window binary on the platforms that ship as a folder.
stage_release() {
  rm -rf "$stage"
  mkdir -p "$(dirname "$stage")"

  if [[ $platform == macos ]]; then
    # shellcheck source=scripts/lib/bundle.sh
    . scripts/lib/bundle.sh
    bundle_embed_release "$app" "$release" "$name"
  else
    # A tar stream, not `cp -R`: the OTP tree holds files `cp` refuses to write
    # over — on Windows it stopped at `erts-17.1.1/bin/erl` with "File exists" —
    # and the copy only has to reproduce the tree, which is what tar does.
    tar -C "$(dirname "$release")" -cf - "$name" | tar -x -C "$(dirname "$stage")"
  fi

  # Without a launcher there, the window starts nothing — and a window that
  # opens on nothing is worse than a build that fails here.
  if ! release_carries_launcher; then
    echo "the release carried no launcher at ${stage#$PWD/}/$launcher — it holds:"
    ls "$stage" 2>/dev/null || echo "(nothing; the copy did not land)"
    return 1
  fi

  echo "carried $(du -sh "$stage" | cut -f1) into ${stage#$PWD/}"
}

# The file the window starts the release through: a script on macOS and Linux,
# which has to be executable, and the `.bat` on Windows, which only has to be
# there — the POSIX permission bits of a Windows filesystem are not a fact, and
# `test -x` on the `.bat` answered no to a launcher that runs.
release_carries_launcher() {
  local required="$stage/$launcher"
  if [[ $platform == windows ]]; then
    test -f "$required"
  else
    test -x "$required"
  fi
}

# A portable folder is a complete install on Linux and Windows: the window
# binary, the release beside it in `rel/`, and a note saying what the window
# needs. The macOS bundle has no use for this — `Contents/MacOS` is already
# where a bundle's executable goes.
stage_window() {
  local destination="$out/confluence-export-$platform"

  mkdir -p "$destination"
  cp "$window" "$destination/"

  # The note names the file to run, because "the window binary in this folder" is
  # only obvious to somebody who already knows which one that is.
  {
    cat <<'NOTE'
Confluence Export — a desktop tool that reads a Confluence site into a folder.

It starts its own server and opens it; the mirror it serves is the same one the
web deployment serves, and the tool's own screens live under /__tool.

Where things are kept (the catalogue, the mirrored attachments, the logs):
  macOS    ~/Library/Application Support/confluence-export
  Linux    ~/.local/share/confluence-export
  Windows  %LOCALAPPDATA%\confluence-export

On Linux the window needs GTK 3 and WebKitGTK 4.1 (Debian/Ubuntu:
  libgtk-3-0 libwebkit2gtk-4.1-0 librsvg2-2 libayatana-appindicator3-1).
The release in `rel/` needs nothing installed: it carries its own Erlang.

Nothing here is signed. macOS and Windows will both warn the first time; a macOS
copy that was downloaded needs `xattr -rd com.apple.quarantine` first.
NOTE
    echo
    if [[ $platform == linux ]]; then
      echo "Start it in a terminal: ./${window##*/}"
    else
      echo "Start it: double-click ${window##*/}"
    fi
  } >"$destination/README.txt"

  echo "staged $(du -sh "$destination" | cut -f1) in ${destination#$PWD/}"
}

assemble() {
  mkdir -p "$out"

  case "$platform" in
    macos)
      rm -f "$out/$asset"
      assemble_bundle
      ;;
    linux)
      rm -f "$out/$asset"
      assemble_tarball
      ;;
    # Windows ships two shapes of the same build: the folder, which is a complete
    # portable install, and the NSIS setup a person double-clicks. The installer is
    # built by `tauri-bundler`; when it is not there, the folder is still a working
    # download, so this reports the miss instead of failing a build that produced
    # something usable.
    windows)
      copy_installer
      echo "the artifact is $out/confluence-export-windows/"
      ;;
  esac
}

# The setup.exe `tauri-bundler` left, named after the platform rather than after
# the product version — the file a person downloads should not have to be
# decoded.
copy_installer() {
  local built

  built=$(find src-tauri/target/release/bundle/nsis -name '*-setup.exe' -print -quit 2>/dev/null || true)

  if [[ -z $built ]]; then
    echo "no setup.exe was bundled: the portable folder is the Windows download"
    return 0
  fi

  cp "$built" "$installer"
  ls -lh "$installer"
}

assemble_bundle() {
  # `ditto`, not `zip`: an application bundle is directories, symlinks and
  # extended attributes, and only `ditto -k` (or Finder's own zip) preserves the
  # ones a bundle needs to launch.
  ditto -c -k --keepParent "$app" "$out/$asset"

  # Prove the promise: one file, and the bundle is inside it with **both** halves
  # — the window and the release it starts. Checking only the window is how a
  # 2 MB zip with no `Contents/Resources/rel` passed a workflow gate and shipped
  # an app that could not start anything. The listing is compared, not piped into
  # `grep -q`: that exits at the first match, `unzip` takes the SIGPIPE, and
  # `pipefail` reads 141 as a failure.
  local listing
  listing=$(unzip -l "$out/$asset")
  case "$listing" in
    *"Confluence Export.app/Contents/MacOS/confluence-export"*) ;;
    *)
      echo "the zip does not carry the application bundle:"
      echo "$listing" | head -20
      return 1
      ;;
  esac

  case "$listing" in
    *"Confluence Export.app/Contents/Resources/rel/$name/bin/$name"*) ;;
    *)
      echo "the zip carries a window with no release behind it:"
      echo "$listing" | grep "Contents/Resources" | head -20
      return 1
      ;;
  esac

  ls -lh "$out/$asset"
}

assemble_tarball() {
  # Paths relative to `$out`, so the archive unpacks to one folder rather than
  # into whatever directory the person happens to be in.
  tar -czf "$out/$asset" -C "$out" "confluence-export-linux"

  # The same lesson as the bundle listing: an archive that carries a window and
  # no release is a download that opens on nothing.
  local listing
  listing=$(tar -tzf "$out/$asset")
  case "$listing" in
    *"confluence-export-linux/confluence-export"*) ;;
    *)
      echo "the tarball does not carry the window:"
      echo "$listing" | head -20
      return 1
      ;;
  esac

  case "$listing" in
    *"confluence-export-linux/rel/$name/$launcher"*) ;;
    *)
      echo "the tarball carries a window with no release behind it:"
      echo "$listing" | grep "rel/" | head -20
      return 1
      ;;
  esac

  ls -lh "$out/$asset"
}

# A release ships whatever `priv/static` holds and never builds it, so these are
# the steps that decide what the window looks like. They are the four that
# `scripts/start-desktop.sh` runs, for the same reason: a skipped one is a
# console full of "unknown hook found" and a menu that does not open.
run "checking the asset toolchain (installs it once, then finds it)" \
  env MIX_ENV=desktop mix assets.install --if-missing

# The JavaScript the bundle imports is npm's — `js/code_highlight.js` pulls
# highlight.js' grammars — and `mix esbuild` only bundles it. `mix
# assets.install` above fetches the esbuild and tailwind *binaries*, not
# `assets/node_modules`, so a clone that has never run `npm ci` fails at the
# first bundle with "Could not resolve highlight.js/lib/languages/diff". The
# release workflow did exactly that on every run.
if [[ ! -d assets/node_modules ]]; then
  run "installing the assets' npm packages (a fresh clone has none)" \
    env npm --prefix assets ci --no-audit --no-fund
fi

run "building the stylesheet" \
  env MIX_ENV=desktop mix tailwind confluence_phx_mirror --minify

run "building the scripts" \
  env MIX_ENV=desktop mix esbuild confluence_phx_mirror --minify

run "building the scripts the API docs page loads" \
  env MIX_ENV=desktop mix esbuild confluence_phx_mirror_swagger --minify

run "digesting the assets (the manifest the screens link through)" \
  env MIX_ENV=desktop mix phx.digest

# A restored build cache can carry Rustler's stamps without the thing it built:
# `priv/native/*.so` is what `mix release` copies, `mix compile` has nothing to
# do when the stamps say the crate is current, and the release then dies at boot
# with `on_load_function_failed` on the keyring module. Ask the file, not the
# stamps — the same lesson as the artifact that carried no release.
if [[ ! -f "_build/desktop/lib/$name/priv/native/confluence_keyring.so" ]]; then
  run "the keyring NIF is missing from the build; compiling it again" \
    env MIX_ENV=desktop mix compile --force
fi

# What the tool was built from, burned into the release the way the image does
# it: the version, the commit, and the moment — the tool serves the same admin
# footer, and a copy somebody reports a bug against should be able to say when
# it was made instead of `dev`.
run "recording what this build is" env MIX_ENV=desktop mix build.info

# Signing is macOS's problem: `ElixirKit.Release.codesign/1` runs `codesign`
# over 2 700 files so a signed app is not one that refuses to launch, and there
# is nothing on Linux or Windows for it to sign. Asking for it there would fail
# the release on a tool that is simply absent.
if [[ $platform == macos ]]; then
  run "building the sidecar release, signed (ad-hoc without a certificate)" \
    env MIX_ENV=desktop CONFLUENCE_SIGN_RELEASE=1 mix release --overwrite
else
  run "building the sidecar release" \
    env MIX_ENV=desktop mix release --overwrite
fi

# The window is built after the release on purpose: the release has to exist
# before it can be put beside (or inside) the window, or the build would carry
# the previous one — the trap that made a window start code from hours earlier.
if [[ $platform == macos ]]; then
  run "building the application shell" \
    cargo tauri build --bundles app --config "$bundle_config"
elif [[ $platform == windows ]]; then
  # Bundling on, because the point of this platform's artifact is an installer:
  # `tauri-bundler` builds the window, copies `rel\` in as a resource, and hands
  # the lot to NSIS. The portable folder below is still staged from the same
  # window binary, so a machine that downloads the zip gets what it always got.
  #
  # The bundle directory is cleared first: the workflow caches `src-tauri/target`,
  # and a setup.exe left by a previous run is last week's release carrying this
  # week's name.
  rm -rf src-tauri/target/release/bundle
  run "building the window and its installer" \
    cargo tauri build --config "$installer_config"
else
  # No bundling: on these platforms the artifact *is* a folder, and letting
  # Tauri bundle would run its resource copy — the step that fails on this
  # toolchain (`scripts/lib/bundle.sh`) and that we do not need, because the
  # release is copied in by hand below.
  run "building the window" cargo tauri build --no-bundle
fi

# The release goes where the installed window looks for it, rather than through
# `bundle.resources`: Tauri's own copy of this tree (2 700 files, addressed
# across a `..` in the config) fails in its resource phase with "Permission
# denied (os error 13)" on this toolchain, and one copy puts it exactly where
# `src-tauri/src/main.rs` looks it up — `resource_dir()/rel/confluence_phx_mirror`
# in a bundle, and the directory beside the binary in a portable folder.
run "carrying the release to where the window looks for it" stage_release

if [[ $platform != macos ]]; then
  run "staging the window and what it needs beside it" stage_window
fi

run "booting the release the artifact carries and asking it to serve" boot_check

run "assembling the artifact" assemble

if [[ $install_after == yes ]]; then
  if [[ $platform != macos ]]; then
    echo "--install writes into ~/Applications and only makes sense on macOS"
    exit 64
  fi

  run "installing that build the way a download installs" \
    env CONFLUENCE_EXPORT_BASE_URL="file://$PWD/$out" ./install-desktop.sh
fi

echo
echo "artifact: $out/$asset"
echo "uploaded by the workflow as: confluence-export-$platform"
[[ $install_after == yes ]] || echo "to install it: scripts/package.sh --install"
