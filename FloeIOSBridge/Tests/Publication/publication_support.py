"""Hermetic fixtures for the local Bridge release publisher tests."""

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parents[1] / "scripts"
PACKAGING_TESTS = HERE.parents[0] / "Packaging"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(PACKAGING_TESTS))

import package_bridge as pb  # noqa: E402
import verify_bridge as vb  # noqa: E402
import support as packaging_support  # noqa: E402
import publish_bridge_release as pub  # noqa: E402


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(arguments)} failed: {result.stderr}")
    return result.stdout


def make_ipa(path: Path, *, signed: bool = False, extra: dict | None = None) -> Path:
    entries = {
        "Payload/BridgeHost.app/Info.plist": b"host-plist",
        "Payload/BridgeHost.app/BridgeHost": b"host-binary",
        "Payload/BridgeHost.app/PlugIns/BridgeTunnel.appex/Info.plist": b"appex-plist",
        "Payload/BridgeHost.app/PlugIns/BridgeTunnel.appex/BridgeTunnel": b"appex-binary",
        "Payload/BridgeHost.app/PlugIns/BridgeTests.xctest/Info.plist": b"test-plist",
        "Payload/BridgeHost.app/PlugIns/BridgeTests.xctest/BridgeTests": b"test-binary",
        "Payload/BridgeHost.app/Frameworks/BridgeCore.framework/Info.plist": b"core-plist",
        "Payload/BridgeHost.app/Frameworks/BridgeCore.framework/BridgeCore": b"core-binary",
    }
    if signed:
        entries["Payload/BridgeHost.app/_CodeSignature/CodeResources"] = b"signature"
        entries["Payload/BridgeHost.app/embedded.mobileprovision"] = b"profile"
    entries.update(extra or {})
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return path


