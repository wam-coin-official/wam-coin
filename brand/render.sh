#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  render.sh -- turn the SVGs into the PNGs people actually ask for
# ===========================================================================
#
#      bash brand/render.sh [outdir]      # default: brand/png
#
#  Every asset here is vector, which is correct for the source and useless in
#  practice: email clients, exchange listing forms, Telegram, and X all want a
#  PNG at a fixed size, and every one of them will happily accept a screenshot
#  instead. A screenshot of a logo is how a brand starts looking cheap -- it
#  arrives with the wrong colours, a grey fringe from subpixel antialiasing,
#  and whatever was behind the window.
#
#  So the PNGs are generated, not drawn, and generated from the same SVG the
#  site uses. They cannot drift.
#
#  TWO BACKGROUNDS, ON PURPOSE
#
#  Transparent is correct everywhere except email. Outlook and several mobile
#  clients composite a transparent PNG onto whatever the theme background is,
#  so a dark-mode reader gets a dark logo on dark. The -on-white files exist
#  for exactly that, and are the ones to paste into a signature.
# ===========================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/png}"

GREEN=$'\033[32m'; OFF=$'\033[0m'
ok() { printf '  %sok%s    %s\n' "$GREEN" "$OFF" "$*"; }

command -v rsvg-convert >/dev/null 2>&1 || {
    printf 'rsvg-convert is not installed:  sudo apt-get install -y librsvg2-bin\n' >&2
    exit 1
}

mkdir -p "$OUT"

# name:viewbox-width:viewbox-height
SQUARE="wam-coin wam-icon wam-icon-mono"
SIZES="1024 512 256 200 128 64"

for name in $SQUARE; do
    for s in $SIZES; do
        rsvg-convert -w "$s" -h "$s" "$HERE/${name}.svg" -o "$OUT/${name}-${s}.png"
    done
    ok "${name}: $(echo $SIZES | tr ' ' ',')"
done

# The lockup is 300x120, so height drives it -- asking for a square would
# letterbox it and no one checks before uploading.
for h in 512 256 160 120 80; do
    w=$(( h * 300 / 120 ))
    rsvg-convert -w "$w" -h "$h" "$HERE/wam-logo.svg" -o "$OUT/wam-logo-${h}h.png"
done
ok "wam-logo: 512,256,160,120,80 tall (2.5:1)"

for s in 16 32 48; do
    rsvg-convert -w "$s" -h "$s" "$HERE/wam-favicon.svg" -o "$OUT/wam-favicon-${s}.png"
done
ok "wam-favicon: 16,32,48"

# ---------------------------------------------------------------------------
# The email versions. rsvg-convert has --background-color, which composites
# during rendering rather than pasting a rectangle behind afterwards, so the
# edge antialiasing blends against white instead of against nothing and then
# white -- which is what produces the grey halo people notice and cannot name.
for spec in "wam-coin 512" "wam-coin 256" "wam-icon 512" "wam-icon 256"; do
    set -- $spec
    rsvg-convert -w "$2" -h "$2" --background-color white \
        "$HERE/$1.svg" -o "$OUT/$1-$2-on-white.png"
done
for h in 160 120 80; do
    w=$(( h * 300 / 120 ))
    rsvg-convert -w "$w" -h "$h" --background-color white \
        "$HERE/wam-logo.svg" -o "$OUT/wam-logo-${h}h-on-white.png"
done
ok "on-white variants for email"

echo
printf '  %s files in %s\n' "$(find "$OUT" -name '*.png' | wc -l)" "$OUT"
du -sh "$OUT" | awk '{printf "  %s total\n", $1}'
