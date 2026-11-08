#!/usr/bin/env python3
"""Read only: capture the stable latest release and its exact Git tag binding."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess

_spec = importlib.util.spec_from_file_location(
    'publication_gate', Path(__file__).with_name('verify_github_release_publication.py'))
publication = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(publication)


def capture(repo, expected_tag, api_get):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) \
            or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', expected_tag):
        raise ValueError('Expected an explicit repository and preserved stable tag')
    release = api_get(f'repos/{repo}/releases/latest')
    if release.get('tag_name') != expected_tag:
        raise ValueError('Current latest is not the explicitly preserved tag')
    ref = api_get(f'repos/{repo}/git/ref/tags/{expected_tag}')
    obj = ref.get('object', {})
    tag = api_get(f'repos/{repo}/git/tags/{obj["sha"]}') if obj.get('type') == 'tag' else {}
    snapshot = {'schemaVersion': 1, 'release': release, 'tagRef': ref, 'tagObject': tag}
    publication.latest_snapshot_identity(snapshot)
    return snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--expected-tag', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    api = lambda path: json.loads(subprocess.check_output(['gh', 'api', path], text=True))
    snapshot = capture(args.repo, args.expected_tag, api)
    args.output.write_text(json.dumps(snapshot, indent=2) + '\n')
    print('Captured immutable latest pointer: ' + args.expected_tag)


if __name__ == '__main__':
    main()
