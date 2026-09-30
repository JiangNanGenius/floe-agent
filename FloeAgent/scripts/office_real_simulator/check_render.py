#!/usr/bin/env python3
"""Pixel-analyse the simulator frames to prove a real rendered slide.

The XCTest attachments exported from the xcresult are real simulator frames.
A web view existing does not prove a frame, so this gate analyses pixels with
Pillow (installed in the runner venv):

* 01-preview: the fixture preview must contain the actual marker colors -
  blue title RGB(29,78,216) and/or orange bar RGB(234,88,12) - and non-blank
  content, so an all-white canvas cannot pass;
* 02-edit / 03-idle-120s / 04-reopen: the central slide region (middle 60%
  crop) must contain non-blank pixels, proving drawn content rather than only
  toolbar chrome.

It is a presence/blankness check, not a reference pixel-diff; labelled
host-only.
"""
import argparse
import json
from pathlib import Path

from PIL import Image

EXPECTED_FRAMES = ('01-preview', '02-edit', '03-idle-120s', '04-reopen')
MARKER_COLORS = {
    'blue-title': (29, 78, 216),
    'orange-bar': (234, 88, 12),
}
COLOR_TOLERANCE = 70
MIN_MARKER_PIXELS = 40
MIN_NONWHITE_FRACTION = 0.0015  # 0.15% of the analysed region


def color_distance(first, second):
    return sum(abs(a - b) for a, b in zip(first, second))


def frame_pixels(image, central_only=False):
    image = image.convert('RGB')
    if central_only:
        width, height = image.size
        box = (int(width * 0.2), int(height * 0.2),
               int(width * 0.8), int(height * 0.8))
        image = image.crop(box)
    return list(image.getdata()), image.size


def is_nonwhite(pixel):
    r, g, b = pixel
    return (255 - r > 18 or 255 - g > 18 or 255 - b > 18)


def analyse_frame(path, require_markers):
    image = Image.open(path)
    pixels, size = frame_pixels(image, central_only=require_markers)
    nonwhite = sum(1 for pixel in pixels if is_nonwhite(pixel))
    fraction = nonwhite / len(pixels)
    markers = {}
    if require_markers:
        # Markers are small; scan the full frame for the exact colors.
        all_pixels, _ = frame_pixels(image, central_only=False)
        for name, target in MARKER_COLORS.items():
            count = sum(1 for pixel in all_pixels
                        if color_distance(pixel, target) <= COLOR_TOLERANCE)
            markers[name] = count
    return {
        'size': [size[0], size[1]],
        'nonwhitePixels': nonwhite,
        'nonwhiteFraction': round(fraction, 5),
        'markerPixels': markers,
    }


def find_frame(screenshot_dir, token):
    matches = sorted(Path(screenshot_dir).glob(f'*{token}*.png'))
    return matches[0] if matches else None


def check_render(screenshot_dir):
    screenshot_dir = Path(screenshot_dir)
    frames = []
    failures = []
    for token in EXPECTED_FRAMES:
        path = find_frame(screenshot_dir, token)
        if path is None:
            failures.append(f'missing frame: {token}')
            frames.append({'frame': token, 'found': False})
            continue
        require_markers = token == '01-preview'
        try:
            facts = analyse_frame(path, require_markers)
        except (OSError, Image.UnidentifiedImageError) as error:
            failures.append(f'{token} unreadable: {error}')
            frames.append({'frame': token, 'path': str(path), 'found': True,
                           'error': str(error)})
            continue
        entry = {'frame': token, 'path': str(path), 'found': True, **facts}
        if facts['nonwhiteFraction'] < MIN_NONWHITE_FRACTION:
            failures.append(
                f'{token}: blank central region '
                f"({facts['nonwhiteFraction']} < {MIN_NONWHITE_FRACTION})")
        if require_markers:
            hit = {name: count for name, count in facts['markerPixels'].items()
                   if count >= MIN_MARKER_PIXELS}
            entry['markersDetected'] = sorted(hit)
            if not hit:
                failures.append(
                    f"{token}: fixture marker colors absent "
                    f"({facts['markerPixels']})")
        frames.append(entry)
    result = {
        'screenshotDir': str(screenshot_dir),
        'expectedFrames': list(EXPECTED_FRAMES),
        'frames': frames,
        'failures': failures,
        'renderPassed': not failures,
        'checkKind': 'screenshot-blankness-and-marker-presence',
        'hostKind': 'upstream-mobile-host-only',
    }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('screenshot_dir',
                        help='Directory of PNGs exported from the xcresult')
    parser.add_argument('--output', default=None)
    args = parser.parse_args()
    result = check_render(args.screenshot_dir)
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if not result['renderPassed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
