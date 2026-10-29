#!/usr/bin/env bash
#
# Turn one square mark into the favicon that shows in a browser tab.
#
#   ./scripts/favicon.sh                        # img/logo/concept1-square.png → priv/static/favicon.ico
#   ./scripts/favicon.sh img/logo/other.png     # another mark, same destination
#   ./scripts/favicon.sh --out /tmp/try.ico     # look at it before committing it
#
#   ./scripts/favicon.sh img/logo/concept1-square-static.png \
#                        --out priv/static/images/archive-favicon.ico
#
# Two files come out of this, and they are different on purpose:
#
#   priv/static/favicon.ico                  what this site serves, at /favicon.ico
#   priv/static/images/archive-favicon.ico   what a static export carries inside
#                                            its ZIP, as assets/favicon.ico
#
# The output is one ICO holding a 16, 32 and 48 pixel render, because that is
# the format that is *portable*: every browser takes it, no `<link rel="icon"
# type=…>` negotiation and no second file, so the same artifact works served
# from a domain, opened from a folder over file://, and dropped beside an
# exported page. The tab, the bookmark bar and the desktop shortcut each pick
# the frame drawn for them instead of a downscaled one.
#
# The mark is trimmed to what it paints and centred in every frame, on white:
# a concept drawn with a generous margin would otherwise show a speck in a 16
# pixel tab. Pass --no-trim to keep the source's own canvas.
#
# ImageMagick does the conversion (`magick`, or `convert` on a 6.x install) —
# it is the one tool on a laptop that reads PNG and writes multi-frame ICO.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SOURCE=img/logo/concept1-square.png
OUT=priv/static/favicon.ico
SIZES=(48 32 16)
TRIM=1
# The concepts sit on a near-white gradient, not on flat white: trim needs
# enough tolerance to see the margin as margin.
FUZZ=8%

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="${2:?--out needs a file name}"
      shift 2
      ;;
    --sizes)
      IFS=, read -r -a SIZES <<< "${2:?--sizes needs sizes, e.g. 48,32,16}"
      shift 2
      ;;
    --no-trim)
      TRIM=0
      shift
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    -*)
      echo "error: unknown option $1 (try --help)" >&2
      exit 64
      ;;
    *)
      SOURCE="$1"
      shift
      ;;
  esac
done

if [[ ${#SIZES[@]} -eq 0 ]]; then
  echo "error: --sizes needs at least one size, e.g. 48,32,16" >&2
  exit 64
fi

MAGICK=$(command -v magick || command -v convert || true)
if [[ -z "$MAGICK" ]]; then
  echo "error: ImageMagick is not installed: brew install imagemagick" >&2
  exit 69
fi

if [[ ! -f "$SOURCE" ]]; then
  echo "error: no such image: $SOURCE" >&2
  exit 66
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mark=$SOURCE
if ((TRIM)); then
  mark=$work/mark.png
  "$MAGICK" "$SOURCE" -fuzz "$FUZZ" -trim +repage "$mark"
fi

# One render per size: scaled to fit the frame with a margin, then centred on
# a square of exactly that size.
frames=()
for size in "${SIZES[@]}"; do
  inner=$((size * 92 / 100))

  "$MAGICK" "$mark" \
    -resize "${inner}x${inner}" \
    -background white -gravity center -extent "${size}x${size}" \
    "$work/$size.png"

  frames+=("$work/$size.png")
done

mkdir -p "$(dirname "$OUT")"
"$MAGICK" "${frames[@]}" "$OUT"

printf '%s ← %s (%s)\n' "$OUT" "$SOURCE" \
  "$("$MAGICK" identify -format '%wx%h ' "$OUT" | sed 's/ $//')"
