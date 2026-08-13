# WAM Coin brand assets

| File | Use |
|---|---|
| `wam-icon.svg` | Primary mark. Default for anything ≥ 48px. |
| `wam-logo.svg` | Horizontal lockup (mark + wordmark). Whitepaper header, site header, README. |
| `wam-icon-mono.svg` | Single ink. Engraving, embossing, stamps, screen print, fax. Inherits `currentColor`. |
| `wam-coin.svg` | Circular coin face, no legend. Exchange listings, wallet token lists, market-data aggregators. |
| `wam-coin-face.svg` | The coin with its legends. Official use: email signatures, documents, print. |
| `wam-coin-face-struck.svg` | The same coin with a struck-metal finish. Screens only, 128px and up. |
| `wam-favicon.svg` | 16–48px. **Not** the primary icon scaled down — redrawn for small sizes. |

---

## Palette

| | Hex | Use |
|---|---|---|
| Primary | `#0B7C5C` | The hexagon. Also the accent colour in the pool dashboard and explorer. |
| Ink | `#0B2C22` | Wordmark, body text on light. |
| On dark | `#14B88A` | Substitute for the primary on dark backgrounds — `#0B7C5C` fails contrast there. |
| Coin field | `#D9A63C` | Coin face only. Never for UI. |
| Coin rim | `#A8761A` / `#8A5F10` | Coin face only. |

---

## Design decisions, and why

**Flat, always.** No gradients, bevels, or drop shadows anywhere. A logo that needs a
gradient breaks the moment it is embroidered, foil-stamped, printed in one colour, faxed to
a regulator, or rendered at 16px. Every asset here survives all of those.

**Hexagon, not a circle.** The block motif, and a silhouette that is actually
distinguishable in a market where nearly every mark is a circle with a letter in it.

**The W's centre vertex rises above its arms**, at a 1:6 proportion. This is the whole
identity in one decision: symmetric, because a currency should read as balanced rather than
tilted; but rising, because a static W is forgettable. The wordmark's W repeats it at the
same ratio, which is what ties mark and type into one system.

**The wordmark is drawn, never typeset.** There is no `<text>` element and no font
dependency in any file. It renders identically on a machine that has never heard of the
font, and cannot be silently substituted by a PDF pipeline.

**The favicon is a different drawing.** The hexagon is enlarged to fill the tile (optical
margin is wasted pixels at 16px), the stroke is thickened 11 → 14 so it survives one-pixel
rendering, and the centre spire is shortened — at that size the extra height reads as an
artefact rather than as intent.

**The monochrome variant knocks the W out** rather than drawing it on top, so the mark is
one solid shape in one ink. It uses a mask referencing the identical W path, so it can
never drift out of sync with the primary.

---

## The coin face

Four positions. They do not move between variants:

```
        22,000,000          the supply ceiling
            W               the mark
     WAMCOIN.15.9.2026      the name and the genesis date
```

**Colour, finish and ornament may vary. These positions may not.** That single
rule is what lets a flat asset and a rich marketing image read as the same
coin rather than as two identities. A silver edition, a print edition, an
anniversary edition — all of them keep the four positions and change whatever
else they like.

**Only what can be checked goes on the coin.** The ceiling is enforced by
consensus and the date is the genesis timestamp; both can be verified against
a running node. No price, no slogan, and specifically not "decentralized
digital currency" — a claim every coin makes and none of them proves.

`make_coin_face.py` generates both files, extracting the legends from the font
as outlines. Nothing font-dependent survives into the shipped SVG, because an
asset carrying `<text>` renders with whatever the viewer happens to have
installed, and a coin whose legend reflows on someone else's machine is worse
than no coin at all. The script refuses to write a file that still contains
`<text>`, `font-family` or `textPath`.

The arc is built one glyph at a time rather than with `<textPath>`. librsvg,
which renders every PNG in this directory, ignores `textPath` completely and
emits a coin with no legend and no warning.

## Clear space and minimum sizes

- **Clear space:** at least the height of the hexagon on every side of the lockup.
- **Minimum lockup width:** 120px. Below that use `wam-icon.svg` alone.
- **Minimum icon size:** 24px for `wam-icon.svg`; use `wam-favicon.svg` below that.

## Don't

- Don't recolour the hexagon outside the palette above.
- Don't place `#0B7C5C` on a dark background — use `#14B88A`.
- Don't stretch, skew, rotate, or add effects.
- Don't reconstruct the wordmark in a system font.
- Don't use the coin face in UI; it is a listing asset.

---

## Producing raster files

```bash
# PNGs for exchange listings (they usually want 200 and 400 px, circular)
rsvg-convert -w 400 -h 400 brand/wam-coin.svg -o wam-coin-400.png
rsvg-convert -w 200 -h 200 brand/wam-coin.svg -o wam-coin-200.png

# favicon.ico
rsvg-convert -w 48 -h 48 brand/wam-favicon.svg -o f48.png
rsvg-convert -w 32 -h 32 brand/wam-favicon.svg -o f32.png
rsvg-convert -w 16 -h 16 brand/wam-favicon.svg -o f16.png
convert f16.png f32.png f48.png favicon.ico
```

---

## A note on a currency symbol

WAM ships **without** an invented currency glyph, on purpose. The obvious candidate — a W
with a horizontal bar — is one stroke away from **₩** (Korean won, U+20A9), which is a W
with two bars. A symbol that is misread as an existing national currency is worse than no
symbol at all.

Use the ticker `WAM`, or the hexagon mark where a glyph is needed.
