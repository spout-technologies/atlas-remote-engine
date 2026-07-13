#!/usr/bin/env bash
#
# gen_atlas_icons.sh — regenerate every Atlas Remote icon asset from the
# canonical artwork at res/atlas-icon.svg.
#
# Artwork: rounded-square app icon — pale grey-green background (#eaeee7)
# with two interlocking ribbon strokes (#6ea924 bright green, #b3cab3 sage).
#
# Outputs (all overwritten in place):
#   res/            icon.png (512), 32x32.png, 64x64.png, 128x128.png,
#                   128x128@2x.png (256), mac-icon.png (1024),
#                   icon.ico (16/24/32/48/64/128/256), tray-icon.ico (16/24/32),
#                   mac-tray-dark-x2.png + mac-tray-light-x2.png (60x60
#                   monochrome template glyphs), scalable.svg (copy of source —
#                   installed by Linux packaging as the hicolor scalable icon).
#   flutter/assets/ icon.png (512), icon.svg (copy of source), logo.svg +
#                   logo_light.svg + logo_dark.svg (ribbon mark only; light and
#                   dark chrome recolours are simple fill swaps).
#   flutter/macos/Runner/AppIcon.icns            (full 10-slot iconset; macOS only)
#   flutter/windows/runner/resources/app_icon.ico (16/24/32/48/64/128/256)
#   flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png
#                   (every PNG referenced by Contents.json, flattened opaque —
#                   Apple rejects alpha; Contents.json itself is not touched)
#   flutter/android/app/src/main/res/mipmap-*/ic_launcher.png (48..192),
#                   ic_launcher_round.png (circular mask), ic_launcher_foreground.png
#                   (adaptive-icon foreground: ribbon glyph at ~66% on transparency),
#                   values/ic_launcher_background.xml (#EAEEE7)
#   fastlane/metadata/android/en-US/images/icon.png (512)
#
# Requirements: rsvg-convert (librsvg), magick (ImageMagick 7), python3;
#               iconutil for the .icns step (macOS — skipped elsewhere with a warning).
#
# Usage: bash res/gen_atlas_icons.sh   (from anywhere; paths are self-resolved)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${SCRIPT_DIR}/atlas-icon.svg"

BG_COLOUR="#eaeee7"   # rounded-square background
GREEN="#6ea924"       # bright green ribbon
SAGE="#b3cab3"        # sage ribbon
SAGE_LIGHT_CHROME="#9dba9d"   # sage recolour used on light chrome (matches wordmark convention)
SAGE_DARK_CHROME="#eff5ef"    # sage recolour used on dark chrome (matches wordmark convention)

