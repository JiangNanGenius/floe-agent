import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).parents[1] / 'prepare_testflight.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class TestFlightPreparationTests(unittest.TestCase):
    def test_wrong_candidate_never_writes(self):
        calls = []
        def api(method, path, body=None):
            calls.append(method)
            return {'data': {'attributes': {'version': '148', 'processingState': 'VALID'},
                'relationships': {'app': {'data': {'id': 'app'}}, 'preReleaseVersion': {'data': {'id': 'release'}}}}}
        with self.assertRaises(ValueError):
            prepare.prepare('build', 'org.floe', '1.7.0', '149', {'en-US': 'Test'}, api)
        self.assertEqual(calls, ['GET'])

    def test_preparation_readback_and_retry_are_idempotent(self):
        writes, locales, groups = [], [], []
        group = {'type': 'betaGroups', 'id': 'qa', 'attributes': {'name': 'Floe QA', 'isInternalGroup': True}}
        def api(method, path, body=None):
            if method != 'GET':
                writes.append((method, path))
                if path == '/v1/betaBuildLocalizations':
                    item = body['data']; item['id'] = 'locale-' + item['attributes']['locale']; locales.append(item)
                elif path == '/v1/betaGroups/qa/relationships/builds': groups.append(group)
                else: self.fail('Unexpected write')
                return {}
            if path == '/v1/builds/build?include=betaGroups':
                return {'data': {'relationships': {'betaGroups': {'data': [{'type': 'betaGroups', 'id': g['id']} for g in groups]}}}, 'included': groups}
            if path.startswith('/v1/builds/build?'):
                return {'data': {'attributes': {'version': '149', 'processingState': 'VALID'},
                    'relationships': {'app': {'data': {'id': 'app'}}, 'preReleaseVersion': {'data': {'id': 'release'}}}},
                    'included': [{'type': 'apps', 'id': 'app', 'attributes': {'bundleId': 'org.floe'}},
                                 {'type': 'preReleaseVersions', 'id': 'release', 'attributes': {'version': '1.7.0'}}]}
            if path.startswith('/v1/betaGroups?'): return {'data': [group]}
            if path.startswith('/v1/betaBuildLocalizations?'): return {'data': locales}
            self.fail('Unexpected read')
        notes = {'en-US': 'Check maps', 'zh-Hans': '检查导图'}
        for _ in range(2):
            result = prepare.prepare('build', 'org.floe', '1.7.0', '149', notes, api)
            self.assertEqual(result['processing'], 'VALID')
        self.assertEqual(len(writes), 3)

    def test_incomplete_group_include_is_not_treated_as_absent(self):
        def api(method, path, body=None):
            self.assertEqual((method, path), ('GET', '/v1/builds/build?include=betaGroups'))
            return {'data': {'relationships': {'betaGroups': {'data': [{'id': 'qa'}]}}}, 'included': []}
        with self.assertRaisesRegex(RuntimeError, 'Incomplete'):
            prepare.build_groups('build', api)

    def test_pagination_never_sends_auth_to_another_host(self):
        with self.assertRaises(ValueError):
            prepare.rows('/v1/builds', lambda *args: {'data': [], 'links': {'next': 'https://unrelated.example/v1/builds'}})


if __name__ == '__main__': unittest.main()
