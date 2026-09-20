#!/usr/bin/env python3
"""verify_base_release.py — read-only preflight for the runner-update pipeline.

Checks (never mutates anything):
  * this workflow's own safety contract (draft-only release, never --clobber,
    tag policy, registration push runs preflight only);
  * the requested component tag/image id are new and policy-conformant
    (no leading v/V, never "latest", not the base tag, no existing foreign
    tag/release; only our own marked draft may be resumed);
  * the pinned base component release (floe-linux-guest-20260920.1) still
    exists, is the published prerelease on the pinned base commit, and every
    one of its 13 assets matches the pinned name/size/SHA-256 exactly;
  * on dispatch: the target commit is a full 40-hex SHA, resolves, carries the
    whole pipeline (scripts + host + install path), its runner sources really
    are protocol 3 with a concurrent command/session table big enough for the
    focused check, and the engine artifact contract (`runnerArtifact` +
    `runnerCapabilities`, the Role enum the JSON must stay inside, and the
    registry upgrade consumer) is integrated — so an old-runner ref or a
    half-integrated engine fails closed instead of producing an image that
    cannot be consumed or cannot upgrade an existing disk.

Input is entirely via environment (see below); output is a JSON record.
Exit 1 when any check fails.

Env: REPO, EVENT_NAME, COMPONENT_TAG, IMAGE_ID, TARGET_COMMIT, RELEASE_MARKER,
     WORKFLOW_FILE, PREFLIGHT_OUT,
     BASE_TAG, BASE_TARGET_COMMIT, BASE_ZIP, BASE_ZIP_BYTES, BASE_ZIP_SHA256,
     BASE_ASSETS_JSON  ({"name": {"bytes": n, "sha256": hex}, ...} all 13)
"""
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_contract  # noqa: E402  (sibling script directory)

failures = []
facts = {}

PIPELINE_FILES = (
    "FloeAgent/scripts/linux-guest-runner-update/verify_base_release.py",
    "FloeAgent/scripts/linux-guest-runner-update/pipeline_contract.py",
    "FloeAgent/scripts/linux-guest-runner-update/build_runner.sh",
    "FloeAgent/scripts/linux-guest-runner-update/prepare_image.sh",
    "FloeAgent/scripts/linux-guest-runner-update/guest_protocol_check.py",
    "FloeAgent/scripts/linux-guest-runner-update/package_component.py",
    "FloeAgent/scripts/linux-guest-runner-update/selfcheck.py",
    "FloeAgent/LinuxGuest/image/floe-guest-init",
    "FloeAgent/LinuxGuest/image/install-into-image.sh",
    "FloeAgent/LinuxGuest/image/write-image-manifest.py",
    "FloeAgent/Qualification/TinyEMULinux/floe_vm_host.c",
    "FloeAgent/ThirdParty/TinyEMU/fetch_source.sh",
    "FloeAgent/ThirdParty/TinyEMU/license_check.sh",
    "FloeAgent/ThirdParty/TinyEMU/adapter/Makefile",
)

# Framing/marker literals the focused guest check drives (all code literals,
# comments excluded on purpose: an unimplemented comment must not pass).
RUNNER_MARKERS = ('FLOE-CAPS', 'FLOE-END', 'FLOE-PID', 'FLOE-FAILED', 'FLOE_MARK',
                  'FLOE_CANCEL', '"BEGIN"', '"HELLO"', '"OPEN"', '"SPAWN"', '"SIGNAL"',
                  '"ALIVE"', '"KILL"', '"CLOSE"', '"CHUNK"', '"RUN"', '"IN"')


def ok(message):
    print("OK: %s" % message, flush=True)


def fail(message):
    failures.append(message)
    print("FAIL: %s" % message, flush=True)


def note(message):
    print("note: %s" % message, flush=True)


def require(condition, message):
    ok(message) if condition else fail(message)
    return bool(condition)


def gh(path, allow_missing=False):
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if result.returncode != 0:
        if allow_missing and "404" in (result.stderr + result.stdout):
            return None
        raise SystemExit("gh api %s failed: %s%s" % (path, result.stdout.strip(), result.stderr.strip()))
    return json.loads(result.stdout)


def gh_file(relative, ref):
    """Raw bytes of a file at a ref, or None when missing."""
    payload = gh("repos/%s/contents/%s?ref=%s" % (os.environ["REPO"], relative, ref), allow_missing=True)
    if payload is None:
        return None
    return base64.b64decode(payload["content"])


def check_workflow_contract():
    contract = open(os.environ["WORKFLOW_FILE"], encoding="utf-8").read()
    for needle in ("workflow_dispatch:", "target_commit:", "component_tag:", "image_id:",
                   "--draft", "--prerelease", "--latest=false",
                   "if: github.event_name == 'workflow_dispatch'",
                   "floe-linux-guest-20260920.1"):
        require(needle in contract, "workflow contract contains %r" % needle)
    clobber_lines = [line for line in contract.splitlines()
                     if "--clobber" in line and not line.lstrip().startswith("#") and "never" not in line]
    require(not clobber_lines, "workflow never passes --clobber to a release command")
    require("runnerArtifact" in contract or "package_component.py" in contract,
            "workflow invokes the packaging step that writes the runner artifact fields")


