#!/usr/bin/env python3
"""Verify a recovered compiled test host before any UI test runs.

The dual-device IDE UI qualification must be recoverable without rebuilding the
App. A previously uploaded ``compiled-test-host-<sha>`` artifact is usable only
after its provenance, integrity and contents are proven:

* the artifact came from the trusted ``ci.yml`` workflow of this repository,
  reached by ``push`` or ``workflow_dispatch`` (never an external pull request);
* the run's full source SHA, run id and attempt match the request, and the
  ``Upload recoverable compiled test host`` step succeeded;
* the archive's ``SOURCE-SHA/RUN/ATTEMPT``, recorded toolchain and the
  ``Products.tar.gz`` digest match, including an optional pinned digest;
* the tar archive cannot escape the extraction directory, contains only regular
  files and directories (every symlink, hardlink, device or FIFO member is
  rejected) and contains exactly the expected xctestrun and the
  ``FloeAgentUITests-Runner.app`` UITest runner.

The runner's own ``xcodebuild -version`` and simulator SDK major are checked by
the workflow before this helper runs, so the archive TOOLCHAIN text is only ever
compared against the toolchain that actually executes the tests.

The run's UI phase may be absent, running or failed: recovery exists precisely
for hosts whose UI phase never completed, so the run conclusion is never
required to be ``success``.

Only after every check passes is a path handed to ``xcodebuild``.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tarfile
from pathlib import Path

TRUSTED_REPOSITORY = "JiangNanGenius/floe-agent"
TRUSTED_WORKFLOW_PATH = ".github/workflows/ci.yml"
TRUSTED_EVENTS = ("push", "workflow_dispatch")
HOST_JOB = "build-test"
HOST_UPLOAD_STEP = "Upload recoverable compiled test host"
HOST_RETAIN_STEP = "Retain the complete compiled test host before UI execution"

# Bounded extraction: a hostile or corrupt archive must not exhaust the runner
# before the real host is rejected.
MAX_MEMBERS = 60000
MAX_UNCOMPRESSED_BYTES = 16 * 1024 * 1024 * 1024
_READ_CHUNK = 1024 * 1024
# Exactly the plain regular-file and directory type codes; contiguous files,
# sparse members and every link/device/FIFO type are refused.
_ALLOWED_MEMBER_TYPES = frozenset(
    (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE))
_FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_DRIVE = re.compile(r"^[A-Za-z]:")


class HostVerificationError(ValueError):
    """The candidate host is not a trusted, intact compiled test host."""


def _require(condition: object, message: str) -> None:
    if not condition:
        raise HostVerificationError(message)


def artifact_name(source_sha: str, prefix: str = "compiled-test-host") -> str:
    return f"{prefix}-{source_sha}"


def expected_toolchain(xcode_version: str, xcode_build: str) -> str:
    """The exact ``xcodebuild -version`` text written into TOOLCHAIN.txt."""
    return f"Xcode {xcode_version}\nBuild version {xcode_build}\n"


def _read_text(path: Path) -> str:
    _require(path.is_file(), f"missing archive member {path.name}")
    return path.read_text(encoding="utf-8")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(_READ_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_metadata(metadata: dict, *, source_sha: str, source_run: str,
                    source_attempt: str, repository: str = TRUSTED_REPOSITORY,
                    workflow_path: str = TRUSTED_WORKFLOW_PATH,
                    host_job: str = HOST_JOB,
                    upload_step: str = HOST_UPLOAD_STEP,
                    retain_step: str | None = HOST_RETAIN_STEP,
                    artifact_prefix: str = "compiled-test-host",
                    controller_sha: str = "",
                    source_checkout_step: str | None = None,
                    source_verify_step: str | None = None) -> dict:
    """Prove the host came from the trusted run before it is downloaded.

    The job and step names default to the ``ci.yml`` App-regression host; a
    release-side recovery passes its own trusted workflow/job/step names while
    keeping the same archive, digest and extraction policy.

    A ``ci.yml`` host carries ``head_sha == source_sha``. A release-recovery host
    is built by a ``workflow_dispatch`` controller run whose ``head_sha`` is the
    controller commit, so the caller may pass ``controller_sha`` (the SHA
    recorded inside the verified archive) together with the source-checkout and
    tagged-source verification steps. Provenance is then bound, not loosened:
    the run head must equal the controller commit, the run must be a dispatch,
    both source-binding steps must have succeeded, and the archive itself is
    still pinned to ``source_sha`` and (optionally) a digest.
    """
    _require(isinstance(metadata, dict), "run metadata must be a JSON object")
    _require(bool(_FULL_SHA.match(source_sha or "")),
             "source SHA must be a full 40-hex lowercase commit")
    _require(str(source_run).isdigit(), "source run must be numeric")
    _require(str(source_attempt).isdigit() and int(source_attempt) >= 1,
             "source attempt must be a positive integer")

    _require(metadata.get("repository") == repository,
             f"run does not belong to the trusted repository {repository}")
    _require(metadata.get("workflow_path") == workflow_path,
             f"run is not the trusted workflow {workflow_path}")
    event = metadata.get("event")
    _require(event in TRUSTED_EVENTS,
             f"run event {event!r} is not a trusted push/workflow_dispatch")
    run_id = metadata.get("run_id")
    _require(str(run_id) == str(source_run), "run id does not match the request")
    run_attempt = metadata.get("run_attempt")
    _require(str(run_attempt) == str(source_attempt),
             "run attempt does not match the request")

    name = artifact_name(source_sha, artifact_prefix)
    artifacts = metadata.get("artifacts") or []
    matches = [item for item in artifacts
               if isinstance(item, dict) and item.get("name") == name]
    _require(len(matches) == 1,
             f"expected exactly one artifact named {name}")
    artifact = matches[0]
    _require(artifact.get("expired") is False, "host artifact is expired")
    _require(str(artifact.get("workflow_run_id")) == str(run_id),
             "host artifact does not belong to the requested run")
    _require(int(artifact.get("size_in_bytes") or 0) > 0, "host artifact is empty")

    jobs = metadata.get("jobs") or []
    job = next((item for item in jobs
                if isinstance(item, dict) and item.get("name") == host_job), None)
    _require(job is not None, f"trusted run has no {host_job} job")
    steps = {step.get("name"): step for step in (job.get("steps") or [])
             if isinstance(step, dict)}
    upload = steps.get(upload_step)
    _require(upload is not None,
             "host upload step is missing: the run never built or uploaded a host")
    _require(upload.get("conclusion") == "success",
             "host upload step did not succeed; a failed or pending upload is not recoverable")
    if retain_step is not None:
        retain = steps.get(retain_step)
        if retain is not None:
            _require(retain.get("conclusion") == "success",
                     "host retention step did not succeed")

    # Bind the host's own source commit. A plain ci.yml host is built from the
    # requested application SHA. A release-recovery host is built by a
    # workflow_dispatch controller run whose head is the controller commit, so
    # the caller passes that commit (recorded inside the same digest-pinned
    # archive) plus the two source-binding steps; the application SHA is still
    # proven separately by SOURCE-SHA.txt in verify_archive.
    if controller_sha:
        _require(bool(_FULL_SHA.match(controller_sha)),
                 "controller SHA must be a full 40-hex lowercase commit")
        _require(metadata.get("head_sha") == controller_sha,
                 "run head SHA does not match the controller commit recorded in the host archive")
        _require(event == "workflow_dispatch",
                 "a controller-bound host must come from a workflow_dispatch run")
        for label, step_name in (("source checkout", source_checkout_step),
                                 ("tagged-source verification", source_verify_step)):
            _require(bool(step_name),
                     f"controller binding requires the {label} step name")
            step = steps.get(step_name)
            _require(step is not None,
                     f"controller-bound run has no {label} step: {step_name}")
            _require(step.get("conclusion") == "success",
                     f"controller-bound {label} step did not succeed: {step_name}")
    else:
        _require(source_checkout_step is None and source_verify_step is None,
                 "source binding steps require a controller SHA binding")
        _require(metadata.get("head_sha") == source_sha,
                 "run head SHA does not match the requested full source SHA")

    return {
        "repository": repository,
        "workflow_path": workflow_path,
        "event": event,
        "head_sha": metadata.get("head_sha"),
        "source_sha": source_sha,
        "controller_sha": controller_sha or None,
        "run_id": int(run_id),
        "run_attempt": int(run_attempt),
        "artifact_id": artifact.get("id"),
        "artifact_name": name,
        "binding": "controller" if controller_sha else "source",
    }


def _within(dest: Path, candidate: Path) -> bool:
    return candidate == dest or dest in candidate.parents


def _validate_member(member: tarfile.TarInfo, dest: Path, seen: set) -> str:
    raw = member.name
    _require(isinstance(raw, str) and raw != "", "archive member has an empty name")
    _require("\x00" not in raw, "archive member name contains a NUL byte")
    _require(not raw.startswith(("/", "\\")), f"archive member {raw!r} is absolute")
    _require(not _DRIVE.match(raw), f"archive member {raw!r} has a drive prefix")
    _require("\\" not in raw,
             f"archive member {raw!r} uses a backslash path separator")
    # A real compiled test host is a plain file/directory tree. Links and
    # special entries are refused outright instead of trying to prove that a
    # symlink/hardlink chain cannot escape; that keeps a hostile archive from
    # trading on member order or on paths that only exist after extraction.
    _require(member.type in _ALLOWED_MEMBER_TYPES,
             f"archive member {raw!r} is not a regular file or directory")

    parts = [part for part in raw.rstrip("/").split("/") if part not in ("", ".")]
    _require(parts and ".." not in parts,
             f"archive member {raw!r} escapes the extraction directory")
    normalized = "/".join(parts)
    # Two members that normalize to the same path (for example ``Products`` and
    # ``Products/``) would otherwise race during extraction; reject them.
    _require(normalized not in seen,
             f"archive member {raw!r} repeats the normalized path {normalized!r}")

    target = dest.joinpath(*parts)
    _require(_within(dest, target.resolve()),
             f"archive member {raw!r} escapes the extraction directory")
    seen.add(normalized)
    return normalized


def safe_extract(tar_path: Path, dest: Path) -> int:
    """Extract a validated tar archive and return the member count.

    Only regular files and directories are accepted; every symlink, hardlink,
    device, FIFO or other special member is rejected before a single byte is
    written, and duplicate normalized names are refused. Absolute paths, ``..``
    traversal, NUL/drive/backslash names and members that resolve outside the
    destination are rejected up front. The extraction directory must not
    already contain unrelated files.
    """
    tar_path = Path(tar_path)
    dest = Path(dest)
    _require(tar_path.is_file(), f"{tar_path.name} is missing")
    if dest.exists():
        _require(dest.is_dir() and not any(dest.iterdir()),
                 f"extraction directory {dest} must be empty")
    else:
        dest.mkdir(parents=True)
    dest = dest.resolve()

    with tarfile.open(tar_path, "r:gz") as archive:
        members = archive.getmembers()
        _require(0 < len(members) <= MAX_MEMBERS,
                 f"archive has {len(members)} members, outside the allowed range")
        seen: set = set()
        total = 0
        for member in members:
            _validate_member(member, dest, seen)
            total += max(member.size, 0)
            _require(total <= MAX_UNCOMPRESSED_BYTES,
                     "archive expands beyond the allowed uncompressed size")
        try:
            # Validation already refused every non-file/directory member, so the
            # only entries handed to extraction are regular files and dirs.
            archive.extractall(dest, members=members, filter="fully_trusted")
        except TypeError:  # Python < 3.12 has no extraction filter.
            archive.extractall(dest, members=members)
        return len(members)


def verify_archive(artifact_dir: Path, *, source_sha: str, source_run: str,
                   source_attempt: str, toolchain: str,
                   extract_dir: Path, products_sha256: str = "",
                   controller_sha: str = "") -> dict:
    """Prove the downloaded archive is intact, matching and safe to extract."""
    artifact_dir = Path(artifact_dir)
    _require(artifact_dir.is_dir(),
             f"artifact directory {artifact_dir} does not exist")

    _require(_read_text(artifact_dir / "SOURCE-SHA.txt").strip() == source_sha,
             "SOURCE-SHA.txt does not match the requested source SHA")
    _require(_read_text(artifact_dir / "SOURCE-RUN.txt").strip() == str(source_run),
             "SOURCE-RUN.txt does not match the requested run")
    _require(_read_text(artifact_dir / "SOURCE-ATTEMPT.txt").strip() == str(source_attempt),
             "SOURCE-ATTEMPT.txt does not match the requested attempt")
    # A controller-built host records the commit that ran the recovery workflow
    # next to the application SHA it checked out. The run metadata must equal
    # that commit (verify_metadata) and this file must agree with it.
    recorded_controller = ""
    controller_file = artifact_dir / "CONTROLLER-SHA.txt"
    if controller_file.is_file():
        recorded_controller = controller_file.read_text(encoding="utf-8").strip()
        _require(bool(_FULL_SHA.match(recorded_controller)),
                 "CONTROLLER-SHA.txt is not a full 40-hex lowercase commit")
    if controller_sha:
        _require(recorded_controller == controller_sha,
                 "CONTROLLER-SHA.txt does not match the controller commit bound in the run metadata")
    actual_toolchain = _read_text(artifact_dir / "TOOLCHAIN.txt").replace("\r\n", "\n")
    _require(actual_toolchain == toolchain,
             f"archive toolchain {actual_toolchain!r} does not match the expected {toolchain!r}")

    archive = artifact_dir / "Products.tar.gz"
    _require(archive.is_file(), "Products.tar.gz is missing")
    digest = _sha256(archive)
    embedded = _read_text(artifact_dir / "Products.tar.gz.sha256").split()[0].lower()
    _require(bool(_SHA256.match(embedded)),
             "Products.tar.gz.sha256 is not a SHA-256 digest")
    _require(digest == embedded,
             "Products.tar.gz does not match its embedded SHA-256 digest")
    if products_sha256:
        _require(bool(_SHA256.match(products_sha256)),
                 "pinned Products digest is not a SHA-256 digest")
        _require(digest == products_sha256.lower(),
                 "Products.tar.gz does not match the pinned SHA-256 digest")

    extract_dir = Path(extract_dir)
    entries = safe_extract(archive, extract_dir)
    products_dir = (extract_dir / "Products").resolve()
    _require(products_dir.is_dir(), "archive did not contain a Products directory")

    xctestruns = sorted(path for path in products_dir.glob("*.xctestrun")
                        if path.is_file())
    _require(len(xctestruns) == 1,
             f"archive must contain exactly one xctestrun, found {len(xctestruns)}")
    xctestrun = xctestruns[0].resolve()
    _require(_within(products_dir, xctestrun),
             "xctestrun path escaped the extracted Products directory")

    runners = sorted(path for path in products_dir.rglob("*UITests-Runner.app")
                     if path.is_dir())
    _require(len(runners) == 1 and runners[0].name == "FloeAgentUITests-Runner.app",
             "archive must contain the FloeAgentUITests-Runner.app UITest runner")
    runner = runners[0].resolve()
    _require(_within(products_dir, runner),
             "UITest runner path escaped the extracted Products directory")

    return {
        "xctestrun": str(xctestrun),
        "products_dir": str(products_dir),
        "uitest_runner": str(runner),
        "products_sha256": digest,
        "toolchain": actual_toolchain.strip(),
        "entries": entries,
        "controller_sha": recorded_controller or None,
    }


def _append_output(path: str, key: str, value: str) -> None:
    _require("\n" not in value and "\r" not in value,
             f"refusing to write a multiline {key} to GITHUB_OUTPUT")
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"{key}={value}\n")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", required=True,
                        help="JSON with run, job and artifact provenance")
    parser.add_argument("--artifact-dir", required=True,
                        help="directory containing the downloaded host artifact")
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--source-run", required=True)
    parser.add_argument("--source-attempt", default="1")
    parser.add_argument("--xcode-version", default="27.0")
    parser.add_argument("--xcode-build", default="27A5252f")
    parser.add_argument("--products-sha256", default="",
                        help="optional pinned Products.tar.gz digest")
    parser.add_argument("--extract-dir", required=True)
    parser.add_argument("--report", default="")
    parser.add_argument("--github-output", default="")
    parser.add_argument("--repository", default=TRUSTED_REPOSITORY)
    parser.add_argument("--workflow-path", default=TRUSTED_WORKFLOW_PATH)
    parser.add_argument("--host-job", default=HOST_JOB,
                        help="trusted run job that built and uploaded the host")
    parser.add_argument("--upload-step", default=HOST_UPLOAD_STEP,
                        help="step in that job that uploaded the host")
    parser.add_argument("--retain-step", default=HOST_RETAIN_STEP,
                        help="optional step that retained the host before upload; "
                             "pass an empty string to skip the check")
    parser.add_argument("--artifact-prefix", default="compiled-test-host",
                        help="artifact name prefix; the source SHA is appended")
    parser.add_argument("--controller-sha-binding", action="store_true",
                        help="bind the run head SHA to the controller commit recorded "
                             "in CONTROLLER-SHA.txt instead of requiring head_sha == "
                             "--source-sha (release-recovery workflow runs)")
    parser.add_argument("--source-checkout-step", default="",
                        help="source-checkout step that must have succeeded in the "
                             "controller-bound host job")
    parser.add_argument("--source-verify-step", default="",
                        help="tagged-source verification step that must have succeeded "
                             "in the controller-bound host job")
    args = parser.parse_args(argv)

    toolchain = expected_toolchain(args.xcode_version, args.xcode_build)
    try:
        artifact_dir = Path(args.artifact_dir)
        controller_sha = ""
        if args.controller_sha_binding:
            controller_file = artifact_dir / "CONTROLLER-SHA.txt"
            _require(controller_file.is_file(),
                     "controller binding requires CONTROLLER-SHA.txt in the host artifact")
            controller_sha = controller_file.read_text(encoding="utf-8").strip()
        metadata = json.loads(Path(args.metadata).read_text(encoding="utf-8"))
        provenance = verify_metadata(
            metadata,
            source_sha=args.source_sha,
            source_run=args.source_run,
            source_attempt=args.source_attempt,
            repository=args.repository,
            workflow_path=args.workflow_path,
            host_job=args.host_job,
            upload_step=args.upload_step,
            retain_step=args.retain_step or None,
            artifact_prefix=args.artifact_prefix,
            controller_sha=controller_sha,
            source_checkout_step=args.source_checkout_step or None,
            source_verify_step=args.source_verify_step or None,
        )
        archive = verify_archive(
            artifact_dir,
            source_sha=args.source_sha,
            source_run=args.source_run,
            source_attempt=args.source_attempt,
            toolchain=toolchain,
            extract_dir=Path(args.extract_dir),
            products_sha256=args.products_sha256,
            controller_sha=controller_sha,
        )
    except (HostVerificationError, json.JSONDecodeError, OSError) as error:
        print(f"host verification failed: {error}", file=sys.stderr)
        return 1

    report = {"source": provenance, "archive": archive,
              "toolchain": toolchain.strip()}
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2) + "\n",
                                     encoding="utf-8")
    if args.github_output:
        _append_output(args.github_output, "xctestrun", archive["xctestrun"])
        _append_output(args.github_output, "products_dir", archive["products_dir"])
        _append_output(args.github_output, "host_verification", args.report)
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
