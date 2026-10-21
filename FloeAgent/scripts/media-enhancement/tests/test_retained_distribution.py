"""Prepared distribution contract tests; run only during the shared qualification."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

class RetainedDistributionTests(unittest.TestCase):
    def test_member_paths_refuse_traversal_and_absolute_names(self):
        staging = module('stage_retained_models')
        for path in ('../weight.bin', '/weight.bin', 'x//weight.bin', 'x/./weight.bin', 'x\\weight.bin'):
            with self.assertRaises(ValueError):
                staging.safe_member(path)
        self.assertEqual(str(staging.safe_member('model.mlmodelc/weights/weight.bin')), 'model.mlmodelc/weights/weight.bin')

    def test_promotion_requires_qualified_exact_manifest_before_network(self):
        promotion = module('promote_retained_models')
        candidate = {'models': [{'id': 'floe/model-rife-v4', 'manifestSHA256': 'a' * 64}]}
        staged = {'models': [{'id': 'floe/model-rife-v4', 'files': [], 'status': 'pending-qualification'}]}
        for qualification in ({}, {'models': {'floe/model-rife-v4': {'manifestSHA256': 'b' * 64, 'hostPassed': True, 'devicePassed': True}}}):
            with self.assertRaises(ValueError):
                promotion.promote(candidate, qualification, staged, 'https://github.com/owner/repo/releases/download/media-models-v1')
        self.assertEqual(staged['models'][0]['status'], 'pending-qualification')
        self.assertEqual(staged['models'][0]['files'], [])

    def test_moving_or_credentialed_release_urls_are_refused(self):
        promotion = module('promote_retained_models')
        for url in ('https://github.com/owner/repo/releases/latest/download',
                    'https://github.com/owner/repo/releases/download/main',
                    'https://user:secret@github.com/owner/repo/releases/download/v1',
                    'http://github.com/owner/repo/releases/download/v1'):
            with self.assertRaises(ValueError):
                promotion.promote({'models': []}, {}, {'models': []}, url)

if __name__ == '__main__':
    unittest.main()
