import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    'summarize_asc_crash', Path(__file__).parents[1] / 'summarize_asc_crash.py')
summarize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summarize)

# Canaries that mimic tester identity, feedback text and on-device paths. None
# of them may reach the sanitized diagnostic summary.
PII_CANARIES = (
    'jane.doe@example.com', 'Jane Doe', 'AAAA-BBBB-CCCC', '/private/var',
    '/Users/', '6C2B0A5F', 'RawDeviceSecret', 'd5e4339a89c2cb90eadf425d1',
)

MODERN_LOG = '\n'.join([
    json.dumps({'app_name': 'Floe Agent', 'timestamp': '2026-10-14 05:53:47.00 +0800'}),
    json.dumps({
        'exception': {'type': 'EXC_CRASH', 'signal': 'SIGABRT'},
        'termination': {'namespace': 'SIGNAL', 'code': 6},
        'faultingThread': 0,
        'threads': [{'triggered': True, 'frames': [
            {'imageIndex': 1, 'imageOffset': 4056, 'symbol': '__pthread_kill + 8'},
            {'imageIndex': 0, 'imageOffset': 145824,
             'symbol': '-[FloeView runAt:/Users/jane/secret]'},
        ]}],
        'usedImages': [
            {'name': 'Floe Agent', 'uuid': 'dc35a10d5e4339a89c2cb90eadf425d1',
             'path': '/private/var/containers/Bundle/Application/AAAA-BBBB-CCCC/'
                     'Floe Agent.app/Floe Agent'},
            {'name': 'libsystem_kernel.dylib', 'uuid': 'abcdef0123456789abcdef0123456789',
             'path': '/usr/lib/system/libsystem_kernel.dylib'},
        ],
    }),
])

LEGACY_LOG = '\n'.join([
    'Incident Identifier: 6C2B0A5F-0000-0000-0000-000000000000',
    'CrashReporter Key:   RawDeviceSecretDeadbeef',
    'Beta Tester: jane.doe@example.com (Jane Doe)',
    'Hardware Model:      iPhone19,2',
    'Process:             Floe Agent [4242]',
    'Path:                /private/var/containers/Bundle/Application/AAAA-BBBB-CCCC/'
    'Floe Agent.app/Floe Agent',
    'Identifier:          org.floeagent.ios',
    'Version:             1.7.30 (271)',
    'Code Type:           ARM-64',
    'OS Version:          iPhone OS 27.0.1',
    'Exception Type:  EXC_CRASH (SIGABRT)',
    'Exception Codes: 0x0000000000000000, 0x0000000000000000',
    'Termination Reason: Namespace SIGNAL, Code 6 Abort trap: 6',
    'Triggered by Thread:  0',
    '',
    'Thread 0 Crashed:',
    '0   libsystem_kernel.dylib          0x000000023c912fd8 0x23c912000 + 4056 '
    '__pthread_kill + 8',
    '1   ???                             0x00000001158f32a4 0x0 + 4656337060',
    '2   Floe Agent                      0x0000000104f8f9a0 0x104f6c000 + 145824 '
    '-[FloeView renderAt:/Users/jane/secret]',
    '3   libsystem_c.dylib               0x0000000186ff57f0 0x186ff5000 + 2032',
    '',
    'Thread 1:',
    '0   libsystem_kernel.dylib          0x000000023c912fd8 0x23c912000 + 4056',
    '',
    'Binary Images:',
    '       0x104f6c000 -        0x1051f3fff Floe Agent arm64  '
    '<dc35a10d5e4339a89c2cb90eadf425d1> /private/var/containers/Bundle/Application/'
    'AAAA-BBBB-CCCC/Floe Agent.app/Floe Agent',
    '       0x1158e0000 -        0x1159e7fff RoyalVNCKit.framework arm64  '
    '<feedfacefeedfacefeedfacefeedface> /private/var/containers/Bundle/Application/'
    'AAAA-BBBB-CCCC/Floe Agent.app/Frameworks/RoyalVNCKit.framework/RoyalVNCKit',
    '       0x186ff5000 -        0x18c4c8fff libsystem_c.dylib arm64e '
    '<00112233445566778899aabbccddeeff> /usr/lib/system/libsystem_c.dylib',
    '       0x23c912000 -        0x23c91bfff libsystem_kernel.dylib arm64e '
    '<abcdef0123456789abcdef0123456789> /usr/lib/system/libsystem_kernel.dylib',
    '',
    'EOF',
])