def check_tag_policy(repo, event, tag, image_id, marker, base_tag):
    require(re.fullmatch(r"floe-linux-guest-[A-Za-z0-9][A-Za-z0-9._-]{0,80}", tag) is not None,
            "component tag %r matches floe-linux-guest-* with safe characters" % tag)
    require(not tag.startswith(("v", "V")) and tag != "latest",
            "component tag %r does not start with v and is not latest" % tag)
    require(tag != base_tag, "component tag %r is not the base tag %s" % (tag, base_tag))
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,80}", image_id) is not None,
            "image id %r has safe characters" % image_id)
    require(image_id != "floe-debian13-riscv64-202609202607", "image id %r differs from the base image id" % image_id)

    release = gh("repos/%s/releases/tags/%s" % (repo, tag), allow_missing=True)
    if release is None:
        # GET /releases/tags/<tag> never returns drafts; find our own marked
        # draft through the release list, like the distribution workflow does.
        listed = gh("repos/%s/releases?per_page=100" % repo) or []
        drafts = [item for item in listed if item.get("tag_name") == tag]
        if len(drafts) == 1 and drafts[0].get("draft") and marker in (drafts[0].get("body") or ""):
            release = drafts[0]
        elif drafts:
            fail("tag %s has %d release row(s) that are not our single marked draft" % (tag, len(drafts)))
            release = None
    facts["release"] = None
    if release is None:
        ref = gh("repos/%s/git/ref/tags/%s" % (repo, tag), allow_missing=True)
        if ref is None:
            note("tag %s and its release are both free" % tag)
        elif event == "workflow_dispatch":
            fail("tag %s already exists without a release; refusing to touch it" % tag)
        else:
            note("tag %s already exists (registration preflight only)" % tag)
    else:
        ours = bool(release.get("draft")) and release.get("tag_name") == tag and marker in (release.get("body") or "")
        facts["release"] = {"id": release.get("id"), "draft": release.get("draft"), "url": release.get("html_url"),
                            "target_commitish": release.get("target_commitish"), "ours": ours,
                            "assets": sorted(asset["name"] for asset in release.get("assets", []))}
        if ours:
            note("resuming our own draft release %s" % release.get("html_url"))
        elif event == "workflow_dispatch":
            fail("release for tag %s already exists and is not our marked draft (draft=%s)" % (tag, release.get("draft")))
        else:
            note("tag %s already has a release (registration preflight only)" % tag)


def check_base_release(repo, base_tag, base_commit, base_zip, base_zip_bytes, base_zip_sha256, base_assets):
    base = gh("repos/%s/releases/tags/%s" % (repo, base_tag), allow_missing=True)
    if not require(base is not None, "base release %s exists" % base_tag):
        base = {"assets": []}
    if base:
        require(base.get("draft") is False, "base release %s is published (not a draft)" % base_tag)
        require(base.get("prerelease") is True, "base release %s is a prerelease" % base_tag)
        require(base.get("target_commitish") == base_commit,
                "base release targets the pinned base commit %s" % base_commit[:12])
        found = {asset["name"]: asset for asset in base.get("assets", [])}
        require(sorted(found) == sorted(base_assets),
                "base release has exactly the 13 pinned assets (%d found)" % len(found))
        for name, pin in sorted(base_assets.items()):
            asset = found.get(name)
            if not asset:
                continue
            require(asset.get("size") == pin["bytes"], "base asset %s is %d bytes" % (name, pin["bytes"]))
            require(asset.get("digest") == "sha256:" + pin["sha256"],
                    "base asset %s digest is sha256:%s…" % (name, pin["sha256"][:16]))
            require(asset.get("state") == "uploaded", "base asset %s is fully uploaded" % name)
        zip_asset = found.get(base_zip, {})
        require(zip_asset.get("size") == base_zip_bytes and zip_asset.get("digest") == "sha256:" + base_zip_sha256,
                "base image archive %s matches the pinned bytes+sha256" % base_zip)
        facts["baseRelease"] = {"id": base.get("id"), "url": base.get("html_url"),
                                "publishedAt": base.get("published_at"),
                                "assets": len(base.get("assets", []))}