for tool in rsvg-convert magick python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found" >&2; exit 1; }
done
[ -f "$SRC" ] || { echo "ERROR: source artwork missing: $SRC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Render the full rounded-square icon at an exact square pixel size.
render() { # render <size> <dest> [source-svg]
    rsvg-convert -w "$1" -h "$1" "${3:-$SRC}" -o "$2"
}

# ---------------------------------------------------------------------------
# 1. Glyph derivation — extract the two ribbon <path> elements from the source
#    SVG (dropping the rounded-square background) and emit recoloured
#    stand-alone SVGs: the flutter logo marks and monochrome tray glyphs.
#    The viewBox is squared around the ribbons' numeric bounding box.
# ---------------------------------------------------------------------------
python3 - "$SRC" "$TMP" "$ROOT" "$GREEN" "$SAGE" "$SAGE_LIGHT_CHROME" "$SAGE_DARK_CHROME" <<'PY'
import re, sys

src, tmp, root, green, sage, sage_light, sage_dark = sys.argv[1:8]
svg = open(src).read()

# The two ribbons are the only <path> elements carrying fill attributes.
paths = re.findall(r'<path fill="(#[0-9a-fA-F]{6})" d="([^"]+)"', svg)
if len(paths) != 2:
    sys.exit(f"expected 2 filled ribbon paths in {src}, found {len(paths)}")

# Square viewBox centred on the ribbons (control-point bounding box + padding).
nums = [float(n) for _, d in paths for n in re.findall(r'-?\d+\.?\d*', d)]
xs, ys = nums[0::2], nums[1::2]
minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
side = max(maxx - minx, maxy - miny) * 1.06          # ~3% padding each side
vx = (minx + maxx) / 2 - side / 2
vy = (miny + maxy) / 2 - side / 2
viewbox = f"{vx:.3f} {vy:.3f} {side:.3f} {side:.3f}"

def glyph(colour_map, dest):
    body = "".join(
        f'<path fill="{colour_map[fill.lower()]}" fill-rule="evenodd" d="{d}"/>'
        for fill, d in paths)
    with open(dest, "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}">{body}</svg>\n')

identity = {green: green, sage: sage}
glyph(identity, f"{tmp}/glyph-colour.svg")                                  # adaptive-icon foreground
glyph({green: "#000000", sage: "#000000"}, f"{tmp}/glyph-mono-black.svg")   # macOS tray template (dark)
glyph({green: "#ffffff", sage: "#ffffff"}, f"{tmp}/glyph-mono-white.svg")   # macOS tray template (light)
glyph(identity, f"{root}/flutter/assets/logo.svg")                          # brand mark
glyph({green: green, sage: sage_light}, f"{root}/flutter/assets/logo_light.svg")  # light chrome
glyph({green: green, sage: sage_dark}, f"{root}/flutter/assets/logo_dark.svg")    # dark chrome
PY

# ---------------------------------------------------------------------------
# 2. res/ — core engine icons (consumed by src/tray.rs, packaging, installers)
# ---------------------------------------------------------------------------
render 512  "${SCRIPT_DIR}/icon.png"
render 32   "${SCRIPT_DIR}/32x32.png"
render 64   "${SCRIPT_DIR}/64x64.png"
render 128  "${SCRIPT_DIR}/128x128.png"
render 256  "${SCRIPT_DIR}/128x128@2x.png"
render 1024 "${SCRIPT_DIR}/mac-icon.png"
cp "$SRC" "${SCRIPT_DIR}/scalable.svg"   # Linux hicolor scalable icon (installed as rustdesk.svg)

# Multi-resolution Windows .ico files (PNG-compressed entries, alpha kept).
for s in 16 24 32 48 64 128 256; do render "$s" "${TMP}/ico-${s}.png"; done
magick "${TMP}/ico-16.png" "${TMP}/ico-24.png" "${TMP}/ico-32.png" "${TMP}/ico-48.png" \
       "${TMP}/ico-64.png" "${TMP}/ico-128.png" "${TMP}/ico-256.png" "${SCRIPT_DIR}/icon.ico"
magick "${TMP}/ico-16.png" "${TMP}/ico-24.png" "${TMP}/ico-32.png" "${SCRIPT_DIR}/tray-icon.ico"

# macOS menu-bar template icons: 60x60 monochrome ribbon glyph on transparency
# (macOS recolours template images itself; dark = black ink, light = white ink).
render 60 "${SCRIPT_DIR}/mac-tray-dark-x2.png"  "${TMP}/glyph-mono-black.svg"
render 60 "${SCRIPT_DIR}/mac-tray-light-x2.png" "${TMP}/glyph-mono-white.svg"

# ---------------------------------------------------------------------------
# 3. flutter/assets — in-app icon + vector marks
# ---------------------------------------------------------------------------
render 512 "${ROOT}/flutter/assets/icon.png"
cp "$SRC" "${ROOT}/flutter/assets/icon.svg"

# ---------------------------------------------------------------------------
# 4. macOS AppIcon.icns — full 10-slot iconset via iconutil (macOS only)
# ---------------------------------------------------------------------------
if command -v iconutil >/dev/null 2>&1; then
    ICONSET="${TMP}/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        render "$s"          "${ICONSET}/icon_${s}x${s}.png"
        render "$((s * 2))"  "${ICONSET}/icon_${s}x${s}@2x.png"
    done
    iconutil -c icns "$ICONSET" -o "${ROOT}/flutter/macos/Runner/AppIcon.icns"
else
    echo "WARN: iconutil unavailable — flutter/macos/Runner/AppIcon.icns NOT regenerated" >&2
fi

# ---------------------------------------------------------------------------
# 5. Windows runner icon
# ---------------------------------------------------------------------------
magick "${TMP}/ico-16.png" "${TMP}/ico-24.png" "${TMP}/ico-32.png" "${TMP}/ico-48.png" \
       "${TMP}/ico-64.png" "${TMP}/ico-128.png" "${TMP}/ico-256.png" \
       "${ROOT}/flutter/windows/runner/resources/app_icon.ico"

# ---------------------------------------------------------------------------
# 6. iOS AppIcon.appiconset — regenerate every PNG referenced by Contents.json
#    at its exact point-size x scale, flattened onto the background colour
#    (App Store icons must carry no alpha channel).
# ---------------------------------------------------------------------------
APPICONSET="${ROOT}/flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset"
python3 - "${APPICONSET}/Contents.json" > "${TMP}/ios-manifest.txt" <<'PY'
import json, sys
seen = {}
for img in json.load(open(sys.argv[1]))["images"]:
    px = round(float(img["size"].split("x")[0]) * int(img["scale"].rstrip("x")))
    seen[img["filename"]] = px
for name, px in seen.items():
    print(name, px)
PY
while read -r name px; do
    render "$px" "${TMP}/ios-tmp.png"
    magick "${TMP}/ios-tmp.png" -background "$BG_COLOUR" -alpha remove -alpha off \
           "PNG24:${APPICONSET}/${name}"
done < "${TMP}/ios-manifest.txt"

# ---------------------------------------------------------------------------
# 7. Android launcher icons
#    - ic_launcher.png        : full artwork (legacy launchers)
#    - ic_launcher_round.png  : full artwork under a circular alpha mask
#    - ic_launcher_foreground : adaptive-icon foreground — ribbon glyph at ~66%
#                               of the canvas on transparency (the #EAEEE7
#                               background layer is supplied by the colour
#                               resource below)
# ---------------------------------------------------------------------------
ANDROID_RES="${ROOT}/flutter/android/app/src/main/res"
DENSITIES=(mdpi hdpi xhdpi xxhdpi xxxhdpi)
LAUNCHER_PX=(48 72 96 144 192)
FOREGROUND_PX=(162 243 324 486 648)

for i in "${!DENSITIES[@]}"; do
    d="${DENSITIES[$i]}"; lp="${LAUNCHER_PX[$i]}"; fp="${FOREGROUND_PX[$i]}"
    dir="${ANDROID_RES}/mipmap-${d}"

    render "$lp" "${dir}/ic_launcher.png"

    # Circular mask: keep artwork alpha only where the inscribed circle is opaque.
    magick "${dir}/ic_launcher.png" \
        \( -size "${lp}x${lp}" xc:none -fill white \
           -draw "circle $((lp / 2)),$((lp / 2)) $((lp / 2)),0" \) \
        -alpha on -compose DstIn -composite "${dir}/ic_launcher_round.png"

    # Glyph at ~66% of the canvas, centred, transparent surround.
    g=$(( fp * 66 / 100 ))
    render "$g" "${TMP}/fg-glyph.png" "${TMP}/glyph-colour.svg"
    magick "${TMP}/fg-glyph.png" -background none -gravity center \
           -extent "${fp}x${fp}" "${dir}/ic_launcher_foreground.png"
done

# Adaptive-icon background layer colour (referenced by mipmap-anydpi-v26 XMLs).
cat > "${ANDROID_RES}/values/ic_launcher_background.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#EAEEE7</color>
</resources>
XML

# ---------------------------------------------------------------------------
# 8. F-Droid / fastlane store icon
# ---------------------------------------------------------------------------
render 512 "${ROOT}/fastlane/metadata/android/en-US/images/icon.png"

echo "OK: Atlas Remote icon assets regenerated from ${SRC}"
