#!/usr/bin/env python3
"""Verified updater for the Floe remote agent.

It runs only when invoked by the host owner or by an explicitly approved Floe
action. Packages come from this repository's releases, are SHA-256 verified,
and are installed atomically with health-check rollback.
"""

import argparse
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request

REPOSITORY = "JiangNanGenius/floe-agent"
INSTALL_ROOT = pathlib.Path("~/.local/lib/floe-agent").expanduser()
ALLOWED_FILES = {"floe_remote_agent.py", "floe_agent_update.py", "REMOTE-AGENT-MANIFEST.json"}


def request_json(url):
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "FloeRemoteAgentUpdater"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def download(url):
    request = urllib.request.Request(url, headers={"Accept": "application/octet-stream", "User-Agent": "FloeRemoteAgentUpdater"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def select_release(tag):
    if tag:
        return request_json(f"https://api.github.com/repos/{REPOSITORY}/releases/tags/{tag}")
    releases = request_json(f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=30")
    for release in releases:
        if not release.get("draft"):
            return release
    raise RuntimeError("no published Floe release found")


def restart_and_check(expected_version):
    if shutil.which("systemctl"):
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=False)
        subprocess.run(["systemctl", "--user", "restart", "floe-agent.service"], check=True)
    else:
        subprocess.run(["pkill", "-f", "/.local/lib/floe-agent/floe_remote_agent.py"], check=False)
        log_path = pathlib.Path("~/.floe/floe-agent.log").expanduser()
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("ab") as log:
            subprocess.Popen(
                [str(pathlib.Path("~/.local/bin/floe-agent").expanduser())],
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
    token = pathlib.Path("~/.config/floe-agent/token").expanduser().read_text(encoding="utf-8").strip()
    for _ in range(20):
        try:
            request = urllib.request.Request("http://127.0.0.1:43187/v1/health", headers={"Authorization": "Bearer " + token})
            with urllib.request.urlopen(request, timeout=2) as response:
                body = json.load(response)
            if body.get("ok") and body.get("version") == expected_version:
                return
        except Exception:
            time.sleep(0.25)
    raise RuntimeError("updated daemon failed its health check")


def safe_extract(archive, stage):
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
        members = [member for member in bundle.getmembers() if member.isfile()]
        names = {pathlib.PurePosixPath(member.name).name for member in members}
        if names != ALLOWED_FILES:
            raise RuntimeError("remote-agent package contains unexpected files")
        for member in members:
            member.name = pathlib.PurePosixPath(member.name).name
            # The exact flat allow-list above prevents traversal and keeps the
            # updater compatible with Python versions used by older LTS hosts.
            bundle.extract(member, stage)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", help="Floe release tag; omitted selects newest published release")
    args = parser.parse_args()
    release = select_release(args.tag)
    assets = {item["name"]: item["browser_download_url"] for item in release.get("assets", [])}
    archives = sorted(name for name in assets if name.startswith("floe-remote-agent-") and name.endswith(".tar.gz"))
    if not archives:
        raise RuntimeError("release has no Floe remote-agent package")
    archive_name = archives[-1]
    checksum_name = archive_name + ".sha256"
    if checksum_name not in assets:
        raise RuntimeError("release is missing the remote-agent checksum")
    archive = download(assets[archive_name])
    expected = download(assets[checksum_name]).decode("ascii").split()[0].lower()
    if hashlib.sha256(archive).hexdigest() != expected:
        raise RuntimeError("remote-agent package SHA-256 mismatch")

    with tempfile.TemporaryDirectory(prefix="floe-agent-update-") as temporary:
        stage = pathlib.Path(temporary)
        safe_extract(archive, stage)
        expected_version = json.loads(stage.joinpath("REMOTE-AGENT-MANIFEST.json").read_text(encoding="utf-8"))["agent_version"]
        backup = INSTALL_ROOT.with_name(INSTALL_ROOT.name + ".previous")
        replacement = INSTALL_ROOT.with_name(INSTALL_ROOT.name + ".next")
        if replacement.exists():
            shutil.rmtree(replacement)
        replacement.mkdir(parents=True)
        for name in ALLOWED_FILES:
            shutil.copy2(stage / name, replacement / name)
        if backup.exists():
            shutil.rmtree(backup)
        if INSTALL_ROOT.exists():
            os.replace(INSTALL_ROOT, backup)
        os.replace(replacement, INSTALL_ROOT)
        try:
            restart_and_check(expected_version)
        except Exception:
            if INSTALL_ROOT.exists():
                shutil.rmtree(INSTALL_ROOT)
            if backup.exists():
                os.replace(backup, INSTALL_ROOT)
                old_manifest = json.loads(INSTALL_ROOT.joinpath("REMOTE-AGENT-MANIFEST.json").read_text(encoding="utf-8"))
                restart_and_check(old_manifest["agent_version"])
            raise
        if backup.exists():
            shutil.rmtree(backup)
        print(json.dumps({"ok": True, "version": expected_version, "release": release["tag_name"]}))


if __name__ == "__main__":
    main()
