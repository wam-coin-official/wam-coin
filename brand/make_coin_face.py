#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""Generate the coin faces, with every legend as an outline.

    python3 brand/make_coin_face.py

Writes brand/wam-coin-face.svg (flat) and brand/wam-coin-face-struck.svg.

WHY THIS IS A GENERATOR AND NOT A DRAWING

brand/README.md forbids a font dependency in any shipped asset, for a reason
that is not stylistic: an SVG carrying <text> renders with whatever the
viewer has installed. On a machine without DejaVu Sans the legend reflows,
the arc spacing breaks, and the coin arrives at an exchange looking like a
mistake. Fonts also cannot be relied on inside PDF pipelines or print RIPs.

So the digits and letters are extracted from the font as outlines here, once,
and the shipped SVG contains paths only. Nothing at render time can change
them.

The arc is built by placing each glyph individually rather than with
<textPath>: librsvg -- which renders this project's PNGs -- ignores textPath
entirely and silently produces a coin with no legend at all.

THE LAYOUT IS FIXED

Four positions, and they do not move between variants:

    22,000,000            the supply ceiling, consensus-enforced
        W                 the mark
  WAMCOIN.15.9.2026       the name and the genesis date

Colour, finish and ornament may vary; these positions may not. That is what
lets a flat asset and a struck marketing image read as the same coin.
"""
import math
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

try:
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.ttLib import TTFont
except ImportError:
    sys.exit('fontTools is required:  python3 -m pip install --user fonttools')

HERE = pathlib.Path(__file__).resolve().parent

FONT_CANDIDATES = [
    '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
    '/usr/share/fonts/TTF/DejaVuSans-Bold.ttf',
    'C:/Windows/Fonts/DejaVuSans-Bold.ttf',
]

W_PATH = 'M32 42 L46 82 L60 34 L74 82 L88 42'

# The legends. Anything here is a claim, so anything here must be checkable
# from the chain: the cap is enforced by consensus, the date is the genesis
# timestamp. No price, no slogan, no "decentralized digital currency".
SUPPLY = '22,000,000'
LEGEND = 'WAMCOIN.15.9.2026'

FLAT = dict(rim='#A8761A', mill='#8A5F10', field='#D9A63C', ink='#6B4A0E')
GOLD_HI, GOLD_DEEP = '#F4D98B', '#5E400B'


def load_font():
    for p in FONT_CANDIDATES:
        if pathlib.Path(p).exists():
            return TTFont(p)
    sys.exit('DejaVuSans-Bold.ttf not found; edit FONT_CANDIDATES')


class Glyphs:
    """Character outlines, in font units, cached."""

    def __init__(self, font):
        self.font = font
        self.gs = font.getGlyphSet()
        self.cmap = font.getBestCmap()
        self.upem = font['head'].unitsPerEm
        self.cap = getattr(font['OS/2'], 'sCapHeight', None) or int(self.upem * 0.73)
        self._cache = {}

    def outline(self, ch):
        if ch in self._cache:
            return self._cache[ch]
        name = self.cmap.get(ord(ch))
        if name is None:
            raise SystemExit(f'the font has no glyph for {ch!r}')
        pen = SVGPathPen(self.gs)
        self.gs[name].draw(pen)
        adv = self.gs[name].width
        self._cache[ch] = (pen.getCommands(), adv)
        return self._cache[ch]


def arc_glyphs(g, text, radius, size, top, spread, colour, dx=0.0, dy=0.0):
    """One <path> per character, positioned and rotated around (60, 60)."""
    n = len(text)
    step = spread / (n - 1) if n > 1 else 0.0
    total = step * (n - 1)
    s = size / g.upem
    out = []
    for i, ch in enumerate(text):
        d, adv = g.outline(ch)
        if not d.strip():
            continue
        th = (-90 - total / 2 + i * step) if top else (90 + total / 2 - i * step)
        rot = th + 90 if top else th - 90
        x = 60 + radius * math.cos(math.radians(th)) + dx
        y = 60 + radius * math.sin(math.radians(th)) + dy
        out.append(
            f'<path transform="translate({x:.3f} {y:.3f}) rotate({rot:.3f})'
            f' scale({s:.6f} {-s:.6f}) translate({-adv / 2:.1f} {-g.cap / 2:.1f})"'
            f' d="{d}" fill="{colour}"/>')
    return ''.join(out)


def reeding(r_out, r_in, n, hi, lo, mid):
    out = []
    for i in range(n):
        a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 0.5) / n
        lit = math.cos(a0 - math.radians(-135))
        col = hi if lit > 0.25 else (lo if lit < -0.25 else mid)
        pts = [(60 + r_in * math.cos(a0), 60 + r_in * math.sin(a0)),
               (60 + r_out * math.cos(a0), 60 + r_out * math.sin(a0)),
               (60 + r_out * math.cos(a1), 60 + r_out * math.sin(a1)),
               (60 + r_in * math.cos(a1), 60 + r_in * math.sin(a1))]
        out.append('<path d="M' + 'L'.join(f'{x:.2f} {y:.2f}' for x, y in pts)
                   + f'Z" fill="{col}"/>')
    return ''.join(out)


def w_mark(colour, cy=59.0, sc=0.70):
    return (f'<g transform="translate(60,{cy}) scale({sc}) translate(-60,-60)">'
            f'<path d="{W_PATH}" fill="none" stroke="{colour}" stroke-width="11"'
            f' stroke-linecap="round" stroke-linejoin="round"/></g>')


HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120"'
        ' width="120" height="120" role="img"'
        ' aria-labelledby="t d">\n'
        '<title id="t">WAM Coin — coin face</title>\n'
        '<desc id="d">A milled coin bearing the WAM W, the 22,000,000 supply'
        ' ceiling, and the launch date.</desc>\n')


def build_flat(g):
    c = FLAT
    return (
        HEAD
        + '<!-- Flat, three inks, no gradient. This is the asset: it survives\n'
          '     being embroidered, foil-stamped, engraved, printed in one\n'
          '     colour, and rendered at 64px. Every legend is an outline, so\n'
          '     it needs no font. -->\n'
        + f'<circle cx="60" cy="60" r="58" fill="{c["rim"]}"/>'
        + f'<circle cx="60" cy="60" r="54" fill="none" stroke="{c["mill"]}"'
          f' stroke-width="8" stroke-dasharray="2.8 2.85"/>'
        + f'<circle cx="60" cy="60" r="50" fill="{c["field"]}"/>\n'
        + arc_glyphs(g, SUPPLY, 41.5, 8.6, True, 100, c['ink']) + '\n'
        + w_mark(c['ink']) + '\n'
        + arc_glyphs(g, LEGEND, 41.5, 6.6, False, 128, c['ink'])
        + '\n</svg>\n')


def build_struck(g):
    c = FLAT
    defs = (
        '<defs>\n'
        '  <radialGradient id="field" cx="34%" cy="28%" r="82%">\n'
        '    <stop offset="0%" stop-color="#F7E3A8"/>\n'
        f'    <stop offset="42%" stop-color="{c["field"]}"/>\n'
        '    <stop offset="88%" stop-color="#BE8A22"/>\n'
        '    <stop offset="100%" stop-color="#A0741A"/>\n'
        '  </radialGradient>\n'
        '  <linearGradient id="rim" x1="18%" y1="8%" x2="82%" y2="92%">\n'
        f'    <stop offset="0%" stop-color="{GOLD_HI}"/>\n'
        '    <stop offset="45%" stop-color="#C99A32"/>\n'
        '    <stop offset="100%" stop-color="#7A5310"/>\n'
        '  </linearGradient>\n'
        '  <linearGradient id="sheen" x1="10%" y1="0%" x2="60%" y2="100%">\n'
        '    <stop offset="0%" stop-color="#ffffff" stop-opacity="0.30"/>\n'
        '    <stop offset="38%" stop-color="#ffffff" stop-opacity="0.06"/>\n'
        '    <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>\n'
        '  </linearGradient>\n'
        '</defs>\n')

    def relief(draw, off):
        # Light copy up-left, dark copy down-right, then the element. This is
        # how a struck coin reads: the eye infers depth from where the light
        # falls. Filters would do it too, and render differently in every
        # engine -- librsvg ignores several outright.
        #
        # The offset scales with the element. A single value tuned for the W,
        # whose stroke is 11 units, doubles a 6.6-unit legend into an unreadable
        # ghost -- which is exactly what the first render produced.
        return (f'<g opacity="0.8" transform="translate({-off},{-off})">{draw(GOLD_HI)}</g>'
                f'<g opacity="0.85" transform="translate({off},{off})">{draw(GOLD_DEEP)}</g>'
                f'{draw(c["ink"])}')

    return (
        HEAD
        + '<!-- Struck. Screens only, 128px and up. The flat file is the asset;\n'
          '     this is the marketing image. Identical geometry, and only the\n'
          '     finish differs, which is what keeps them one coin. -->\n'
        + defs
        + '<circle cx="60" cy="60" r="58" fill="url(#rim)"/>'
        + reeding(58, 50.5, 72, '#E8C46A', '#7A5310', c['field'])
        + f'<circle cx="60" cy="60" r="50.5" fill="{c["mill"]}" opacity="0.55"/>'
        + '<circle cx="60" cy="60" r="49.5" fill="url(#field)"/>\n'
        + relief(lambda col: arc_glyphs(g, SUPPLY, 41.5, 8.6, True, 100, col), 0.34) + '\n'
        + relief(lambda col: w_mark(col), 1.05) + '\n'
        + relief(lambda col: arc_glyphs(g, LEGEND, 41.5, 6.6, False, 128, col), 0.26) + '\n'
        + '<circle cx="60" cy="60" r="49.5" fill="url(#sheen)"/>'
        + '\n</svg>\n')


def main():
    g = Glyphs(load_font())
    for name, svg in (('wam-coin-face.svg', build_flat(g)),
                      ('wam-coin-face-struck.svg', build_struck(g))):
        p = HERE / name
        p.write_text(svg, encoding='utf-8', newline='\n')
        print(f'  {name:<28} {len(svg):>7,} bytes')

    # The property that matters: nothing font-dependent survives into the file.
    for name in ('wam-coin-face.svg', 'wam-coin-face-struck.svg'):
        t = (HERE / name).read_text(encoding='utf-8')
        for forbidden in ('<text', 'font-family', 'textPath'):
            if forbidden in t:
                sys.exit(f'  FAIL {name} still contains {forbidden}')

        # A double hyphen inside an XML comment is a parse error, and the file
        # is rejected whole -- no partial render, no useful message beyond a
        # line number. Caught here rather than by a blank PNG later.
        for chunk in re.findall(r'<!--(.*?)-->', t, re.S):
            if '--' in chunk:
                sys.exit(f'  FAIL {name}: double hyphen inside an XML comment')

        # And it must actually parse.
        try:
            ET.fromstring(t)
        except ET.ParseError as e:
            sys.exit(f'  FAIL {name} does not parse: {e}')

    print('  ok    no <text>, no font-family, no textPath; both files parse')


if __name__ == '__main__':
    main()