def check_target_commit(repo, base_commit, target):
    facts["target"] = None
    if not require(re.fullmatch(r"[0-9a-f]{40}", target) is not None, "target commit is a full 40-hex SHA"):
        return
    commit = gh("repos/%s/commits/%s" % (repo, target))
    require(commit["sha"] == target, "target commit resolves to itself")
    facts["target"] = {"sha": commit["sha"], "subject": commit["commit"]["message"].splitlines()[0],
                       "date": commit["commit"]["committer"]["date"]}

    # --- the target commit carries the whole pipeline -----------------------
    for relative in PIPELINE_FILES:
        require(gh("repos/%s/contents/%s?ref=%s" % (repo, relative, target), allow_missing=True) is not None,
                "target commit contains %s" % relative)

    # --- runner sources: protocol 3 with room for the focused check ---------
    runner_bytes = gh_file("FloeAgent/LinuxGuest/runner/floe_exec.c", target)
    if require(runner_bytes is not None, "target commit contains the runner source"):
        source = runner_bytes.decode("utf-8", "replace")
        require("FLOE_PROTOCOL_VERSION 3" in source, "runner at target declares FLOE_PROTOCOL_VERSION 3")
        try:
            constants = pipeline_contract.parse_runner_constants(source)
        except ValueError as error:
            fail("runner constants at target parse: %s" % error)
            constants = None
        if constants:
            ok("runner constants at target: %s" % json.dumps(constants, sort_keys=True))
            facts["runnerConstants"] = constants
            facts["runnerCaps"] = pipeline_contract.expected_caps(constants)
            require(constants["protocol"] == 3, "runner protocol constant is 3")
            require(constants["max_commands"] >= 4,
                    "runner allows >=4 concurrent commands (focused 4-way overlap)")
            require(constants["max_sessions"] >= 2, "runner allows >=2 concurrent PTY sessions")
        for marker in RUNNER_MARKERS:
            require(marker in source, "runner source implements %s" % marker)
        base_runner = gh_file("FloeAgent/LinuxGuest/runner/floe_exec.c", base_commit)
        if base_runner:
            require(hashlib.sha256(runner_bytes).hexdigest() != hashlib.sha256(base_runner).hexdigest(),
                    "runner source at target differs from the base runner (update is real)")

    # --- engine artifact contract (runnerArtifact/runnerCapabilities) -------
    engine_bytes = gh_file("FloeAgent/Sources/FloeExecution/Linux/LinuxGuestService.swift", target)
    if require(engine_bytes is not None, "target commit contains LinuxGuestService.swift"):
        engine_source = engine_bytes.decode("utf-8", "replace")
        roles, has_fields = pipeline_contract.engine_runner_contract(engine_source)
        require(has_fields,
                "engine LinuxGuestImage carries runnerArtifact + runnerCapabilities")
        require(roles is not None, "engine LinuxGuestImageArtifact.Role enum parses")
        try:
            role, policy, reason = pipeline_contract.choose_runner_role(
                roles, os.environ.get("RUNNER_ARTIFACT_ROLE"))
            ok("runnerArtifact role for this target: %r (%s)" % (role, policy))
            note("role policy: %s" % reason)
            facts["runnerArtifact"] = {"role": role, "policy": policy, "reason": reason,
                                       "enumRoles": roles}
        except ValueError as error:
            fail("runnerArtifact role: %s" % error)

    registry_bytes = gh_file("FloeAgent/Sources/FloeExecution/Linux/LinuxGuestRegistry.swift", target)
    if require(registry_bytes is not None, "target commit contains LinuxGuestRegistry.swift"):
        registry_source = registry_bytes.decode("utf-8", "replace")
        require("runnerArtifact" in registry_source,
                "registry has the in-guest runner upgrade path that consumes runnerArtifact")
        facts["engineRegistryConsumer"] = "runnerArtifact" in registry_source


def main():
    repo = os.environ["REPO"]
    event = os.environ["EVENT_NAME"]
    tag = os.environ["COMPONENT_TAG"].strip()
    image_id = os.environ["IMAGE_ID"].strip()
    target = (os.environ.get("TARGET_COMMIT") or "").strip()
    marker = os.environ["RELEASE_MARKER"]
    base_tag = os.environ["BASE_TAG"]
    base_commit = os.environ["BASE_TARGET_COMMIT"]
    base_zip = os.environ["BASE_ZIP"]
    base_zip_bytes = int(os.environ["BASE_ZIP_BYTES"])
    base_zip_sha256 = os.environ["BASE_ZIP_SHA256"]
    base_assets = json.loads(os.environ["BASE_ASSETS_JSON"])

    check_workflow_contract()
    check_tag_policy(repo, event, tag, image_id, marker, base_tag)
    check_base_release(repo, base_tag, base_commit, base_zip, base_zip_bytes, base_zip_sha256, base_assets)
    if event == "workflow_dispatch":
        check_target_commit(repo, base_commit, target)
    else:
        note("registration push: the target-commit contract checks run on dispatch only")
        facts["target"] = None

    payload = {"schema": "floe-linux-guest-runner-update-preflight/v1",
               "checkedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "event": event, "repository": repo, "componentTag": tag, "imageId": image_id,
               "targetCommit": target or None, "baseTag": base_tag, "facts": facts, "failures": failures}
    out = os.environ["PREFLIGHT_OUT"]
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    print("\npreflight: %d failure(s); wrote %s" % (len(failures), out))
    for failure in failures:
        print("  - %s" % failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
