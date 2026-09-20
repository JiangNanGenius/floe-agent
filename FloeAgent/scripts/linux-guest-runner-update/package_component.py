#!/usr/bin/env python3
"""package_component.py — assemble the runner-update component package after
the focused guest protocol check has PASSED.

Produces (under --out, which the caller uploads as a workflow artifact):
  image/manifest.json              new image manifest (write-image-manifest.py)
  <image-zip>                      catalog ZIP: manifest.json + bbl + kernel + disk
                                   + the standalone verified `floe-exec-riscv64`
  SHA512SUMS / SHA256SUMS          over every release asset
  manifest.json                    copy of the image manifest (release asset)
  distribution.json                machine record: pins, base reuse, digests,
                                   runnerArtifact/runnerCapabilities
  RELEASE-NOTES.md / SOURCE-OFFER.md
  linux-guest-runner-relink-<tag>.tar        new runner sources + object + link
                                   commands + constants
  linux-guest-reused-source-references-<tag>.tar  pinned references + fresh
                                   digests of the UNCHANGED base source assets
                                   (not re-uploaded; licenses allow verbatim
                                   redistribution and the base release keeps
                                   serving them), plus the cross-toolchain
                                   version comparison that justifies reusing the
                                   base toolchain-source asset.

Engine artifact contract (LinuxGuestImage in LinuxGuestService.swift):
  * the manifest carries `runnerArtifact` (role/path/sha512/bytes) pointing at
    the standalone runner inside the image directory and ZIP, the exact
    engine-compatible-origin field naming the pinned base image as the
    verified predecessor (values read from the pinned base manifest bytes, so
    existing environment disks upgrade instead of being rejected), and
  * `runnerCapabilities`, the exact CAPS payload the guest answered in this
    run (cross-checked against the runner source constants of the same commit),
    so an environment whose persistent disk still boots an older runner can be
    upgraded in-guest instead of being wiped.

Nothing here creates tags, releases or uploads anything; that is the release
step's job after this record exists.

Required env:
  COMPONENT_TAG IMAGE_ID TARGET_COMMIT RUNNER_VERSION_QUAL RUN_URL REPO SERVER
  BASE_TAG BASE_ZIP BASE_ZIP_BYTES BASE_ZIP_SHA512 BASE_ZIP_SHA256
  BASE_MANIFEST_SHA512 BASE_IMAGE_ID BASE_DISK_SHA512 BASE_DISK_BYTES
  BASE_BBL_SHA512 BASE_KERNEL_SHA512
  BASE_RELEASE_URL BASE_SOURCE_OFFER_URL BASE_ASSET_DIGESTS_JSON
     ({"asset name": {"bytes": n, "sha256": hex}} — unchanged base assets the
      new release references instead of re-uploading)
  REUSED_ASSETS   space-separated asset names taken from the base release
                  verbatim (source bundles whose content is unchanged)
Optional env:
  RUNNER_ARTIFACT_ROLE  explicit JSON role for runnerArtifact; default: derived
                        from the engine's LinuxGuestImageArtifact.Role enum
                        (`runner` when present, else the recorded `disk` compat
                        fallback).
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import time
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_contract  # noqa: E402  (sibling script directory)

RUNNER_MEMBER = "floe-exec-riscv64"
IMAGE_MEMBERS = ("manifest.json", "bbl64.bin", "kernel-riscv64.bin", "disk.img", RUNNER_MEMBER)

failures = []


def ok(message):
    print("OK: %s" % message, flush=True)


def fail(message):
    failures.append(message)
    print("FAIL: %s" % message, flush=True)


def require(condition, message):
    ok(message) if condition else fail(message)
    return bool(condition)


def sha(path, algo):
    digest = hashlib.new(algo)
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha_stream(handle, algo):
    digest = hashlib.new(algo)
    for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--image-dir", required=True, help="prepared bbl/kernel/disk + manifest-base.json")
    parser.add_argument("--runner-out", required=True, help="build_runner.sh output dir")
    parser.add_argument("--protocol-verdict", required=True, help="guest_protocol_check.py assert JSON")
    parser.add_argument("--repo", required=True, help="checkout at the target commit")
    parser.add_argument("--out", required=True)
    parser.add_argument("--injection-log", default=None,
                        help="prepare_image.sh injection log (hashes the runner inside the image)")
    parser.add_argument("--base-toolchain-file", default=None,
                        help="toolchain.txt from the base release's runner-relink asset "
                             "(required when the toolchain-source asset is reused)")
    args = parser.parse_args()

    env = os.environ
    tag = env["COMPONENT_TAG"]
    image_id = env["IMAGE_ID"]
    target = env["TARGET_COMMIT"]
    repo = env["REPO"]
    base_tag = env["BASE_TAG"]
    image_zip_name = "floe-linux-guest-%s.zip" % image_id
    reused_assets = env["REUSED_ASSETS"].split()
    base_digests = json.loads(env["BASE_ASSET_DIGESTS_JSON"])

    os.makedirs(args.out, exist_ok=True)
    image_out = os.path.join(args.out, "image")
    os.makedirs(image_out, exist_ok=True)

    # --- gate on the actual protocol verdict --------------------------------
    with open(args.protocol_verdict, "r", encoding="utf-8") as handle:
        verdict = json.load(handle)
    require(verdict.get("failures") == 0,
            "guest protocol verdict has failures == 0 (%d check(s), %d service ticks)"
            % (len(verdict.get("checks", [])), verdict.get("serviceTicks", 0)))
    require(verdict.get("serviceTicks", 0) >= 2, "detached service really logged to the 9p share")
    caps_payload = (verdict.get("capsPayload") or "").strip()
    caps = pipeline_contract.parse_caps(caps_payload)
    require(caps is not None, "verdict records a verbatim CAPS payload: %r" % caps_payload)
    if failures:
        return 1

    # --- runner binary + source constants -----------------------------------
    runner_bin = os.path.join(args.runner_out, RUNNER_MEMBER)
    runner_obj = os.path.join(args.runner_out, "floe-exec-riscv64.o")
    runner_constants_path = os.path.join(args.runner_out, "runner-constants.txt")
    runner_sha256 = ""
    if require(os.path.isfile(runner_bin), "built runner binary exists"):
        runner_sha256 = sha(runner_bin, "sha256")
        with open(os.path.join(args.runner_out, "runner-sha256.txt")) as handle:
            recorded = handle.read().split()[0]
        require(recorded == runner_sha256, "runner sha256 matches the build record")
    require(os.path.isfile(runner_obj), "relink object exists")

    constants = None
    if require(os.path.isfile(runner_constants_path), "runner-constants.txt exists"):
        with open(runner_constants_path, "r", encoding="utf-8") as handle:
            constants = json.load(handle)
    if constants:
        require(constants.get("protocol") == 3, "runner source constant protocol == 3")
        require(constants.get("max_commands", 0) >= 4, "runner source allows >=4 concurrent commands")
        require(constants.get("max_sessions", 0) >= 2, "runner source allows >=2 concurrent sessions")
        source_caps = pipeline_contract.expected_caps({
            "runner_version": constants.get("runner_version", ""),
            "protocol": constants.get("protocol", 0),
            "max_commands": constants.get("max_commands", 0),
            "max_sessions": constants.get("max_sessions", 0)})
        require(source_caps == caps_payload,
                "guest CAPS payload %r equals the runner source constants %r" % (caps_payload, source_caps))
        require(caps.get("protocol") == 3, "guest CAPS payload says protocol=3")

    # --- engine artifact contract: role, fields, compatible-origin schema ----
    engine_path = os.path.join(args.repo, "FloeAgent/Sources/FloeExecution/Linux/LinuxGuestService.swift")
    runtime_path = os.path.join(args.repo, "FloeAgent/Sources/FloeExecution/Linux/LinuxGuestRuntimeImage.swift")
    role = None
    role_policy = None
    origin_contract = None
    engine_source = ""
    runtime_source = ""
    if require(os.path.isfile(engine_path), "engine LinuxGuestService.swift is in the checkout"):
        with open(engine_path, "r", encoding="utf-8") as handle:
            engine_source = handle.read()
        roles, has_fields = pipeline_contract.engine_runner_contract(engine_source)
        require(has_fields, "engine LinuxGuestImage carries runnerArtifact + runnerCapabilities")
        try:
            role, role_policy, role_reason = pipeline_contract.choose_runner_role(
                roles, env.get("RUNNER_ARTIFACT_ROLE"))
            ok("runnerArtifact role %r (%s): %s" % (role, role_policy, role_reason))
        except ValueError as error:
            fail("runnerArtifact role: %s" % error)
    if require(os.path.isfile(runtime_path), "engine LinuxGuestRuntimeImage.swift is in the checkout"):
        with open(runtime_path, "r", encoding="utf-8") as handle:
            runtime_source = handle.read()
    try:
        origin_contract = pipeline_contract.compatible_origin_contract(
            engine_source, runtime_source, env.get("COMPATIBLE_ORIGIN_FIELD"))
        ok("compatible-origin field %r over %s (%s)"
           % (origin_contract["field"], origin_contract["elementType"],
              json.dumps(origin_contract["keys"])))
    except ValueError as error:
        fail("compatible-origin contract: %s" % error)

    # --- base member reuse gates --------------------------------------------
    checks = (
        ("bbl64.bin", env["BASE_BBL_SHA512"]),
        ("kernel-riscv64.bin", env["BASE_KERNEL_SHA512"]),
        ("manifest-base.json", env["BASE_MANIFEST_SHA512"]),
    )
    for name, want in checks:
        path = os.path.join(args.image_dir, name)
        require(os.path.isfile(path), "prepared image kept %s" % name)
        if os.path.isfile(path):
            require(sha(path, "sha512") == want, "%s sha512 matches the pinned base" % name)
    disk_path = os.path.join(args.image_dir, "disk.img")
    require(os.path.isfile(disk_path), "updated disk.img exists")
    disk_sha512 = sha(disk_path, "sha512")
    require(disk_sha512 != env["BASE_DISK_SHA512"],
            "updated disk.img digest differs from the base (runner really replaced)")

    # The verified predecessor: values taken from the pinned base manifest
    # bytes (whose own sha512 is pinned), not from notes. Existing environment
    # disks come from exactly this image, so the manifest declares it as a
    # compatible origin for the runner-only upgrade.
    predecessor = None
    base_manifest_path = os.path.join(args.image_dir, "manifest-base.json")
    if os.path.isfile(base_manifest_path):
        with open(base_manifest_path, "r", encoding="utf-8") as handle:
            try:
                base_manifest = json.load(handle)
            except ValueError as error:
                base_manifest = None
                fail("base manifest is valid JSON: %s" % error)
        if base_manifest is not None:
            base_disk = next((artifact for artifact in base_manifest.get("artifacts", [])
                              if artifact.get("role") == "disk"), None)
            require(base_manifest.get("id") == env["BASE_IMAGE_ID"],
                    "base manifest id is the pinned predecessor %s" % env["BASE_IMAGE_ID"])
            require(base_disk is not None
                    and base_disk.get("sha512") == env["BASE_DISK_SHA512"]
                    and int(base_disk.get("bytes", -1)) == int(env["BASE_DISK_BYTES"]),
                    "base manifest disk artifact matches the pinned predecessor digest+bytes")
            require(base_manifest.get("id") != image_id,
                    "the new image id differs from the predecessor id")
            predecessor = {"imageID": base_manifest.get("id"),
                           "sha512": base_disk.get("sha512") if base_disk else None,
                           "bytes": int(base_disk["bytes"]) if base_disk else None}
            ok("predecessor origin verified from the pinned base manifest: %s (%d bytes, %s…)"
               % (predecessor["imageID"], predecessor["bytes"], (predecessor["sha512"] or "")[:16]))

    # The standalone runner inside the image directory (and ZIP): existing
    # writable disks upgrade from exactly these bytes.
    runner_in_image = os.path.join(args.image_dir, RUNNER_MEMBER)
    runner_sha512 = runner_bytes = None
    if os.path.isfile(runner_bin):
        with open(runner_bin, "rb") as src, open(runner_in_image, "wb") as dst:
            dst.write(src.read())
        runner_sha512 = sha(runner_in_image, "sha512")
        runner_bytes = os.path.getsize(runner_in_image)
        ok("standalone runner staged as %s (%d bytes, sha512 %s…)"
           % (RUNNER_MEMBER, runner_bytes, runner_sha512[:16]))
        if args.injection_log:
            if require(os.path.isfile(args.injection_log), "runner injection log exists"):
                log_text = open(args.injection_log, "r", errors="replace").read()
                require("installed:" in log_text, "injection log reports the install step")
                require(runner_sha256 in log_text,
                        "injection log records the built runner sha256 (image really got these bytes)")

    if failures:
        print("\npackage: %d failure(s) before manifest writing" % len(failures))
        for failure in failures:
            print("  - %s" % failure)
        return 1

    # --- new manifest via the repo's own writer ------------------------------
    manifest_path = os.path.join(image_out, "manifest.json")
    evidence = ("runner-only update of %s: static protocol-3 runner cross-built from %s, "
                "injected into the pinned base whole-disk ext4 (bbl/kernel/userland byte-identical); "
                "focused guest boot check passed: HELLO/CAPS negotiation, 4-way concurrent EXEC overlap, "
                "targeted TERM (143), legacy 0x03 cancel (130) with channel recovery, 2 concurrent PTYs, "
                "background service control channel. Run %s."
                % (base_tag, target[:12], env["RUN_URL"]))
    cmd = [sys.executable, os.path.join(args.repo, "FloeAgent/LinuxGuest/image/write-image-manifest.py"), "write",
           "--image-dir", args.image_dir, "--out", manifest_path,
           "--id", image_id,
           "--bios", os.path.join(args.image_dir, "bbl64.bin"),
           "--kernel", os.path.join(args.image_dir, "kernel-riscv64.bin"),
           "--disk", disk_path,
           "--cmdline", "console=hvc0 root=/dev/vda rw loglevel=4",
           "--qualified", "--qualification-run", env["RUNNER_VERSION_QUAL"],
           "--qualification-evidence", evidence,
           "--source-url", "%s/%s/releases/tag/%s" % (env["SERVER"], repo, tag),
           "--build-configuration-url", "%s/%s/tree/%s/FloeAgent/scripts/linux-guest-runner-update" % (env["SERVER"], repo, target),
           "--license", ("Floe runner MPL-2.0; guest userland under its own Debian package licenses; "
                         "kernel GPL-2.0; bbl BSD-3-Clause; static glibc LGPL-2.1"),
           "--distribution-allowed"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    print(result.stdout, end="")
    if not require(result.returncode == 0, "write-image-manifest.py wrote the new manifest"):
        print(result.stderr, file=sys.stderr)
        return 1

    # --- add the engine runner upgrade fields (post-process, then re-verify) --
    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    manifest["runnerArtifact"] = {"role": role, "path": RUNNER_MEMBER,
                                  "sha512": runner_sha512, "bytes": runner_bytes}
    manifest["runnerCapabilities"] = caps_payload
    origin_entry = {origin_contract["keys"]["image_id"]: predecessor["imageID"],
                    origin_contract["keys"]["sha512"]: predecessor["sha512"],
                    origin_contract["keys"]["bytes"]: predecessor["bytes"]}
    manifest[origin_contract["field"]] = [origin_entry]
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    with open(os.path.join(args.image_dir, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    ok("manifest carries runnerArtifact (path %s, role %s) + runnerCapabilities %r"
       % (RUNNER_MEMBER, role, caps_payload))
    ok("manifest declares the verified predecessor origin %s.%s=%r"
       % (origin_contract["field"], origin_contract["keys"]["image_id"], predecessor["imageID"]))

    result = subprocess.run([sys.executable, cmd[1], "verify", "--image-dir", args.image_dir,
                             "--manifest", manifest_path], capture_output=True, text=True)
    print(result.stdout, end="")
    require(result.returncode == 0, "write-image-manifest.py verify passes on the final manifest")
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
    if failures:
        print("\npackage: %d failure(s) after manifest writing" % len(failures))
        for failure in failures:
            print("  - %s" % failure)
        return 1

    # --- catalog ZIP (deterministic order, verifies itself on read-back) -----
    zip_path = os.path.join(args.out, image_zip_name)
    sources = {"manifest.json": manifest_path,
               "bbl64.bin": os.path.join(args.image_dir, "bbl64.bin"),
               "kernel-riscv64.bin": os.path.join(args.image_dir, "kernel-riscv64.bin"),
               "disk.img": disk_path,
               RUNNER_MEMBER: runner_in_image}
    with open(zip_path, "wb") as raw:
        with zipfile.ZipFile(raw, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for member in IMAGE_MEMBERS:
                source = sources[member]
                size = os.path.getsize(source)
                info = zipfile.ZipInfo(member, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                info.file_size = size
                with open(source, "rb") as handle:
                    with archive.open(info, "w", force_zip64=(size >= 2 ** 32)) as entry:
                        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
                            entry.write(chunk)
    zip_sha512 = sha(zip_path, "sha512")
    zip_sha256 = sha(zip_path, "sha256")
    zip_bytes = os.path.getsize(zip_path)
    require(zip_sha512 != env["BASE_ZIP_SHA512"] and zip_sha256 != env["BASE_ZIP_SHA256"],
            "new image archive digest differs from the base archive")
    ok("image archive %s: %d bytes" % (image_zip_name, zip_bytes))

    zip_members = []
    with zipfile.ZipFile(zip_path) as archive:
        bad_entry = archive.testzip()
        require(bad_entry is None, "archive CRCs verify on read-back")
        require(archive.namelist() == list(IMAGE_MEMBERS),
                "archive members are exactly %s" % (list(IMAGE_MEMBERS),))
        for member in IMAGE_MEMBERS:
            with archive.open(member) as handle:
                digest = sha_stream(handle, "sha512")
            info = archive.getinfo(member)
            want = sha(sources[member], "sha512")
            require(digest == want, "archive member %s sha512 matches the packaged file" % member)
            zip_members.append({"name": member, "bytes": info.file_size, "sha512": digest})
    require(any(m["name"] == RUNNER_MEMBER and m["sha512"] == runner_sha512 and m["bytes"] == runner_bytes
                for m in zip_members),
            "archive carries the standalone runner at runnerArtifact.path with the declared digest")
    # The app imports archives with LinuxGuestImageImportLimits.standard:
    # <=128 entries and <=4 GiB of extracted bytes. Fail here rather than at
    # import time on a user's device.
    require(len(zip_members) <= 128, "archive entries stay within the app import limit (128)")
    extracted = sum(member["bytes"] for member in zip_members)
    require(extracted < 4 * 1024 ** 3,
            "extracted archive bytes stay within the app import limit (4 GiB): %d" % extracted)

    # --- relink tarball (new runner LGPL-2.1 §6 material) --------------------
    relink_name = "linux-guest-runner-relink-%s.tar" % tag
    relink_path = os.path.join(args.out, relink_name)
    runner_dir = os.path.join(args.repo, "FloeAgent/LinuxGuest/runner")
    relink_md = ("# Relink material (LGPL-2.1 §6)\n\n"
                 "The shipped runner `floe-exec-riscv64` (sha256 %s) is statically linked against glibc.\n"
                 "This archive carries the complete runner source (MPL-2.0), the relocatable object\n"
                 "`floe-exec-riscv64.o`, the exact link command in `toolchain.txt`, the protocol/limit\n"
                 "constants in `runner-constants.txt`, and the digest that names the standalone runner\n"
                 "inside the image archive, so the runner can be relinked against a modified glibc. The\n"
                 "corresponding glibc/toolchain source is the Ubuntu cross toolchain recorded in\n"
                 "`toolchain.txt`; its source is distributed by the base component release %s (toolchain\n"
                 "source asset, referenced verbatim by this update after the version comparison in the\n"
                 "reused-source references — see SOURCE-OFFER.md) because the toolchain packages are\n"
                 "unchanged.\n"
                 % (runner_sha256, base_tag))
    staging = os.path.join(args.out, ".relink-staging")
    os.makedirs(staging, exist_ok=True)
    for source, dest in ((os.path.join(runner_dir, "floe_exec.c"), "floe_exec.c"),
                         (os.path.join(runner_dir, "floe_clock.h"), "floe_clock.h"),
                         (os.path.join(runner_dir, "Makefile"), "Makefile"),
                         (runner_obj, "floe-exec-riscv64.o"),
                         (os.path.join(args.runner_out, "toolchain.txt"), "toolchain.txt"),
                         (os.path.join(args.runner_out, "runner-source-sha256.txt"), "runner-source-sha256.txt"),
                         (runner_constants_path, "runner-constants.txt")):
        with open(source, "rb") as src, open(os.path.join(staging, dest), "wb") as dst:
            dst.write(src.read())
    with open(os.path.join(staging, "RELINK.md"), "w", encoding="utf-8") as handle:
        handle.write(relink_md)
    with tarfile.open(relink_path, "w") as tar:
        for name in sorted(os.listdir(staging)):
            tar.add(os.path.join(staging, name), arcname=name)
    ok("relink archive %s" % relink_name)

    # --- reused-source references (fresh API digests, no re-upload) ----------
    ref_name = "linux-guest-reused-source-references-%s.tar" % tag
    ref_path = os.path.join(args.out, ref_name)
    record = {
        "schema": "floe-linux-guest-reused-source-references/v1",
        "recordedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "baseRelease": {"tag": base_tag, "url": env["BASE_RELEASE_URL"]},
        "reason": ("the runner update changes only floe_exec.c/floe_clock.h/Makefile output; the Linux "
                   "kernel, bbl, Debian userland and cross toolchain are byte-identical to the base "
                   "component, so their corresponding-source assets are served by the base release "
                   "(MPL-2.0/GPL-2.0/LGPL-2.1/BSD-3-Clause all permit verbatim redistribution; the base "
                   "release remains published). Digests below were re-fetched from the GitHub API at "
                   "package time, not copied from old notes. The toolchain reuse is additionally bound to "
                   "the version comparison recorded here; without a match this packaging fails instead of "
                   "claiming coverage it cannot show."),
        "assets": {},
    }
    toolchain_comparison = None
    if any("toolchain-source" in name for name in reused_assets):
        if require(bool(args.base_toolchain_file) and os.path.isfile(args.base_toolchain_file),
                   "base toolchain record provided for the reused toolchain-source asset"):
            with open(args.base_toolchain_file, "r", errors="replace") as handle:
                base_toolchain_text = handle.read()
            with open(os.path.join(args.runner_out, "toolchain-versions.txt"), "r", errors="replace") as handle:
                new_versions_text = handle.read()
            with open(os.path.join(args.runner_out, "toolchain.txt"), "r", errors="replace") as handle:
                new_toolchain_text = handle.read()
            base_packages = pipeline_contract.binary_packages(base_toolchain_text)
            base_toolchain_packages = pipeline_contract.toolchain_packages(base_toolchain_text)
            gaps = pipeline_contract.toolchain_record_gaps(base_toolchain_text, new_versions_text)
            gaps += pipeline_contract.toolchain_gaps(base_toolchain_text, new_toolchain_text)
            require(len(base_packages) + len(base_toolchain_packages) > 0,
                    "base toolchain record names the packages it covers")
            require(not gaps,
                    "every base cross-toolchain package keeps its exact version in this run (%d binary, %d metapackage)"
                    % (len(base_packages), len(base_toolchain_packages)))
            toolchain_comparison = {
                "baseRecord": {"url": "%s/%s/releases/download/%s/linux-guest-runner-relink-35503144437.tar"
                                      % (env["SERVER"], repo, base_tag),
                               "file": os.path.basename(args.base_toolchain_file),
                               "sha256": sha(args.base_toolchain_file, "sha256")},
                "binaryPackages": base_packages, "packages": base_toolchain_packages, "gaps": gaps,
            }
            ok("cross toolchain matches the base record for %d binary package(s)"
               % len(base_packages))
    for name in reused_assets:
        pin = base_digests.get(name)
        if not require(pin is not None, "base asset %s has a fresh pinned digest" % name):
            continue
        record["assets"][name] = {
            "url": "%s/%s/releases/download/%s/%s" % (env["SERVER"], repo, base_tag, name),
            "bytes": pin["bytes"], "sha256": pin["sha256"],
        }
        ok("reused source asset %s (sha256 %s…)" % (name, pin["sha256"][:16]))
    record["toolchainComparison"] = toolchain_comparison
    source_offer_url = "%s/%s/releases/download/%s/SOURCE-OFFER.md" % (env["SERVER"], repo, base_tag)
    staging2 = os.path.join(args.out, ".ref-staging")
    os.makedirs(staging2, exist_ok=True)
    with open(os.path.join(staging2, "REUSED-SOURCES.json"), "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
        handle.write("\n")
    with open(os.path.join(staging2, "REUSED-SOURCES.md"), "w", encoding="utf-8") as handle:
        handle.write("# Reused corresponding-source assets (base %s)\n\n" % base_tag)
        handle.write("This runner update replaces only the guest runner binary. The unchanged upstream,\n"
                     "Debian, toolchain and base relink/source-evidence assets are served by the published\n"
                     "base release; their digests below were verified against the GitHub API when this\n"
                     "package was assembled. The base license/offer document applies: %s\n\n" % source_offer_url)
        for name in reused_assets:
            pin = base_digests[name]
            handle.write("- `%s` — %d bytes, sha256 `%s`\n  %s/%s/releases/download/%s/%s\n"
                         % (name, pin["bytes"], pin["sha256"], env["SERVER"], repo, base_tag, name))
        if toolchain_comparison:
            handle.write("\n## Cross-toolchain correspondence\n\n"
                         "Every package listed below keeps its exact version in the update run, so the base\n"
                         "toolchain-source asset still covers the statically linked runner:\n\n")
            for name, entry in sorted(toolchain_comparison["binaryPackages"].items()):
                handle.write("- `%s` %s (source `%s` %s)\n"
                             % (name, entry["version"], entry["source"], entry["source_version"]))
            for name, version in sorted(toolchain_comparison["packages"].items()):
                handle.write("- `%s` %s\n" % (name, version))
    tar_members = ["REUSED-SOURCES.json", "REUSED-SOURCES.md"]
    if toolchain_comparison:
        with open(os.path.join(staging2, "toolchain-comparison.txt"), "w", encoding="utf-8") as handle:
            for name, entry in sorted(toolchain_comparison["binaryPackages"].items()):
                handle.write("match %s %s source %s %s\n"
                             % (name, entry["version"], entry["source"], entry["source_version"]))
            for name, version in sorted(toolchain_comparison["packages"].items()):
                handle.write("match %s %s\n" % (name, version))
            handle.write("gaps=%d\n" % len(toolchain_comparison["gaps"]))
        tar_members.append("toolchain-comparison.txt")
    with tarfile.open(ref_path, "w") as tar:
        for member in tar_members:
            tar.add(os.path.join(staging2, member), arcname=member)
    ok("reused-source references %s" % ref_name)

    # --- notes / offer / sums -------------------------------------------------
    assets = [image_zip_name, relink_name, ref_name, "manifest.json", "SHA512SUMS", "SHA256SUMS",
              "distribution.json", "RELEASE-NOTES.md", "SOURCE-OFFER.md"]
    with open(manifest_path, "rb") as src, open(os.path.join(args.out, "manifest.json"), "wb") as dst:
        dst.write(src.read())

    notes = ("<!-- floe-linux-guest-runner-update:v1 -->\n"
             "# Floe Linux guest runner update %s (component release)\n\n"
             "Draft component release for the Floe Linux RISC-V guest image `%s` (**not published**).\n"
             "Created by `.github/workflows/linux-guest-runner-update.yml` (run %s).\n\n"
             "This is a **runner-only update** of the published base component `%s`: the whole-disk ext4,\n"
             "bbl and kernel are byte-identical to the base; only `/usr/local/bin/floe-exec` was replaced\n"
             "with the protocol-3 runner built from `%s`.\n\n"
             "## Image\n\n- archive: `%s` (%d bytes)\n- archive sha512: `%s`\n- archive sha256: `%s`\n"
             "- standalone runner in the archive: `%s` (%d bytes, sha512 `%s`)\n"
             "- runner capabilities: `%s`\n"
             "- manifest fields `runnerArtifact` (role `%s`) + `runnerCapabilities`: present, so an\n"
             "  environment whose persistent disk still boots an older runner upgrades in-guest from these\n"
             "  verified bytes instead of being wiped\n"
             "- verified predecessor origin: `%s` declares `%s` (disk sha512 `%s`, %d bytes) as the\n"
             "  compatible runner-only origin, taken from the pinned base manifest bytes\n"
             "- cmdline: `console=hvc0 root=/dev/vda rw loglevel=4`\n\n"
             "## Focused qualification (actual guest boot, this run)\n\n"
             "HELLO/CAPS protocol-3 negotiation; 4-way concurrent EXEC with a real 9p overlap barrier;\n"
             "targeted SIGNAL TERM (exit 143); legacy 0x03 interrupt-all (exit 130 x2) with immediate\n"
             "channel recovery; two concurrent PTY sessions with per-token input; background service\n"
             "SPAWN/PID plus honest END 3 for unknown ALIVE/KILL pids; detached service logging to the 9p\n"
             "share (%d ticks). Verdict JSON: `failures=0` over %d checks.\n\n"
             "Release state: **draft** (`draft: true`, `latest: false`, tag does not start with `v`).\n"
             % (image_id, image_id, env["GITHUB_RUN_ID"], base_tag, target, image_zip_name, zip_bytes,
                zip_sha512, zip_sha256, RUNNER_MEMBER, runner_bytes, runner_sha512, caps_payload, role,
                origin_contract["field"], predecessor["imageID"], predecessor["sha512"],
                predecessor["bytes"], verdict.get("serviceTicks", 0),
                len(verdict.get("checks", []))))
    with open(os.path.join(args.out, "RELEASE-NOTES.md"), "w", encoding="utf-8") as handle:
        handle.write(notes)

    offer = ("# Corresponding source offer — Floe Linux guest runner update `%s`\n\n"
             "## License mapping\n\n"
             "| Component | License | Source |\n| --- | --- | --- |\n"
             "| Floe runner (new, protocol 3) | MPL-2.0 | `%s` in this release + `%s` inside the image archive |\n"
             "| glibc (statically linked into the runner) | LGPL-2.1 | relink object + link command in `%s`; "
             "toolchain source served by base release %s (unchanged packages, version comparison in `%s`) |\n"
             "| Linux kernel 4.15 (riscv-linux) | GPL-2.0 | base release upstream asset (unchanged, referenced) |\n"
             "| riscv-pk / bbl | BSD-3-Clause | base release upstream asset (unchanged, referenced) |\n"
             "| Debian userland packages | per package | base release Debian source assets (unchanged, referenced) |\n\n"
             "## What changed vs the base\n\n"
             "Only the runner (`floe_exec.c`, `floe_clock.h`, `Makefile` output). Every other binary in the\n"
             "image is byte-identical to the published base `%s` (whose manifest is a reused, pinned member);\n"
             "the manifest declares `%s` -> `%s` as the verified compatible origin so existing environment\n"
             "disks keep their installed packages. The reused-source archive `%s` carries the\n"
             "base asset URLs plus the digests re-verified at package time. No zero-gap claim is made beyond\n"
             "those verified digests and the recorded cross-toolchain version comparison.\n\n"
             "## Relink (LGPL-2.1 §6)\n\n"
             "`%s` carries `floe_exec.c`, `floe_clock.h`, `Makefile`, the relocatable object, the exact link\n"
             "command (`toolchain.txt`), the runner constants (`runner-constants.txt`) and `RELINK.md`.\n"
             % (image_id, relink_name, RUNNER_MEMBER, relink_name, base_tag, ref_name,
                origin_contract["field"], predecessor["imageID"], base_tag, ref_name, relink_name))
    with open(os.path.join(args.out, "SOURCE-OFFER.md"), "w", encoding="utf-8") as handle:
        handle.write(offer)

    distribution = {
        "schema": "floe-linux-guest-runner-update-distribution/v1",
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "repository": repo,
        "componentTag": tag,
        "targetCommit": target,
        "workflowRun": env["GITHUB_RUN_ID"],
        "runUrl": env["RUN_URL"],
        "base": {"tag": base_tag, "zip": env["BASE_ZIP"], "zipBytes": int(env["BASE_ZIP_BYTES"]),
                 "zipSha512": env["BASE_ZIP_SHA512"], "zipSha256": env["BASE_ZIP_SHA256"],
                 "reusedMembers": {"bbl64.bin": env["BASE_BBL_SHA512"],
                                   "kernel-riscv64.bin": env["BASE_KERNEL_SHA512"],
                                   "manifest-base.json": env["BASE_MANIFEST_SHA512"]}},
        "image": {"id": image_id, "archive": image_zip_name, "bytes": zip_bytes,
                  "sha512": zip_sha512, "sha256": zip_sha256,
                  "diskSha512": disk_sha512, "baseDiskSha512": env["BASE_DISK_SHA512"],
                  "members": zip_members},
        "runnerArtifact": {"path": RUNNER_MEMBER, "role": role, "rolePolicy": role_policy,
                           "sha512": runner_sha512, "bytes": runner_bytes,
                           "binarySha256": runner_sha256, "sourceCommit": target},
        "runnerCapabilities": caps_payload,
        "predecessorOrigin": {"field": origin_contract["field"],
                              "keys": origin_contract["keys"],
                              "entry": origin_entry},
        "runnerConstants": constants,
        "protocolCheck": {"failures": verdict.get("failures"), "checks": len(verdict.get("checks", [])),
                          "serviceTicks": verdict.get("serviceTicks"),
                          "capsPayload": caps_payload},
        "reusedSourceAssets": record["assets"],
        "toolchainComparison": toolchain_comparison,
        "assets": assets,
    }
    with open(os.path.join(args.out, "distribution.json"), "w", encoding="utf-8") as handle:
        json.dump(distribution, handle, indent=2)
        handle.write("\n")

    # SHA512SUMS covers the payload assets; SHA256SUMS is written afterwards
    # and also covers SHA512SUMS (the base release's convention).
    sha512_names = sorted(name for name in assets if name not in ("SHA512SUMS", "SHA256SUMS"))
    with open(os.path.join(args.out, "SHA512SUMS"), "w", encoding="utf-8") as handle:
        for name in sha512_names:
            path = os.path.join(args.out, name)
            if os.path.isfile(path):
                handle.write("%s  %s\n" % (sha(path, "sha512"), name))
    with open(os.path.join(args.out, "SHA256SUMS"), "w", encoding="utf-8") as handle:
        for name in sorted(a for a in assets if a != "SHA256SUMS"):
            path = os.path.join(args.out, name)
            if os.path.isfile(path):
                handle.write("%s  %s\n" % (sha(path, "sha256"), name))

    # final integrity pass over what the release step will upload.
    with open(os.path.join(args.out, "manifest.json"), "rb") as root_manifest:
        root_bytes = root_manifest.read()
    with zipfile.ZipFile(zip_path) as archive:
        with archive.open("manifest.json") as member:
            require(member.read() == root_bytes, "release manifest.json equals the archive member")
    for name in assets:
        path = os.path.join(args.out, name)
        if require(os.path.isfile(path), "release asset %s exists" % name) and name not in ("SHA512SUMS", "SHA256SUMS"):
            require(os.path.getsize(path) > 0, "release asset %s is non-empty" % name)

    print("\npackage: %d failure(s)" % len(failures))
    for failure in failures:
        print("  - %s" % failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
