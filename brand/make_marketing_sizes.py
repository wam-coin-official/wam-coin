#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""Derive the marketing coin's sizes from the master image.

    python3 brand/make_marketing_sizes.py

The master (brand/wam-coin-marketing.jpg) is a 3D render, not vector, so
every size has to be resampled from it rather than drawn. Downscaling is
lossless in the sense that matters -- detail is discarded, never invented --
but upscaling is not, so the master must always be the largest version that
exists. Replace it with a larger render and re-run; never enlarge an output.

Outputs are PNG. The master arrived as JPEG, whose blocking artefacts sit
exactly where this image is most fragile: the fine gold dots of the map
against a flat black field. Resampling a JPEG repeatedly compounds that, so
the derived files leave the lossy format behind at the first step.
"""
import pathlib
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit('Pillow is required:  python3 -m pip install --user Pillow')

HERE = pathlib.Path(__file__).resolve().parent
PNG = HERE / 'png'

MASTERS = ['wam-coin-marketing.jpg', 'wam-coin-marketing.png']
SIZES = [1024, 512, 256, 200, 128]


def main():
    src = next((HERE / m for m in MASTERS if (HERE / m).exists()), None)
    if src is None:
        sys.exit(f'no master found; expected one of {MASTERS} in {HERE}')

    PNG.mkdir(exist_ok=True)
    with Image.open(src) as im:
        im = im.convert('RGB')
        w, h = im.size
        print(f'  master  {src.name}  {w} x {h}')
        if w != h:
            print(f'  warn    not square ({w}x{h}); outputs will be letterboxed')
        if w < max(SIZES):
            print(f'  warn    master is smaller than the largest output '
                  f'({w} < {max(SIZES)}); that size is skipped rather than '
                  f'enlarged')

        for s in SIZES:
            if s > w:
                continue
            out = PNG / f'wam-coin-marketing-{s}.png'
            im.resize((s, s), Image.LANCZOS).save(out, 'PNG', optimize=True)
            print(f'  ok      {out.name:<34} {out.stat().st_size / 1024:>6.0f} KB')


if __name__ == '__main__':
    main()
