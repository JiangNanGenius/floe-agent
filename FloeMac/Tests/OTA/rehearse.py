import base64
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from threading import Thread
import time
import uuid
from xml.sax.saxutils import escape

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


binary, framework, evidence = (Path(part).resolve() for part in sys.argv[1:4])
team = "QYL72C43K6"
identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
certificate = next(
    match[1] for line in identities.splitlines()
    if (match := re.search(r'([0-9A-F]{40})\s+"Developer ID Application: .+? \(' + team + r'\)"', line))
)


def run(*command):
    subprocess.run(command, capture_output=True, text=True, check=True, timeout=20)


def make_app(folder, bundle_id, root, feed_url, public_key, version, build):
    app = folder / "OTAFixture.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    shutil.copy2(binary, contents / "MacOS/OTAFixture")
    run("ditto", str(framework), str(contents / "Frameworks/Sparkle.framework"))
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": "Floe OTA Fixture",
        "CFBundleExecutable": "OTAFixture",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": str(build),
        "CFBundleShortVersionString": version,
        "LSMinimumSystemVersion": "15.0",
        "LSUIElement": True,
        "FloeFixtureRoot": str(root),
        "SUFeedURL": feed_url,
        "SUPublicEDKey": public_key,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUEnableAutomaticChecks": False,
        "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", certificate, "--timestamp=none", "--options", "runtime", str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    return app


def current_build(app):
    try:
        return plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
    except FileNotFoundError:
        return None


def stop_fixture(events, app):
    for line in events:
        if not line.startswith("pid:"):
            continue
        pid = int(line.partition(":")[2])
        actual = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
        if actual.strip().startswith(str(app / "Contents/MacOS/OTAFixture")):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


def rehearse(name, valid):
    with tempfile.TemporaryDirectory(prefix="floe-ota-", dir="/private/tmp") as scratch:
        root = Path(scratch)
        download = root / "download"
        download.mkdir()
        logs = root / "events.log"
        logs.touch()
        server_log = (evidence / (name + "-http.log")).open("w")

        class Handler(SimpleHTTPRequestHandler):
            def log_message(self, fmt, *args):
                print(fmt % args, file=server_log, flush=True)

        with ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(download))) as server:
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            key = Ed25519PrivateKey.generate()
            public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
            public_encoded = base64.b64encode(public).decode("ascii")
            identity = "org.floeagent.sparkle-fixture." + uuid.uuid4().hex
            old = make_app(root / "Installed", identity, root, base + "/appcast.xml", public_encoded, "1.1.6", 9)
            new = make_app(root / "New", identity, root, base + "/appcast.xml", public_encoded, "1.2.0", 10)
            archive = download / "updated.dmg"
            run("hdiutil", "create", "-quiet", "-volname", "Floe OTA Fixture",
                "-srcfolder", str(new.parent), "-format", "UDZO", str(archive))
            payload = archive.read_bytes()
            signature = key.sign(payload if valid else payload + b"unpublished fixture")
            encoded_signature = base64.b64encode(signature).decode("ascii")
            (download / "appcast.xml").write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                '<channel><title>Floe local OTA rehearsal</title><item><title>1.2.0</title>'
                '<sparkle:version>10</sparkle:version><sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>'
                '<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>'
                f'<enclosure url="{escape(base)}/updated.dmg" length="{len(payload)}" '
                f'sparkle:edSignature="{encoded_signature}" type="application/octet-stream"/>'
                '</item></channel></rss>', encoding="utf-8"
            )
            events = []
            try:
                run("open", "-n", "-a", str(old))
                cutoff = time.monotonic() + 48
                while time.monotonic() < cutoff:
                    events = logs.read_text().splitlines()
                    if any(line.startswith(("updater-start-error:", "not-found:")) for line in events):
                        break
                    if "work-still-admitted" in events or (
                        valid and any(line.startswith("error:") for line in events)
                    ):
                        break
                    if "preserved-state" in events or "lost-state" in events:
                        break
                    time.sleep(0.2)
                observed = {"installationBuild": current_build(old), "events": events}
                (evidence / (name + ".json")).write_text(json.dumps(observed, indent=2) + "\n")
                if valid:
                    assert observed["installationBuild"] == "10", observed
                    phases = ["found:10", "download", "deferred-for-job", "old-version-held-while-busy",
                              "quit-with-closed-admission", "launch:10", "preserved-state"]
                    assert all(s in events for s in phases), observed
                    assert [events.index(s) for s in phases] == sorted(events.index(s) for s in phases), observed
                    run("codesign", "--verify", "--deep", "--strict", str(old))
                else:
                    assert observed["installationBuild"] == "9" and "download" in events, observed
                    assert any(line.startswith("error:SUSparkleErrorDomain:4005:") for line in events), observed
                    assert "work-still-admitted" in events, observed
                    assert "launch:10" not in events, observed
            finally:
                stop_fixture(events, old)
                server.shutdown()
                thread.join(timeout=3)
                server_log.close()


for case in (sys.argv[4:] or ["accepted", "wrong-signature"]):
    assert case in ("accepted", "wrong-signature")
    rehearse(case, valid=case == "accepted")
    print(case + " passed", flush=True)