class Fixture:
    def __init__(self, root: Path, *, version: str = "1.0.0", build: str = "14"):
        self.root = Path(root)
        self.version = version
        self.build = build
        self.tag = f"floe-ios-bridge-v{version}"
        self.repo = self.root / "repo"
        self.repo.mkdir(parents=True)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "bridge-publication@example.invalid")
        git(self.repo, "config", "user.name", "Bridge Publication Tests")
        self.project_dir = self.repo / "FloeIOSBridge"
        packaging_support.write_source_root(
            self.project_dir, version, build, prototype=False
        )
        (self.repo / "README.md").write_text("root fixture\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "bridge fixture")
        self.source = git(self.repo, "rev-parse", "HEAD").strip()
        git(self.repo, "tag", "-a", self.tag, "-m", f"bridge {version}")

        self.ipa = make_ipa(self.root / f"Floe-iOS-Bridge-{version}-unsigned.ipa")
        self.sidecar = Path(str(self.ipa) + ".sha256")
        self.sidecar.write_text(
            f"{sha256_bytes(self.ipa.read_bytes())}  {self.ipa.name}\n",
            encoding="utf-8",
        )
        identity = vb.load_project_identity(self.project_dir / "project.yml")
        provenance = pb.compute_provenance(
            self.repo, self.project_dir, vb.RELEASE, self.source
        )
        assert provenance["ok"], provenance["strictDeviations"]
        self.provenance = provenance
        summary = pb.build_public_summary(
            identity,
            self.ipa,
            provenance,
            {"checks": [{"ok": True}]},
            {"checks": [{"ok": True}]},
            {"ok": True},
        )
        self.summary = self.root / f"Floe-iOS-Bridge-{version}-public.json"
        self.summary.write_text(json.dumps(summary, indent=2), encoding="utf-8")
        self.notes = self.root / "notes.md"
        self.notes.write_text(
            f"Floe iOS Bridge {version} (build {build}).\n\n"
            "Unsigned universal build for iOS and iPadOS 26 or later.\n"
            "See the installation guide for local signing.\n",
            encoding="utf-8",
        )
        self.receipt = self.root / "qualification-receipt.json"
        self.receipt.write_text(
            json.dumps(self.receipt_payload(), indent=2),
            encoding="utf-8",
        )
        self.scratch = self.root / "scratch"
        self.evidence = self.root / "evidence"

    def receipt_payload(self) -> dict:
        return {
            "schema": pub.RECEIPT_SCHEMA,
            "sourceRef": self.source,
            "sourceTreeSHA256": self.provenance["sourceTreeSHA256"],
            "ipaSHA256": sha256_bytes(self.ipa.read_bytes()),
            "marketingVersion": self.version,
            "buildNumber": self.build,
            "checks": {name: True for name in pub.QUALIFICATION_CHECKS},
            "ipadQualification": pub.IPAD_QUALIFICATION,
        }

    def assets(self) -> dict[str, bytes]:
        return {
            self.ipa.name: self.ipa.read_bytes(),
            self.sidecar.name: self.sidecar.read_bytes(),
            self.summary.name: self.summary.read_bytes(),
        }

    def inputs(self, *, publish: bool = False, **overrides) -> pub.PublicationInputs:
        values = {
            "ipa": self.ipa,
            "sidecar": self.sidecar,
            "summary": self.summary,
            "notes": self.notes,
            "receipt": self.receipt,
            "version": self.version,
            "build": self.build,
            "source_ref": self.source,
            "tag": self.tag,
            "repo_root": self.repo,
            "project": self.project_dir / "project.yml",
            "publish": publish,
            "report_path": None,
            "scratch_dir": self.scratch,
            "evidence_dir": self.evidence if publish else None,
            "expect_latest_tag": None,
        }
        values.update(overrides)
        return pub.PublicationInputs(**values)

    def client(self, **kwargs) -> "FakeGitHub":
        return FakeGitHub(
            source=self.source,
            tag=self.tag,
            version=self.version,
            build=self.build,
            title=f"Floe iOS Bridge {self.version}",
            notes=self.notes.read_text(encoding="utf-8"),
            assets=self.assets(),
            **kwargs,
        )


class FakeGitHub:
    """Deterministic GitHub state with an explicit mutation call log."""

    def __init__(
        self,
        *,
        source: str,
        tag: str,
        version: str,
        build: str,
        title: str,
        notes: str,
        assets: dict[str, bytes],
    ):
        self.source = source
        self.tag = tag
        self.version = version
        self.build = build
        self.title = title
        self.notes = notes
        self.assets = dict(assets)
        self.releases: dict[int, dict] = {}
        self.asset_bytes: dict[int, dict[str, bytes]] = {}
        self.next_id = 100
        self.next_asset_id = 1000
        self.latest = {
            "id": 1,
            "tag_name": "v1.7.65",
            "target_commitish": "main",
            "name": "Floe Agent 1.7.65",
            "draft": False,
            "prerelease": False,
        }
        self.calls: list[tuple] = []
        self.tag_style = "annotated"
        self.tag_object_sha = "a" * 40
        self.tag_peeled = source
        self.tag_object_tag = tag
        self.create_behavior = "normal"
        self.update_behavior = "normal"
        self.latest_after_publish = None
        self.hide_existing_once = False
        self.find_release_calls = 0
        self.upload_behaviors: dict[str, str] = {}
        self.download_failures: set[str] = set()
        self.missing_tag = False

    # --- tag state -----------------------------------------------------
    def get_tag_ref(self, tag: str) -> dict:
        self.calls.append(("get_tag_ref", tag))
        if self.missing_tag or tag != self.tag:
            raise pub.NotFound("tag not found", status=404)
        if self.tag_style == "annotated":
            return {
                "ref": f"refs/tags/{tag}",
                "object": {"type": "tag", "sha": self.tag_object_sha},
            }
        return {
            "ref": f"refs/tags/{tag}",
            "object": {"type": "commit", "sha": self.tag_peeled},
        }

    def get_tag_object(self, object_sha: str) -> dict:
        self.calls.append(("get_tag_object", object_sha))
        if object_sha != self.tag_object_sha:
            raise pub.NotFound("tag object not found", status=404)
        return {
            "sha": self.tag_object_sha,
            "tag": self.tag_object_tag,
            "object": {"type": "commit", "sha": self.tag_peeled},
        }

    # --- latest --------------------------------------------------------
    def get_latest_release(self) -> dict:
        self.calls.append(("get_latest_release",))
        return copy.deepcopy(self.latest)

    def set_latest(self, tag: str) -> None:
        self.latest["tag_name"] = tag

    # --- releases ------------------------------------------------------
    def _release(self, release: dict) -> dict:
        payload = copy.deepcopy(release)
        payload["assets"] = [
            self._asset_payload(release, name)
            for name in self.asset_bytes.get(release["id"], {})
        ]
        return payload

    def _asset_payload(self, release: dict, name: str) -> dict:
        data = self.asset_bytes[release["id"]][name]
        asset_id = 10000 + len(self.asset_bytes[release["id"]])
        return {
            "id": asset_id,
            "name": name,
            "size": len(data),
            "state": "uploaded",
            "digest": "sha256:" + sha256_bytes(data),
            "url": (
                "https://api.github.com/repos/JiangNanGenius/floe-agent/"
                f"releases/assets/{asset_id}"
            ),
            "browser_download_url": (
                "https://github.com/JiangNanGenius/floe-agent/releases/download/"
                f"{self.tag}/{name}"
            ),
        }

    def _new_release(self, payload: dict) -> dict:
        release_id = self.next_id
        self.next_id += 1
        release = {
            "id": release_id,
            "tag_name": payload["tag_name"],
            "target_commitish": payload["target_commitish"],
            "name": payload["name"],
            "body": payload["body"],
            "draft": bool(payload.get("draft", False)),
            "prerelease": bool(payload.get("prerelease", False)),
            "html_url": (
                "https://github.com/JiangNanGenius/floe-agent/releases/tag/"
                f"{payload['tag_name']}"
            ),
            "upload_url": (
                "https://uploads.github.com/repos/JiangNanGenius/floe-agent/"
                f"releases/{release_id}/assets{{?name,label}}"
            ),
        }
        self.releases[release_id] = release
        self.asset_bytes[release_id] = {}
        return release

    def create_release(self, payload: dict) -> dict:
        self.calls.append(("create_release", copy.deepcopy(payload)))
        if self.create_behavior == "raise_no_state":
            raise pub.AmbiguousWrite("create timed out")
        if any(
            release.get("tag_name") == payload.get("tag_name")
            for release in self.releases.values()
        ):
            raise pub.GitHubError("release already exists", status=422)
        release = self._new_release(payload)
        if self.create_behavior == "accept_then_raise":
            raise pub.AmbiguousWrite("create response lost")
        return self._release(release)

    def update_release(self, release_id: int, payload: dict) -> dict:
        self.calls.append(("update_release", release_id, copy.deepcopy(payload)))
        if self.update_behavior == "raise_no_state":
            raise pub.AmbiguousWrite("update timed out")
        release = self.releases[release_id]
        if "draft" in payload:
            release["draft"] = bool(payload["draft"])
        if "prerelease" in payload:
            release["prerelease"] = bool(payload["prerelease"])
        if payload.get("draft") is False and self.latest_after_publish is not None:
            self.latest["tag_name"] = self.latest_after_publish
        if self.update_behavior == "accept_then_raise":
            raise pub.AmbiguousWrite("update response lost")
        return self._release(release)

    def get_release(self, release_id: int) -> dict:
        self.calls.append(("get_release", release_id))
        if release_id not in self.releases:
            raise pub.NotFound("release not found", status=404)
        return self._release(self.releases[release_id])

    def get_release_by_tag(self, tag: str) -> dict:
        self.calls.append(("get_release_by_tag", tag))
        for release in self.releases.values():
            if release["tag_name"] == tag and release["draft"] is False:
                return self._release(release)
        raise pub.NotFound("release not found", status=404)

    def list_releases(self, page: int = 1) -> list:
        self.calls.append(("list_releases", page))
        if page != 1:
            return []
        return [self._release(release) for release in self.releases.values()]

    def find_release(self, tag: str) -> dict | None:
        self.calls.append(("find_release", tag))
        self.find_release_calls += 1
        if self.hide_existing_once and self.find_release_calls == 1:
            return None
        for release in self.releases.values():
            if release["tag_name"] == tag:
                return self._release(release)
        return None

    def upload_asset(self, release: dict, name: str, source_path: Path) -> dict:
        data = Path(source_path).read_bytes()
        self.calls.append(("upload_asset", release["id"], name, str(source_path)))
        behavior = self.upload_behaviors.get(name, "normal")
        if behavior == "raise_no_state":
            raise pub.AmbiguousWrite("upload timed out")
        self.asset_bytes[release["id"]][name] = data
        if behavior == "accept_then_raise":
            raise pub.AmbiguousWrite("upload response lost")
        if behavior == "reject":
            raise pub.GitHubError("asset rejected", status=422)
        return self._asset_payload(release, name)

    def download_asset(self, asset: dict, destination: Path, *, max_bytes: int) -> tuple[int, str]:
        name = asset["name"]
        self.calls.append(("download_asset", name, str(destination)))
        if name in self.download_failures:
            raise pub.GitHubError("authenticated download failed")
        release_id = None
        for candidate_id, values in self.asset_bytes.items():
            if name in values:
                release_id = candidate_id
                break
        if release_id is None:
            raise pub.GitHubError("asset bytes missing")
        data = self.asset_bytes[release_id][name]
        if len(data) > max_bytes:
            raise pub.DownloadError("asset exceeds bound")
        Path(destination).write_bytes(data)
        return len(data), sha256_bytes(data)

    def seed_release(
        self,
        *,
        draft: bool,
        assets: dict[str, bytes] | None = None,
        target: str | None = None,
        name: str | None = None,
        body: str | None = None,
        prerelease: bool = False,
    ) -> dict:
        release = self._new_release({
            "tag_name": self.tag,
            "target_commitish": target or self.source,
            "name": name or self.title,
            "body": body if body is not None else self.notes,
            "draft": draft,
            "prerelease": prerelease,
        })
        for asset_name, data in (assets or {}).items():
            self.asset_bytes[release["id"]][asset_name] = data
        return self._release(release)

    def mutation_calls(self) -> list[tuple]:
        return [
            call for call in self.calls
            if call[0] in {"create_release", "update_release", "upload_asset"}
        ]


class FakeVerifier:
    def __init__(self, tree_sha: str):
        self.tree_sha = tree_sha
        self.calls: list[dict] = []
        self.responses: list[dict] = []
        self.latest_payloads: list[dict] = []

    def __call__(self, **kwargs) -> dict:
        self.calls.append(dict(kwargs))
        latest_path = Path(kwargs["latest_json"])
        self.latest_payloads.append(
            json.loads(latest_path.read_text(encoding="utf-8")) if latest_path.is_file() else {}
        )
        if self.responses:
            payload = copy.deepcopy(self.responses.pop(0))
        else:
            payload = {"ok": True, "checks": [{"name": "full-public-verifier", "ok": True}]}
        payload.setdefault("sourceRef", kwargs["source_ref"])
        payload.setdefault("tag", kwargs["tag"])
        payload.setdefault("version", kwargs["version"])
        payload.setdefault("buildNumber", kwargs["build"])
        payload.setdefault("sourceTreeSHA256", self.tree_sha)
        return payload


class FakeDownloader:
    def __init__(self, contents: dict[str, bytes]):
        self.contents = dict(contents)
        self.calls: list[dict] = []
        self.failures: set[str] = set()

    def fetch(
        self,
        url: str,
        destination: Path,
        *,
        expected_size: int,
        expected_sha256: str,
        max_bytes: int,
    ) -> tuple[int, str]:
        self.calls.append({
            "url": url,
            "destination": str(destination),
            "expected_size": expected_size,
            "expected_sha256": expected_sha256,
            "max_bytes": max_bytes,
        })
        if url in self.failures:
            raise pub.DownloadError("public download failed")
        data = self.contents.get(url)
        if data is None:
            raise pub.DownloadError("public download URL not found")
        if len(data) != expected_size or sha256_bytes(data) != expected_sha256:
            raise pub.DownloadError("public download does not match")
        Path(destination).write_bytes(data)
        return len(data), sha256_bytes(data)


def make_publisher(
    fixture: Fixture,
    *,
    publish: bool = False,
    client: FakeGitHub | None = None,
    verifier: FakeVerifier | None = None,
    downloader: FakeDownloader | None = None,
    inputs: pub.PublicationInputs | None = None,
) -> tuple[pub.Publisher, FakeGitHub, FakeVerifier, FakeDownloader]:
    client = client or fixture.client()
    verifier = verifier or FakeVerifier(fixture.provenance["sourceTreeSHA256"])
    contents = {
        f"https://github.com/JiangNanGenius/floe-agent/releases/download/{fixture.tag}/{name}": data
        for name, data in fixture.assets().items()
    }
    downloader = downloader or FakeDownloader(contents)
    publisher = pub.Publisher(
        inputs or fixture.inputs(publish=publish),
        client=client,
        verifier=verifier,
        downloader=downloader,
        sleep_fn=lambda _: None,
        clock=lambda: "TESTSTAMP",
    )
    return publisher, client, verifier, downloader
