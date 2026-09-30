#!/usr/bin/env python3
"""Pixel gate for the real Floe app simulator frames.

The screenshots attached by ``OfficeRealEngineUITests`` and resolved through
the xcresult manifest (GUID export names are irrelevant — frames are matched
by attachment name) are real simulator frames of the genuine Floe app hosting
the native engine.

The independent host-only ``office_real_simulator/check_render.py`` inspects
the whole frame for the edit/idle/reopen frames, so a solid toolbar or sidebar
on an otherwise blank document can pass. This Floe gate is stricter and
self-contained (the host-only pipeline is intentionally not modified):

* the DOCUMENT region of EVERY frame (the central crop, excluding the
  notebookbar/toolbars and sidebars) must contain drawn, non-blank pixels —
  chrome alone can never satisfy any frame;
* the fixture preview frame must additionally show the pinned fixture marker
  colors INSIDE the document region, proving the real fixture slide rendered
  in the content area rather than marker-colored app chrome;
* every named frame must be present and readable.

It is a presence/blankness gate, not a reference pixel diff.
"""
import argparse
import json
from pathlib import Path

from PIL import Image

# Named frames in lifecycle order.
EXPECTED_FRAMES = ('01-preview', '02-edit', '03-idle-120s', '04-reopen',
                   '05-persisted')
MARKER_COLORS = {
    'blue-title': (29, 78, 216),
    'orange-bar': (234, 88, 12),
}
COLOR_TOLERANCE = 70
MIN_MARKER_PIXELS = 40
MIN_NONWHITE_FRACTION = 0.0015  # 0.15% of the analysed document region
# Real drawn content must differ from the local background, not merely be a
# non-white shade: a uniform grey/dark "document" (or a flat fill) has zero
# luma variation and no ink contrast even though every pixel is non-white.
MIN_LUMA_STDDEV = 8.0
MIN_INK_FRACTION = 0.0010  # pixels separated from the background luma
INK_DELTA = 35

# Document/central crop (left, top, right, bottom). The Floe header and the
# native notebookbar reach ~22% from the top and sidebars/slide rails occupy
# the side bands, so the crop starts below and inside that chrome; only the
# slide content area on iPad landscape is analysed.
DOCUMENT_REGION = (0.20, 0.22, 0.80, 0.90)


def color_distance(first, second):
    return sum(abs(a - b) for a, b in zip(first, second))


def is_nonwhite(pixel):
    r, g, b = pixel
    return (255 - r > 18 or 255 - g > 18 or 255 - b > 18)


def luma(pixel):
    r, g, b = pixel
    return 0.299 * r + 0.587 * g + 0.114 * b


def document_crop(image):
    """The slide/document region with app chrome excluded."""
    image = image.convert('RGB')
    width, height = image.size
    left, top, right, bottom = DOCUMENT_REGION
    return image.crop((int(width * left), int(height * top),
                       int(width * right), int(height * bottom)))


def analyse_frame(path):
    """Analyse ONLY the document region of one frame.

    A frame passes the blankness check only when its document region has
    non-white pixels, real luma VARIATION (a flat background of any shade
    fails, in light or dark mode), and enough pixels separated from the
    median background to count as drawn ink.
    """
    image = Image.open(path)
    document = document_crop(image)
    pixels = list(document.getdata())
    nonwhite = sum(1 for pixel in pixels if is_nonwhite(pixel))
    lumas = sorted(luma(pixel) for pixel in pixels)
    count = len(lumas)
    mean_luma = sum(lumas) / count
    variance = sum((value - mean_luma) ** 2 for value in lumas) / count
    stddev = variance ** 0.5
    background = lumas[count // 2]  # median luma = dominant background
    ink = sum(1 for value in lumas if abs(value - background) > INK_DELTA)
    fraction = nonwhite / count
    ink_fraction = ink / count
    markers = {}
    for name, target in MARKER_COLORS.items():
        markers[name] = sum(1 for pixel in pixels
                            if color_distance(pixel, target) <= COLOR_TOLERANCE)
    return {
        'documentSize': list(document.size),
        'documentNonwhitePixels': nonwhite,
        'documentNonwhiteFraction': round(fraction, 5),
        'documentLumaStdDev': round(stddev, 3),
        'backgroundLuma': round(background, 2),
        'documentInkFraction': round(ink_fraction, 5),
        'documentMarkerPixels': markers,
    }


def find_frame(curated_dir, token):
    matches = sorted(
        path for path in Path(curated_dir).glob(f'{token}.*')
        if path.suffix.lower() in ('.png', '.jpg', '.jpeg', '.data'))
    return matches[0] if matches else None


def content_proof_failures(token, facts):
    """Real drawn content must live INSIDE the document crop.

    A flat background of any shade (light or dark mode) has no variation and
    no ink separated from its background, so it fails even when it is fully
    non-white; chrome confined to the excluded top/side bands cannot help.
    """
    failures = []
    if facts['documentNonwhiteFraction'] < MIN_NONWHITE_FRACTION:
        failures.append(
            f'{token}: blank document region '
            f"({facts['documentNonwhiteFraction']} < {MIN_NONWHITE_FRACTION})")
    if facts['documentLumaStdDev'] < MIN_LUMA_STDDEV:
        failures.append(
            f"{token}: document region is a flat fill (luma stddev "
            f"{facts['documentLumaStdDev']} < {MIN_LUMA_STDDEV}); no drawn content "
            'in any appearance mode')
    if facts['documentInkFraction'] < MIN_INK_FRACTION:
        failures.append(
            f"{token}: no drawing contrast against the document background "
            f"(ink fraction {facts['documentInkFraction']} < {MIN_INK_FRACTION})")
    return failures


def check_floe_render(curated_dir):
    curated_dir = Path(curated_dir)
    frames = []
    failures = []
    for token in EXPECTED_FRAMES:
        path = find_frame(curated_dir, token)
        if path is None:
            failures.append(f'missing frame: {token}')
            frames.append({'frame': token, 'found': False})
            continue
        try:
            facts = analyse_frame(path)
        except (OSError, Image.UnidentifiedImageError) as error:
            failures.append(f'{token} unreadable: {error}')
            frames.append({'frame': token, 'path': str(path), 'found': True,
                           'error': str(error)})
            continue
        entry = {'frame': token, 'path': str(path), 'found': True, **facts}
        content_failures = content_proof_failures(token, facts)
        failures.extend(content_failures)
        if token == '01-preview':
            hit = {name: count for name, count in facts['documentMarkerPixels'].items()
                   if count >= MIN_MARKER_PIXELS}
            entry['documentMarkersDetected'] = sorted(hit)
            if not hit:
                failures.append(
                    f"{token}: fixture marker colors absent from the document region "
                    f"({facts['documentMarkerPixels']})")
        frames.append(entry)
    return {
        'curatedDir': str(curated_dir),
        'documentRegion': list(DOCUMENT_REGION),
        'expectedFrames': list(EXPECTED_FRAMES),
        'frames': frames,
        'failures': failures,
        'renderPassed': not failures,
        'checkKind': 'floe-app-document-region-blankness-and-markers',
        'hostKind': 'fullFloeAppSimulator',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('curated_dir',
                        help='Directory of named frames curated by resolve_attachments.py')
    parser.add_argument('--output', type=Path, default=None)
    args = parser.parse_args()
    result = check_floe_render(args.curated_dir)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if not result['renderPassed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
