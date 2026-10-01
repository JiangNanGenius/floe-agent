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
  chrome alone can never satisfy any frame (the one explicitly expected
  inserted blank page is asserted marker-free instead);
* the fixture preview frame must additionally show the pinned fixture marker
  colors INSIDE the document region, proving the real fixture slide rendered
  in the content area rather than marker-colored app chrome;
* the slideshow frames must prove page identity through the real deck order
  [fixture slide 1, inserted blank, fixture slide 2]: slide 1 needs the blue
  title AND orange bar, the intermediate must be marker-free, slide 2 needs
  the green oval, every presented frame needs the slideshow letterbox, the
  exit frame must NOT have it, and distinct pages must not be the same frame;
* every named frame must be present and readable from real attachments.

It is a presence/blankness gate, not a reference pixel diff.
"""
import argparse
import json
from pathlib import Path

from PIL import Image

# Named frames in lifecycle order. The slideshow frames are explicit content
# identity checks for the real presented deck; `11-slideshow-blank-page` is
# the inserted blank page observed between fixture slide 1 and fixture
# slide 2, and is asserted marker-FREE (it must never be counted as content).
EXPECTED_FRAMES = ('01-preview', '02-edit', '10-slideshow-page1',
                   '11-slideshow-blank-page', '12-slideshow-page2',
                   '13-slideshow-exit', '03-idle-120s', '04-reopen',
                   '05-persisted')
# The inserted blank intermediate is allowed to have an empty document region
# ONLY because it is explicitly asserted marker-free below; every other frame
# must satisfy the drawn-content proof.
BLANK_INTERMEDIATE_FRAMES = ('11-slideshow-blank-page',)
# Frames that must additionally show the pinned fixture marker colors inside
# the document region: the read-only preview. A slideshow whose virtual
# device never painted cannot satisfy the slideshow marker rules below.
MARKER_REQUIRED_FRAMES = ('01-preview',)
MARKER_COLORS = {
    'blue-title': (29, 78, 216),
    'orange-bar': (234, 88, 12),
    'green-oval': (16, 160, 64),
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
# The real slideshow letterboxes the slide (black bands above/below); the
# editor canvas does not. `PRESENTATION_MIN_BLACK` proves a slideshow frame
# really is fullscreen, `EXIT_MAX_BLACK` proves the exit frame no longer is,
# so editor chrome mounted behind a still-active canvas cannot fake an exit.
PRESENTATION_MIN_BLACK = 0.04
EXIT_MAX_BLACK = 0.02
# Cross-frame page identity: distinct pages must not be pixel-identical.
MIN_CROSS_FRAME_DIFF = 0.01
DIFF_PIXEL_DELTA = 90
BLACK_MAX_CHANNEL = 16

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


def full_frame_band_fractions(image, divisor=8):
    """Black/white shares of the WHOLE frame (downsampled).

    The slideshow letterbox lives outside the document crop, so the
    presentation/exited state is judged here instead of in the crop.
    """
    small = image.convert('RGB').resize(
        (max(1, image.width // divisor), max(1, image.height // divisor)))
    pixels = list(small.getdata())
    count = len(pixels)
    black = sum(1 for r, g, b in pixels
                if r <= BLACK_MAX_CHANNEL and g <= BLACK_MAX_CHANNEL
                and b <= BLACK_MAX_CHANNEL)
    white = sum(1 for r, g, b in pixels if r >= 245 and g >= 245 and b >= 245)
    return round(black / count, 5), round(white / count, 5)


def frame_diff_ratio(first_path, second_path, divisor=8):
    """Fraction of downsampled pixels that differ strongly between frames."""
    with Image.open(first_path) as first_image:
        first = first_image.convert('RGB').resize(
            (max(1, first_image.width // divisor),
             max(1, first_image.height // divisor)))
    with Image.open(second_path) as second_image:
        second = second_image.convert('RGB').resize(first.size)
    first_pixels = list(first.getdata())
    second_pixels = list(second.getdata())
    count = len(first_pixels)
    changed = sum(
        1 for a, b in zip(first_pixels, second_pixels)
        if color_distance(a, b) > DIFF_PIXEL_DELTA)
    return round(changed / count, 5)


def analyse_frame(path):
    """Analyse the document region plus the full-frame letterbox bands.

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
    black_fraction, white_fraction = full_frame_band_fractions(image)
    return {
        'documentSize': list(document.size),
        'documentNonwhitePixels': nonwhite,
        'documentNonwhiteFraction': round(fraction, 5),
        'documentLumaStdDev': round(stddev, 3),
        'backgroundLuma': round(background, 2),
        'documentInkFraction': round(ink_fraction, 5),
        'documentMarkerPixels': markers,
        'fullBlackFraction': black_fraction,
        'fullWhiteFraction': white_fraction,
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


def slideshow_identity_failures(by_token):
    """Explicit page/exit identity rules for the presented deck.

    The deck order after the real Insert Page action is
    [fixture slide 1, inserted blank, fixture slide 2]:
    * page 1 must present the blue title AND orange bar inside the document
      region and must NOT show the green oval (wrong page / chrome rejected);
    * the intermediate page must be marker-free and differ from both content
      pages (a marker-bearing blank or the same frame as page 1 fails);
    * page 2 must present the green oval (still without the orange bar) and
      must differ from page 1 (a repeat/wrong page fails);
    * the exit frame must NOT carry the slideshow letterbox and must differ
      from the last presented page (chrome mounted behind a still-active
      canvas cannot fake the exit).
    """
    failures = []
    page1 = by_token.get('10-slideshow-page1')
    blank = by_token.get('11-slideshow-blank-page')
    page2 = by_token.get('12-slideshow-page2')
    exit_frame = by_token.get('13-slideshow-exit')

    def marker(facts, name):
        return (facts.get('documentMarkerPixels') or {}).get(name, 0)

    def require_presenting(token, facts):
        if facts['fullBlackFraction'] < PRESENTATION_MIN_BLACK:
            failures.append(
                f'{token}: slideshow letterbox missing '
                f"({facts['fullBlackFraction']} < {PRESENTATION_MIN_BLACK}); "
                'editor chrome is not a presented page')

    if page1 is not None:
        require_presenting('10-slideshow-page1', page1)
        if marker(page1, 'blue-title') < MIN_MARKER_PIXELS \
                or marker(page1, 'orange-bar') < MIN_MARKER_PIXELS:
            failures.append(
                '10-slideshow-page1: fixture slide 1 markers incomplete in the '
                f"document region ({page1['documentMarkerPixels']})")
        if marker(page1, 'green-oval') >= MIN_MARKER_PIXELS:
            failures.append(
                '10-slideshow-page1: green fixture marker shown on slide 1 '
                '(wrong page)')
    if blank is not None:
        require_presenting('11-slideshow-blank-page', blank)
        if any(marker(blank, name) >= MIN_MARKER_PIXELS
               for name in MARKER_COLORS):
            failures.append(
                '11-slideshow-blank-page: inserted blank page carries fixture '
                f"markers ({blank['documentMarkerPixels']})")
    if page2 is not None:
        require_presenting('12-slideshow-page2', page2)
        if marker(page2, 'green-oval') < MIN_MARKER_PIXELS:
            failures.append(
                '12-slideshow-page2: fixture slide 2 green oval absent from the '
                f"document region ({page2['documentMarkerPixels']})")
        if marker(page2, 'orange-bar') >= MIN_MARKER_PIXELS:
            failures.append(
                '12-slideshow-page2: slide 1 orange bar still shown on page 2 '
                '(wrong page)')
    if exit_frame is not None:
        if exit_frame['fullBlackFraction'] >= EXIT_MAX_BLACK:
            failures.append(
                '13-slideshow-exit: slideshow letterbox still present '
                f"({exit_frame['fullBlackFraction']} >= {EXIT_MAX_BLACK}); "
                'the presentation did not exit')

    def cross_frame(token, first_token, second_token):
        first = by_token.get(first_token)
        second = by_token.get(second_token)
        if first is None or second is None:
            return
        ratio = frame_diff_ratio(first['path'], second['path'])
        if ratio < MIN_CROSS_FRAME_DIFF:
            failures.append(
                f'{token}: {first_token} and {second_token} are the same frame '
                f'(diff {ratio} < {MIN_CROSS_FRAME_DIFF})')

    cross_frame('10-slideshow-page1 vs 12-slideshow-page2',
                '10-slideshow-page1', '12-slideshow-page2')
    cross_frame('11-slideshow-blank-page vs 10-slideshow-page1',
                '11-slideshow-blank-page', '10-slideshow-page1')
    cross_frame('11-slideshow-blank-page vs 12-slideshow-page2',
                '11-slideshow-blank-page', '12-slideshow-page2')
    cross_frame('13-slideshow-exit vs 12-slideshow-page2',
                '13-slideshow-exit', '12-slideshow-page2')
    return failures


def check_floe_render(curated_dir):
    curated_dir = Path(curated_dir)
    frames = []
    failures = []
    by_token = {}
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
        if token not in BLANK_INTERMEDIATE_FRAMES:
            content_failures = content_proof_failures(token, facts)
            failures.extend(content_failures)
        if token in MARKER_REQUIRED_FRAMES:
            hit = {name: count for name, count in facts['documentMarkerPixels'].items()
                   if count >= MIN_MARKER_PIXELS}
            entry['documentMarkersDetected'] = sorted(hit)
            if not hit:
                failures.append(
                    f"{token}: fixture marker colors absent from the document region "
                    f"({facts['documentMarkerPixels']})")
        frames.append(entry)
        by_token[token] = entry
    failures.extend(slideshow_identity_failures(by_token))
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