def render(log):
    stream = io.StringIO()
    with contextlib.redirect_stdout(stream):
        summarize.summarize(log)
    return stream.getvalue()


class SummarizeAscCrashTests(unittest.TestCase):
    def test_modern_ips_emits_uuid_and_load_relative_offset(self):
        output = render(MODERN_LOG)
        self.assertIn('exception=EXC_CRASH', output)
        self.assertIn('signal=SIGABRT', output)
        self.assertIn('terminationNamespace=SIGNAL', output)
        self.assertIn('terminationCode=6', output)
        self.assertIn(
            'frame image=System offset=4056 '
            'imageUUID=ABCDEF01-2345-6789-ABCD-EF0123456789 symbol=__pthread_kill',
            output)
        self.assertIn(
            'frame image=Floe offset=145824 '
            'imageUUID=DC35A10D-5E43-39A8-9C2C-B90EADF425D1 symbol=omitted',
            output)

    def test_legacy_text_emits_symbolication_fields(self):
        output = render(LEGACY_LOG)
        self.assertIn('Exception Type=EXC_CRASH (SIGABRT)', output)
        self.assertIn('Exception Codes=0x0000000000000000, 0x0000000000000000', output)
        self.assertIn('Termination Reason=Namespace SIGNAL, Code 6 Abort trap: 6', output)
        self.assertIn(
            'frame image=Floe offset=145824 '
            'imageUUID=DC35A10D-5E43-39A8-9C2C-B90EADF425D1 symbol=omitted',
            output)
        self.assertIn(
            'frame image=Other offset=78500 '
            'imageUUID=FEEDFACE-FEED-FACE-FEED-FACEFEEDFACE symbol=omitted',
            output)
        self.assertIn(
            'frame image=System offset=4056 '
            'imageUUID=ABCDEF01-2345-6789-ABCD-EF0123456789 symbol=__pthread_kill',
            output)
        self.assertIn(
            'frame image=System offset=2032 '
            'imageUUID=00112233-4455-6677-8899-AABBCCDDEEFF symbol=omitted',
            output)
        # Only the crashed thread is summarized, and mapped frames keep no
        # absolute runtime address.
        self.assertEqual(output.count('frame image='), 4)
        self.assertNotIn('address=0x', output)
        self.assertNotIn('0x104f8f9a0', output)
        self.assertNotIn('0x104f6c000', output)

    def test_legacy_without_binary_images_keeps_safe_fallback(self):
        output = render(LEGACY_LOG.split('Binary Images:')[0])
        self.assertIn('frame image=Floe address=0x104f8f9a0 symbol=omitted', output)

    def test_binary_images_hides_paths_and_normalizes_uuids(self):
        images = summarize.binary_images(LEGACY_LOG)
        self.assertEqual(len(images), 4)
        self.assertEqual({item['image'] for item in images}, {'Floe', 'Other', 'System'})
        self.assertEqual(images[0]['uuid'], 'DC35A10D-5E43-39A8-9C2C-B90EADF425D1')

    def test_binary_images_accepts_uuid_variants(self):
        log = '\n'.join([
            'Binary Images:',
            '       0x100000000 -        0x1000ffff Floe Agent arm64  '
            '(dc35a10d5e4339a89c2cb90eadf425d1) /a/Floe.app/Floe Agent',
            '       0x200000000 -        0x2000ffff Other.framework arm64e  '
            'dc35a10d5e4339a89c2cb90eadf425d1 /b/Other.framework/Other',
            '       0x300000000 -        0x3000ffff NoUuid.dylib arm64e  /c/NoUuid.dylib',
            '',
        ])
        images = summarize.binary_images(log)
        self.assertEqual(
            [item['uuid'] for item in images],
            ['DC35A10D-5E43-39A8-9C2C-B90EADF425D1'] * 2 + ['unknown'])

    def test_raw_tester_text_never_reaches_output(self):
        for fixture in (MODERN_LOG, LEGACY_LOG):
            output = render(fixture)
            for canary in PII_CANARIES:
                self.assertNotIn(canary, output)

    def test_legacy_hex_base_offset_keeps_symbol(self):
        log = '\n'.join([
            'Thread 0 Crashed:',
            '0   libsystem_kernel.dylib   0x23c912fd8 0x23c912000 + 0xfd8 '
            '__pthread_kill + 8',
            '',
            'Binary Images:',
            '       0x23c912000 -        0x23c91bfff libsystem_kernel.dylib arm64e '
            '<abcdef0123456789abcdef0123456789> /usr/lib/system/libsystem_kernel.dylib',
            '',
        ])
        output = render(log)
        self.assertIn(
            'frame image=System offset=4056 '
            'imageUUID=ABCDEF01-2345-6789-ABCD-EF0123456789 symbol=__pthread_kill',
            output)

    def test_binary_images_tolerates_unindented_and_blank_rows(self):
        log = '\n'.join([
            'Thread 0 Crashed:',
            '0   libsystem_kernel.dylib   0x23c912fd8 0x23c912000 + 0xfd8 '
            '__pthread_kill + 8',
            '',
            'Binary Images:',
            '',
            '0x23c912000 - 0x23c91bfff libsystem_kernel.dylib arm64e '
            '<abcdef0123456789abcdef0123456789> /usr/lib/system/libsystem_kernel.dylib',
            '',
            '0x104f6c000 - 0x1051f3fff Floe Agent arm64 '
            '<dc35a10d5e4339a89c2cb90eadf425d1> /a/Floe Agent.app/Floe Agent',
            'EOF',
            '0x300000000 - 0x3000ffff Late.dylib arm64e '
            '<00112233445566778899aabbccddeeff> /usr/lib/Late.dylib',
        ])
        images = summarize.binary_images(log)
        self.assertEqual(len(images), 2)
        output = render(log)
        self.assertIn(
            'frame image=System offset=4056 '
            'imageUUID=ABCDEF01-2345-6789-ABCD-EF0123456789 symbol=__pthread_kill',
            output)

    def test_unbounded_reason_and_symbols_are_omitted(self):
        log = '\n'.join([
            'Exception Type: EXC_CRASH (SIGABRT)',
            'Termination Reason: jane.doe@example.com',
            '',
            'Thread 0 Crashed:',
            '0   Floe Agent   0x0000000104f8f9a0 /Users/jane/secret.m:12',
            '',
            'Binary Images:',
            '       0x104f6c000 -        0x1051f3fff Floe Agent arm64  '
            '<dc35a10d5e4339a89c2cb90eadf425d1> /private/x/Floe Agent.app/Floe Agent',
            '',
        ])
        output = render(log)
        self.assertNotIn('jane.doe@example.com', output)
        self.assertNotIn('Termination Reason=', output)
        self.assertIn(
            'frame image=Floe offset=145824 '
            'imageUUID=DC35A10D-5E43-39A8-9C2C-B90EADF425D1 symbol=omitted',
            output)

    def test_symbol_name_rejects_paths_and_keeps_objc_identifiers(self):
        self.assertEqual(summarize.symbol_name('/Users/jane/secret.m:12'), 'omitted')
        self.assertEqual(summarize.symbol_name('__pthread_kill + 8'), '__pthread_kill')
        self.assertEqual(summarize.symbol_name('-[FloeView render]'), '-[FloeView render]')

    def test_cli_payload_path_and_missing_log(self):
        script = Path(__file__).parents[1] / 'summarize_asc_crash.py'
        with tempfile.TemporaryDirectory() as tmp:
            payload = Path(tmp) / 'crash-log.json'
            payload.write_text(json.dumps(
                {'data': {'attributes': {'logText': LEGACY_LOG}}}))
            result = subprocess.run(
                [sys.executable, str(script), str(payload)],
                capture_output=True, text=True, check=True)
            self.assertIn('imageUUID=DC35A10D-5E43-39A8-9C2C-B90EADF425D1', result.stdout)
            empty = Path(tmp) / 'empty.json'
            empty.write_text(json.dumps({'data': {'attributes': {}}}))
            result = subprocess.run(
                [sys.executable, str(script), str(empty)],
                capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), 'crash-log-unavailable')


if __name__ == '__main__':
    unittest.main()
