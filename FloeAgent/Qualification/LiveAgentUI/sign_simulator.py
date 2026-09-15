"""Ad-hoc sign only a disposable simulator copy so normal Keychain APIs work."""
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile

app = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'org.floeagent.ios'
assert info['CFBundleSupportedPlatforms'] == ['iPhoneSimulator'], 'Never sign a device or release package here'
exe = app / info['CFBundleExecutable']
before = hashlib.sha256(exe.read_bytes()).hexdigest()
# Match this repository's development team; this is not a distribution signature.
identity = 'QYL72C43K6.' + info['CFBundleIdentifier']
entitlements = {'application-identifier': identity,
                'com.apple.developer.team-identifier': 'QYL72C43K6',
                'keychain-access-groups': [identity], 'get-task-allow': True}
with tempfile.TemporaryDirectory(prefix='floe-demo-sign-') as temp:
    path = pathlib.Path(temp) / 'entitlements.plist'
    path.write_bytes(plistlib.dumps(entitlements))
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', '--entitlements', str(path), str(app)], check=True)
    actual = subprocess.check_output(['codesign', '-d', '--entitlements', '-', '--xml', str(app)], stderr=subprocess.DEVNULL)
    signed = plistlib.loads(actual)
    assert signed['application-identifier'] == identity
    assert signed['keychain-access-groups'] == [identity]
(out / 'simulator-signing.json').write_text(json.dumps({
    'purpose': 'Disposable simulator Keychain identity; source code and tool behavior unchanged',
    'appExecutableSHA256BeforeSigning': before,
    'appExecutableSHA256AfterSigning': hashlib.sha256(exe.read_bytes()).hexdigest(),
    'signing': 'ad-hoc simulator only; not an installable device IPA',
    'entitlements': signed}, indent=2) + '\n')
print('Disposable simulator App has its own verified Keychain access group.')
