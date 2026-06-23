#!/usr/bin/env bash
#
# Recolor the upstream cmux blue chevron into the Chatmux magenta -> red ->
# orange chevron, in place, across every app-icon asset.
#
# How it works: a selective hue rotation. Only blue/cyan/purple chevron
# pixels (hue band ~cyan..purple, with non-trivial saturation) are rotated;
# the orange "DEV"/"NIGHTLY" banners and the white/dark backgrounds are left
# untouched. Whole-image rotation can't be used because it would turn the
# orange banner green.
#
# Idempotent: red/orange pixels fall OUTSIDE the recolor hue band, so
# re-running is a no-op on already-red assets. After `/sync-upstream`, if
# upstream shipped a new (blue) icon, just re-run this script to reapply the
# Chatmux red — that's why this is a script and not a one-off manual edit.
#
# Requires ImageMagick 7 (`magick`). Install with `brew install imagemagick`.
#
# Variant: the default hue (+135deg) is "variant A" — magenta->red->orange.
# Override with CHATMUX_ICON_HUE if you want a different red:
#   175 = +135deg (default, magenta->red->orange)
#   183 = +150deg (crimson/red->orange)
set -euo pipefail

HUE="${CHATMUX_ICON_HUE:-175}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v magick >/dev/null 2>&1; then
  echo "error: ImageMagick 'magick' not found. Install with: brew install imagemagick" >&2
  exit 1
fi

recolor() {
  local f="$1"
  local t
  t="$(mktemp -d)"
  # 1) Whole-image hue rotation (blue -> red/magenta).
  magick "$f" -modulate 100,100,"$HUE" "$t/rot.png"
  # 2) Build a mask isolating the blue chevron + its glow:
  #    hue band [42%,83%] (cyan..purple) AND saturation > 5%.
  magick "$f" -colorspace HSB -channel R -separate "$t/hue.png"
  magick "$f" -colorspace HSB -channel G -separate "$t/sat.png"
  magick "$t/hue.png" -threshold 42% "$t/hLo.png"
  magick "$t/hue.png" -threshold 83% -negate "$t/hHi.png"
  magick "$t/hLo.png" "$t/hHi.png" -compose multiply -composite "$t/band.png"
  magick "$t/sat.png" -threshold 5% "$t/satm.png"
  magick "$t/band.png" "$t/satm.png" -compose multiply -composite "$t/mask.png"
  magick "$t/mask.png" -blur 0x1.0 "$t/mask.png"
  # 3) Composite the rotated image over the original through the mask, so
  #    only the chevron changes. Pixel dimensions are preserved (no resize).
  magick "$f" "$t/rot.png" "$t/mask.png" -compose over -composite "$t/out.png"
  cp "$t/out.png" "$f"
  rm -rf "$t"
  echo "  recolored: $f"
}

# Glob targets (no spaces in these directory names).
for f in \
  Assets.xcassets/AppIcon.appiconset/*.png \
  Assets.xcassets/AppIcon-Debug.appiconset/*.png \
  Assets.xcassets/AppIcon-Nightly.appiconset/*.png \
  Assets.xcassets/AppIconDark.imageset/*.png \
  Assets.xcassets/AppIconLight.imageset/*.png; do
  [ -f "$f" ] && recolor "$f"
done

# Icon Composer source chevron (filename contains a space; handle literally).
chevron="AppIcon.icon/Assets/cmux-icon-chevron 2.png"
[ -f "$chevron" ] && recolor "$chevron"

echo "done. Rebuild + reinstall to see the new icon (reload.sh --tag ... then install-fork.sh)."
