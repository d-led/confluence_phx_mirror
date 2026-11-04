# The release an application bundle carries, inside the bundle.
#
# `src-tauri/src/main.rs` looks for its sidecar at
# `resource_dir()/rel/confluence_phx_mirror/bin/confluence_phx_mirror`, which in
# a macOS app is `Contents/Resources/rel/confluence_phx_mirror`. Two scripts
# build a bundle — `start-desktop.sh --app` and `package.sh` — so the path and the
# copy live here rather than in each of them, or the app one of them opens would
# be the one that starts nothing.
#
# It is not `bundle.resources`: Tauri's own copy of this tree (2 700 files,
# addressed across a `..` in the config) fails in its resource phase with
# "Permission denied (os error 13)" on this toolchain, and one `ditto` puts it
# exactly where the shell looks.
#
#   bundle_embed_release "path/to/Thing.app" "_build/desktop/rel/the_app" the_app
bundle_embed_release() {
  local app=$1 bundle_src=$2 app_name=$3 dest
  dest="$app/Contents/Resources/rel/$app_name"

  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  ditto "$bundle_src" "$dest"

  # Without an executable sidecar there, the window starts nothing — and a bundle
  # that opens on a blank window is worse than one that fails here.
  test -x "$dest/bin/$app_name"
}
