# WAM Coin brand assets

The mark is a struck gold coin on black: the letter **W** over a dotted world
map and a circuit trace, inside a milled rim. Adopted 2026-08-18 and final.

---

## Which file to use

| File | Use |
|---|---|
| `png/wam-platform-200.png` | **Exchange and wallet listings.** The size almost every venue asks for. |
| `png/wam-platform-32.png` … `-2048.png` | The same mark at 32, 64, 128, 256, 512 and 2048. Favicon at 32, app icon at 512. |
| `png/wam-social-512.png` … `-2048.png` | **Announcements only.** The coin with the supply figure and the launch date struck into it. |
| `png/wam-platform-master-1080.jpg` | Source render, plain mark. |
| `png/wam-social-master-1080.jpg` | Source render, with legend. |

All PNGs are RGBA with a genuinely transparent background — the coin is masked
to its own circle, so it sits correctly on a light interface and a dark one.
The JPEG masters are not transparent and are kept only as the originals.

---

## The one rule that matters

**The plain mark is the identity. The one with text is not.**

The version carrying the supply figure and `WAMCOIN · 15 · 9 · 2026` is
announcement artwork. It is dated, it carries a number, and at the 32 pixels an
exchange renders a logo at, both become noise. It is right for a launch post
and wrong everywhere the identity appears.

The plain mark goes everywhere and never changes. Consistency is most of what
makes a mark recognisable, and a mark that varies by context is not one.

---

## Sizes, and why nothing larger

2048 is the largest useful size. Exchanges and wallets render listing logos
between 24 and 200 pixels; aggregators ask for 200 or 256. Anything above 2048
is bytes nobody downloads — a 7680 square PNG of this artwork is over sixty
megabytes and renders identically to the 512.

If a venue asks for a size that is not here, downscale from
`png/wam-platform-2048.png` rather than from a smaller file.

---

## Colour

Read off the render rather than specified in advance, because the mark is a 3D
render and not a flat vector.

| | Approximate | Use |
|---|---|---|
| Coin gold | `#E8A93C` | The rim, the letter, the circuit traces. |
| Deep gold | `#B07818` | Shadow side of the rim and the letter bevel. |
| Field | `#141210` | The near-black behind the map. |

For anything needing a flat colour — a single-ink stamp, an engraving, a
terminal — use the gold on the field and do not try to reproduce the bevels.
They do not survive the reduction.

---

## `legacy/`

Everything under `legacy/` is a **superseded** design: a flat green hexagon,
with an SVG pipeline and the PNGs it generated. It was replaced by the coin
above and is kept only so the history is not lost.

Nothing there should be used. If you are looking for a logo, it is in `png/`.

The scripts that produced it are kept alongside it for the same reason:
`legacy/make_coin_face.py`, `legacy/make_marketing_sizes.py` and
`legacy/render.sh`.
