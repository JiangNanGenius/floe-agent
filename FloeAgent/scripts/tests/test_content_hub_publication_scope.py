"""Exercise the real content-only publication shell without network writes."""
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = yaml.safe_load((ROOT / '.github/workflows/skill-hub.yml').read_text())
STEPS = WORKFLOW['jobs']['publish']['steps']


def step(name):
    return next(s for s in STEPS if s.get('name') == name)['run']


class ContentHubPublicationScopeTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / 'Local/Scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='content-publication-', dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_shell(self, script, **extra):
        env = dict(os.environ, GITHUB_OUTPUT=str(self.root / 'output'), **extra)
        return subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script],
                              env=env, cwd=self.root, capture_output=True, text=True)

    def test_tag_is_rejected_before_checkout_or_signing(self):
        script = step('Require a branch for signed feed publication')
        self.assertNotEqual(self.run_shell(script, GITHUB_REF_TYPE='tag').returncode, 0)
        self.assertEqual(self.run_shell(script, GITHUB_REF_TYPE='branch').returncode, 0)
        names = [s.get('name', s.get('uses')) for s in STEPS]
        self.assertLess(names.index('Require a branch for signed feed publication'),
                        names.index('actions/checkout@v5'))

    def test_channel_resolution_keeps_existing_modes_and_rejects_ambiguous_partial_modes(self):
        for full, android, content in itertools.product([False, True], repeat=3):
            if not (full or android or content):
                continue  # The job condition does not admit this request.
            script = step('Resolve publication channels')
            for key, value in [('publish', full), ('publish_android', android), ('publish_content', content)]:
                script = script.replace('${{ inputs.' + key + ' }}', str(value).lower())
            output = self.root / 'output'
            output.unlink(missing_ok=True)
            result = self.run_shell(script)
            if not full and android and content:
                self.assertNotEqual(result.returncode, 0)
                continue
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = 'both' if full else 'android' if android else 'content'
            self.assertEqual(output.read_text().strip(), 'channels=' + expected)

    def mock_git(self):
        binary = self.root / 'bin'
        binary.mkdir()
        git = binary / 'git'
        git.write_text('''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]; root=Path(os.environ['MOCK_ROOT'])
with (root/'commands').open('a') as f: f.write(json.dumps(args)+'\\n')
if args[:1]==['add']:
 with (root/'staged').open('a') as f: f.write('\\n'.join(p+'/fixture.zip' if p.endswith('/packages') else p for p in args[1:])+'\\n')
elif args==['diff','--cached','--name-only']:
 print((root/'staged').read_text(),end='');print(os.environ.get('INJECT_STAGED',''))
elif args==['diff','--cached','--quiet']: sys.exit(1)
elif args[:1]==['rev-parse']: print('a'*40)
''')
        git.chmod(0o700)
        return str(binary) + os.pathsep + os.environ['PATH']

    def execute_commit(self, injected=''):
        result = self.run_shell(step('Commit signed artifacts'), PATH=self.mock_git(),
            MOCK_ROOT=str(self.root), INJECT_STAGED=injected, PUBLISH_LEGACY='false',
            PUBLISH_ANDROID='false', PUBLISH_CONTENT='true', TARGET_BRANCH='codex/test-content')
        commands = [json.loads(line) for line in (self.root / 'commands').read_text().splitlines()]
        return result, commands

    def test_content_only_stages_no_skills_seeds_or_android_and_pushes_the_branch(self):
        result, commands = self.execute_commit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c for c in commands if c[0] == 'add'], [
            ['add', 'content-hub/index.json', 'content-hub/index.sig', 'content-hub/packages']])
        self.assertEqual([c for c in commands if c[0] == 'push'],
                         [['push', 'origin', 'HEAD:codex/test-content']])

    def test_unrelated_staged_file_stops_before_commit_and_push(self):
        result, commands = self.execute_commit('skill-hub/catalog.json')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] in ('commit', 'push') for c in commands))


if __name__ == '__main__':
    unittest.main()
