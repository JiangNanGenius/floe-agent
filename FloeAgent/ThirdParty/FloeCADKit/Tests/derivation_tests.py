#!/usr/bin/env python3
"""Hermetic tests for the derivation-aware OCCT bootstrap contract.

These tests never compile OCCT, run ranlib on the real slices, touch the real
Vendor files, or use the network.  They build tiny synthetic BSD ar fixtures,
inject a fake object producer/ranlib index provider, and exercise the real
``bootstrap.py``, ``derivation_common.py`` and ``derive_standard_type_slice.py``
paths.

Run:
    python3 Tests/derivation_tests.py
    python3 Tests/bootstrap_tests.py       # legacy guarantees, unchanged
"""

import contextlib
import copy
import hashlib
import importlib.util
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import unittest.mock

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE = os.path.dirname(HERE)
DERIVATIONS = os.path.join(PACKAGE, "relink", "derivations")
sys.path.insert(0, DERIVATIONS)

import derivation_common as dc  # noqa: E402
import derive_standard_type_slice as dv  # noqa: E402
import occt_archive as oa  # noqa: E402

BOOTSTRAP_PATH = os.path.join(PACKAGE, "bootstrap.py")


def _load_bootstrap():
    spec = importlib.util.spec_from_file_location("floecad_bootstrap", BOOTSTRAP_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bs = _load_bootstrap()

TARGET = "Standard_Type.cxx.o"
INDEX = "__.SYMDEF"
INSTALL_PATH = "Vendor/OCCT.xcframework/ios-arm64-simulator/libOCCT-SIMULATORARM64.a"

QUALIFIED_TOOLCHAIN = {
    "xcodeVersion": "27.1",
    "xcodeBuild": "27A9275",
    "sdkVersion": "27.1",
    "sdkName": "iphonesimulator",
    "sdkPath": "/fake/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.1.sdk",
    "clangVersion": "Apple clang version 21.0.0 (clang-2100.3.34.2)",
    "target": "arm64-apple-ios16.0-simulator",
    "compileFlags": ["-std=c++17", "-O3"],
    "versionMinFlag": "-mios-simulator-version-min=16.0",
    "commandTemplate": ["<CLANGXX>", "-target", "arm64-apple-ios16.0-simulator"],
}
UNQUALIFIED_TOOLCHAIN = dict(
    QUALIFIED_TOOLCHAIN,
    xcodeVersion="26.6",
    xcodeBuild="17F0000",
    sdkVersion="26.6",
    sdkPath="/fake/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.6.sdk",
    clangVersion="Apple clang version 20.0.0",
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def version_encoded(text):
    parts = [int(part) for part in text.split(".")] + [0, 0]
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def fake_macho(platform_name, minos, sdk):
    platform = {"IOS": 2, "IOSSIMULATOR": 7}[platform_name]
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 1, 1, 24, 0, 0)
    command = struct.pack("<IIIIII", 0x32, 24, platform, version_encoded(minos),
                          version_encoded(sdk), 0)
    return header + command


def _record(name, payload):
    name_bytes = name.encode("ascii")
    name_len = len(name_bytes) + 1
    name_field = ("#1/%d" % name_len).ljust(16).encode("ascii")
    data = name_bytes.ljust(name_len, b"\x00") + payload
    header = (
        name_field
        + b"0".ljust(12)
        + b"0".ljust(6)
        + b"0".ljust(6)
        + b"100644".ljust(8)
        + str(len(data)).encode("ascii").ljust(10)
        + b"`\n"
    )
    return header + data + (b"\n" if len(data) % 2 else b"")


def write_archive(path, members):
    with open(path, "wb") as handle:
        handle.write(b"!<arch>\n")
        handle.write(_record(INDEX, struct.pack("<II", 0, 0)))
        for name, payload in members:
            handle.write(_record(name, payload))


class Fixture:
    """A temporary FloeCADKit-shaped package with one derived artifact."""

    def __init__(self, toolchain=None, object_mutator=None, symbol_mutator=None,
                 schema=2):
        self.root = tempfile.mkdtemp(prefix="floe-derivation-test-")
        self.toolchain = dict(toolchain or QUALIFIED_TOOLCHAIN)
        self.object_mutator = object_mutator
        self.symbol_mutator = symbol_mutator
        self.derivations = os.path.join(self.root, "relink", "derivations")
        os.makedirs(self.derivations)
        os.makedirs(os.path.dirname(os.path.join(self.root, INSTALL_PATH)))
        os.makedirs(os.path.join(self.root, "Vendor", "Headers"))
        self.base_path = os.path.join(self.root, INSTALL_PATH)
        self.base_members_input = [
            ("Alpha.cxx.o", b"A" * 100),
            (TARGET, b"BASE" * 50),
            ("Beta.cxx.o", b"B" * 101),
        ]
        write_archive(self.base_path, self.base_members_input)
        self.base_bytes = open(self.base_path, "rb").read()
        self.base_members = oa.read_archive(self.base_path)
        summary = oa.archive_summary(self.base_members, TARGET)

        def source(relative, data):
            path = os.path.join(self.root, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(data)
            return {"path": relative, "size": len(data), "sha256": sha256(data)}

        self.base_source = source("relink/derivations/fixture-base.cxx", b"// base\n")
        self.overlay_source = source("relink/derivations/fixture-overlay.cxx",
                                     b"// overlay\n")
        self.patch = source("relink/derivations/fixture.patch", b"patch fixture\n")

        template_path = os.path.join(DERIVATIONS, "standard-type-lifetime.v1.json")
        recipe = copy.deepcopy(json.load(open(template_path, encoding="utf-8")))
        recipe["occt"]["baseSource"] = self.base_source
        recipe["occt"]["overlaySource"] = self.overlay_source
        recipe["occt"]["patch"] = self.patch
        public_symbols = [
            "__ZN13Standard_Type19get_type_descriptorEv",
            "__ZTI13Standard_Type",
            "__ZTV13Standard_Type",
        ]
        recipe["member"] = {
            "name": TARGET,
            "publicSymbolPattern": "^(__ZN13Standard_Type|__ZNK13Standard_Type|__ZT[ISV]13Standard_Type$)",
            "expectedPublicSymbols": public_symbols,
            "expectedPublicSymbolsSha256": sha256(
                ("\n".join(sorted(public_symbols)) + "\n").encode()
            ),
        }
        recipe["build"]["headersPath"] = "Vendor/Headers"
        recipe["build"].pop("headersTreeSha256", None)
        recipe["build"].pop("headersTreeAlgorithm", None)
        recipe["build"].pop("headersFileCount", None)
        recipe["build"]["compileFlags"] = ["-std=c++17", "-O3"]
        recipe["qualifiedToolchain"] = {
            "xcodeVersion": "27.1",
            "xcodeBuild": "27A9275",
            "sdkVersion": "27.1",
        }
        recipe["limitations"] = ["synthetic test fixture; no native compile"]
        recipe["slices"] = {
            "simulator": {
                "installPath": INSTALL_PATH,
                "baseSize": len(self.base_bytes),
                "baseSha256": sha256(self.base_bytes),
                "baseMemberCount": summary["memberCount"],
                "baseMemberOrderSha256": summary["memberOrderSha256"],
                "baseNonTargetMembersDigestSha256": summary["nonTargetMembersDigestSha256"],
                "baseIndexMemberSize": summary["indexMemberSize"],
                "baseIndexPayloadSize": summary["indexPayloadSize"],
                "baseIndexPayloadSha256": summary["indexPayloadSha256"],
                "baseTargetPayloadSize": summary["targetPayloadSize"],
                "baseTargetPayloadSha256": summary["targetPayloadSha256"],
                "arch": "arm64",
                "machoPlatform": "IOSSIMULATOR",
                "minos": "16.0",
                "target": "arm64-apple-ios16.0-simulator",
                "sdk": "iphonesimulator",
                "versionMinFlag": "-mios-simulator-version-min=16.0",
                "sdkVersionAtBaseBuild": "27.1",
            }
        }
        self.recipe = recipe
        self.recipe_path = os.path.join(self.derivations, "fixture-recipe.json")
        self.write_recipe(recipe)
        self.receipt_path = self.base_path + ".derivation.json"
        self.manifest = {
            "schemaVersion": schema,
            "artifacts": [{
                "name": "fixture slice",
                "installPath": INSTALL_PATH,
                "size": len(self.base_bytes),
                "sha256": sha256(self.base_bytes),
                "source": {
                    "kind": "git-lfs",
                    "sourceId": "src",
                    "upstreamPath": "ThirdParty/fixture.a",
                    "oid": sha256(self.base_bytes),
                },
                "derivation": {
                    "id": recipe["id"],
                    "recipe": "relink/derivations/fixture-recipe.json",
                    "recipeSha256": sha256(open(self.recipe_path, "rb").read()),
                    "receiptPath": INSTALL_PATH + ".derivation.json",
                },
            }],
            "sources": {
                "src": {
                    "kind": "git-lfs",
                    "lfsBatchApi": "http://127.0.0.1:1/batch",
                    "lfsTransfer": "basic",
                }
            },
        }
        self.write_manifest()
        self.fetched = []
        self.derive_calls = 0
        self.object_tag = b"OBJECT-V1"

    def write_recipe(self, recipe):
        with open(self.recipe_path, "w", encoding="utf-8") as handle:
            json.dump(recipe, handle, indent=2, sort_keys=True)

    def rewrite_recipe_hash(self):
        self.manifest["artifacts"][0]["derivation"]["recipeSha256"] = sha256(
            open(self.recipe_path, "rb").read()
        )
        self.write_manifest()

    def write_manifest(self):
        with open(os.path.join(self.root, "DEPENDENCIES.json"), "w",
                  encoding="utf-8") as handle:
            json.dump(self.manifest, handle, indent=2, sort_keys=True)

    def set_expected_result(self, size, result_sha):
        self.manifest["artifacts"][0]["derivation"]["expectedResult"] = {
            "size": size, "sha256": result_sha,
        }
        self.write_manifest()

    def install(self, payload=None):
        with open(self.base_path, "wb") as handle:
            handle.write(self.base_bytes if payload is None else payload)

    def object_bytes(self, toolchain=None):
        active = toolchain or self.toolchain
        data = fake_macho("IOSSIMULATOR", "16.0", active["sdkVersion"])
        if self.object_mutator:
            data = self.object_mutator(data)
        return data

    def symbols(self, base=False):
        data = {
            "defined": [
                "__ZN13Standard_Type19get_type_descriptorEv",
                "__ZTI13Standard_Type",
                "__ZTV13Standard_Type",
                "_extra",
            ],
            "undefined": ["_undef"],
        }
        if self.symbol_mutator and not base:
            data = self.symbol_mutator(data)
        return data

    def _lister(self, path):
        return self.symbols(base=os.path.basename(path).startswith(".base-"))

    def _producer(self, package_root, recipe, slice_cfg, overlay, workdir,
                  toolchain, paths):
        path = os.path.join(workdir, "Standard_Type.cxx.o")
        with open(path, "wb") as handle:
            handle.write(self.object_bytes(toolchain))
        return path, ["<CLANGXX>"], ""

    def _index_provider(self, indexless_path):
        return struct.pack("<II", 0, 0)

    def derive_to_temp(self, toolchain=None, output_name="fixture-derived.a",
                       object_tag=None):
        old_tag = self.object_tag
        if object_tag is not None:
            self.object_tag = object_tag
        try:
            output = os.path.join(self.root, output_name)
            receipt = output + ".json"
            dv.derive_slice(
                self.root, self.recipe_path, "simulator", self.base_path,
                output, receipt,
                recipe_sha256=sha256(open(self.recipe_path, "rb").read()),
                toolchain=dict(toolchain or self.toolchain),
                tool_paths={"ranlib": "/usr/bin/ranlib", "nm": "/usr/bin/nm"},
                object_producer=self._producer,
                symbol_lister=self._lister,
                index_provider=self._index_provider,
                timeout=30,
                produced_at="2026-11-01T00:00:00Z",
            )
            return output, receipt
        finally:
            self.object_tag = old_tag

    def fake_run(self, root, art, recipe, slice_name, base_path, output_path,
                 receipt_path, log):
        self.derive_calls += 1
        dv.derive_slice(
            self.root, recipe["_path"], slice_name, base_path, output_path,
            receipt_path, recipe_sha256=recipe["_sha256"],
            toolchain=dict(self.toolchain),
            tool_paths={"ranlib": "/usr/bin/ranlib", "nm": "/usr/bin/nm"},
            object_producer=self._producer,
            symbol_lister=self._lister,
            index_provider=self._index_provider,
            timeout=30,
            produced_at="2026-11-01T00:00:00Z",
        )

    def fake_fetch(self, dest_dir, art, source, deadline, log):
        log("fetch  %s verified base (fixture)" % art.get("name"))
        os.makedirs(dest_dir, exist_ok=True)
        handle, path = tempfile.mkstemp(prefix=".floecad-base-test-", suffix=".a",
                                        dir=dest_dir)
        os.close(handle)
        with open(path, "wb") as out:
            out.write(self.base_bytes)
        self.fetched.append(path)
        return path

    def run(self, **kwargs):
        logs = []
        kwargs.setdefault("log", logs.append)
        kwargs.setdefault("offline", False)
        rc = bs.run(self.root, **kwargs)
        return rc, logs

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


class FixtureTestCase(unittest.TestCase):
    fixture_kwargs = {}

    def setUp(self):
        self.fixture = Fixture(**self.fixture_kwargs)
        self.addCleanup(self.fixture.close)

    @contextlib.contextmanager
    def patched(self, run=None, fetch=None):
        with unittest.mock.patch.object(
                bs, "_run_derive_tool", run or self.fixture.fake_run), \
                unittest.mock.patch.object(
                    bs, "_fetch_verified_temp", fetch or self.fixture.fake_fetch):
            yield

    def prepare(self):
        with self.patched():
            return self.fixture.run(check=False)


class TestManifestSchema(unittest.TestCase):
    def test_xcrun_selects_xcode_without_assuming_a_bundled_dispatcher(self):
        developer = "/Applications/Selected Xcode.app/Contents/Developer"
        previous = os.environ.get("DEVELOPER_DIR")
        completed = subprocess.CompletedProcess([], 0, b"/selected/sdk\n", b"")
        with unittest.mock.patch.object(dv.shutil, "which", return_value="/usr/bin/xcrun"), \
                unittest.mock.patch.object(dv, "_run", return_value=completed) as run:
            result = dv._xcrun(developer, ["--sdk", "iphoneos", "--show-sdk-path"])
        self.assertEqual(result, "/selected/sdk")
        self.assertEqual(run.call_args.args[0],
                         ["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-path"])
        self.assertEqual(run.call_args.kwargs["env"]["DEVELOPER_DIR"], developer)
        self.assertEqual(os.environ.get("DEVELOPER_DIR"), previous)

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)

    def test_schema1_legacy_manifest_is_accepted(self):
        legacy = copy.deepcopy(self.fixture.manifest)
        legacy["schemaVersion"] = 1
        legacy["artifacts"][0].pop("derivation")
        path = os.path.join(self.fixture.root, "DEPENDENCIES.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(legacy, handle)
        self.assertEqual(bs.load_manifest(self.fixture.root)["schemaVersion"], 1)

    def test_schema1_with_derivation_is_refused(self):
        self.fixture.manifest["schemaVersion"] = 1
        self.fixture.write_manifest()
        with self.assertRaises(bs.ManifestError):
            bs.load_manifest(self.fixture.root)

    def test_future_schema_is_refused(self):
        self.fixture.manifest["schemaVersion"] = 3
        self.fixture.write_manifest()
        with self.assertRaises(bs.ManifestError):
            bs.load_manifest(self.fixture.root)

    def test_invalid_expected_result_is_refused(self):
        for value in ({"size": -1, "sha256": "0" * 64},
                      {"size": 1, "sha256": "nothex"},
                      {"size": True, "sha256": "0" * 64}):
            self.fixture.manifest["artifacts"][0]["derivation"]["expectedResult"] = value
            self.fixture.write_manifest()
            with self.subTest(value=value):
                with self.assertRaises(bs.ManifestError):
                    bs.load_manifest(self.fixture.root)

    def test_absolute_recipe_path_is_refused(self):
        self.fixture.manifest["artifacts"][0]["derivation"]["recipe"] = "/tmp/recipe.json"
        self.fixture.write_manifest()
        with self.assertRaises(bs.ManifestError):
            bs.load_manifest(self.fixture.root)


class TestRecipeAndReceipt(FixtureTestCase):
    def test_recipe_hash_mismatch_is_refused(self):
        with self.assertRaises(dc.DerivationError):
            dc.load_recipe(self.fixture.recipe_path, "0" * 64, self.fixture.recipe["id"])

    def test_recipe_id_mismatch_is_refused(self):
        with self.assertRaises(dc.DerivationError):
            dc.load_recipe(self.fixture.recipe_path,
                           sha256(open(self.fixture.recipe_path, "rb").read()),
                           "another-derivation")

    def test_valid_receipt_and_archive(self):
        output, receipt_path = self.fixture.derive_to_temp()
        loaded = dc.load_recipe(
            self.fixture.recipe_path,
            sha256(open(self.fixture.recipe_path, "rb").read()),
            self.fixture.recipe["id"],
        )
        receipt = json.load(open(receipt_path, encoding="utf-8"))
        artifact = self.fixture.manifest["artifacts"][0]
        problems, qualified = dc.validate_receipt(
            loaded, artifact, receipt, os.path.getsize(output),
            oa.sha256_file(output),
        )
        self.assertEqual(problems, [])
        self.assertTrue(qualified)
        archive_problems, summary = dc.verify_installed_archive(
            output, loaded, loaded["slices"]["simulator"], receipt
        )
        self.assertEqual(archive_problems, [])
        self.assertEqual(summary["targetPayloadSha256"],
                         sha256(self.fixture.object_bytes()))

    def test_tampered_result_is_rejected(self):
        output, receipt_path = self.fixture.derive_to_temp()
        loaded = dc.load_recipe(
            self.fixture.recipe_path,
            sha256(open(self.fixture.recipe_path, "rb").read()),
            self.fixture.recipe["id"],
        )
        receipt = json.load(open(receipt_path, encoding="utf-8"))
        receipt["archive"]["sha256"] = "0" * 64
        problems, _ = dc.validate_receipt(
            loaded, self.fixture.manifest["artifacts"][0], receipt,
            os.path.getsize(output), oa.sha256_file(output),
        )
        self.assertTrue(problems)

    def test_tampered_member_and_non_target_digest_are_rejected(self):
        output, receipt_path = self.fixture.derive_to_temp()
        loaded = dc.load_recipe(
            self.fixture.recipe_path,
            sha256(open(self.fixture.recipe_path, "rb").read()),
            self.fixture.recipe["id"],
        )
        receipt = json.load(open(receipt_path, encoding="utf-8"))
        receipt["member"]["derivedPayloadSha256"] = "0" * 64
        receipt["archive"]["nonTargetMembersDigestSha256"] = "0" * 64
        problems, _ = dc.validate_receipt(
            loaded, self.fixture.manifest["artifacts"][0], receipt,
            os.path.getsize(output), oa.sha256_file(output),
        )
        self.assertGreaterEqual(len(problems), 2)
        archive_problems, _ = dc.verify_installed_archive(
            output, loaded, loaded["slices"]["simulator"], receipt
        )
        self.assertGreaterEqual(len(archive_problems), 2)

    def test_test_bypass_receipt_is_rejected(self):
        output, receipt_path = self.fixture.derive_to_temp()
        loaded = dc.load_recipe(
            self.fixture.recipe_path,
            sha256(open(self.fixture.recipe_path, "rb").read()),
            self.fixture.recipe["id"],
        )
        receipt = json.load(open(receipt_path, encoding="utf-8"))
        receipt["testBypass"] = True
        problems, _ = dc.validate_receipt(
            loaded, self.fixture.manifest["artifacts"][0], receipt,
            os.path.getsize(output), oa.sha256_file(output),
        )
        self.assertTrue(any("bypass" in problem for problem in problems))

    def test_unqualified_toolchain_is_recorded_but_not_qualified(self):
        output, receipt_path = self.fixture.derive_to_temp(
            toolchain=UNQUALIFIED_TOOLCHAIN
        )
        loaded = dc.load_recipe(
            self.fixture.recipe_path,
            sha256(open(self.fixture.recipe_path, "rb").read()),
            self.fixture.recipe["id"],
        )
        receipt = json.load(open(receipt_path, encoding="utf-8"))
        problems, qualified = dc.validate_receipt(
            loaded, self.fixture.manifest["artifacts"][0], receipt,
            os.path.getsize(output), oa.sha256_file(output),
        )
        self.assertEqual(problems, [])
        self.assertFalse(qualified)


class TestDerivation(FixtureTestCase):
    def test_end_to_end_derivation(self):
        output, receipt_path = self.fixture.derive_to_temp()
        receipt = json.load(open(receipt_path, encoding="utf-8"))
        self.assertEqual(receipt["approach"], dc.APPROACH)
        self.assertEqual(receipt["artifact"]["resultSha256"], oa.sha256_file(output))
        result = oa.read_archive(output)
        self.assertEqual(
            oa.archive_summary(result, TARGET)["nonTargetMembersDigestSha256"],
            oa.archive_summary(self.fixture.base_members, TARGET)[
                "nonTargetMembersDigestSha256"],
        )
        self.assertEqual(oa.find_member(result, TARGET).payload,
                         self.fixture.object_bytes())

    def test_derivation_is_deterministic(self):
        first, _ = self.fixture.derive_to_temp(output_name="first.a")
        second, _ = self.fixture.derive_to_temp(output_name="second.a")
        self.assertEqual(oa.sha256_file(first), oa.sha256_file(second))

    def test_wrong_platform_is_refused(self):
        fixture = Fixture(object_mutator=lambda data: fake_macho("IOS", "16.0", "27.1"))
        self.addCleanup(fixture.close)
        with self.assertRaises(dv.DeriveError):
            fixture.derive_to_temp()

    def test_wrong_minos_is_refused(self):
        fixture = Fixture(object_mutator=lambda data: fake_macho("IOSSIMULATOR", "15.0", "27.1"))
        self.addCleanup(fixture.close)
        with self.assertRaises(dv.DeriveError):
            fixture.derive_to_temp()

    def test_wrong_sdk_is_refused(self):
        fixture = Fixture(object_mutator=lambda data: fake_macho("IOSSIMULATOR", "16.0", "26.2"))
        self.addCleanup(fixture.close)
        with self.assertRaises(dv.DeriveError):
            fixture.derive_to_temp()

    def test_missing_public_symbol_is_refused(self):
        fixture = Fixture(symbol_mutator=lambda data: {
            "defined": [symbol for symbol in data["defined"]
                        if "get_type_descriptor" not in symbol],
            "undefined": data["undefined"],
        })
        self.addCleanup(fixture.close)
        with self.assertRaises(dv.DeriveError):
            fixture.derive_to_temp()

    def test_changed_public_symbol_set_is_refused(self):
        fixture = Fixture(symbol_mutator=lambda data: {
            "defined": data["defined"] + ["__ZN13Standard_TypeExtraEv"],
            "undefined": data["undefined"],
        })
        self.addCleanup(fixture.close)
        with self.assertRaises(dv.DeriveError):
            fixture.derive_to_temp()

    def test_source_hash_mismatch_is_refused(self):
        path = os.path.join(self.fixture.root, self.fixture.base_source["path"])
        original = open(path, "rb").read()
        with open(path, "wb") as handle:
            handle.write(b"tampered")
        with self.assertRaises(dv.DeriveError):
            self.fixture.derive_to_temp()
        with open(path, "wb") as handle:
            handle.write(original)

    def test_base_archive_hash_mismatch_is_refused(self):
        with open(self.fixture.base_path, "ab") as handle:
            handle.write(b"x")
        with self.assertRaises(dv.DeriveError):
            self.fixture.derive_to_temp()


class TestRecordExisting(FixtureTestCase):
    def _object_path(self):
        path = os.path.join(self.fixture.root, "qualified-object.o")
        with open(path, "wb") as handle:
            handle.write(self.fixture.object_bytes())
        return path

    def test_record_reproduces_the_archive_and_binds_a_receipt(self):
        output, _ = self.fixture.derive_to_temp()
        receipt = os.path.join(self.fixture.root, "recorded-receipt.json")
        result = dv.record_existing_slice(
            self.fixture.root, self.fixture.recipe_path, "simulator",
            self.fixture.base_path, self._object_path(), output, receipt,
            recipe_sha256=sha256(open(self.fixture.recipe_path, "rb").read()),
            toolchain=dict(self.fixture.toolchain),
            tool_paths={"ranlib": "/usr/bin/ranlib", "nm": "/usr/bin/nm"},
            symbol_lister=self.fixture._lister,
            index_provider=self.fixture._index_provider,
            produced_at="2026-11-01T00:00:00Z",
        )
        self.assertEqual(result["sha256"], oa.sha256_file(output))
        loaded = dc.load_recipe(
            self.fixture.recipe_path,
            sha256(open(self.fixture.recipe_path, "rb").read()),
            self.fixture.recipe["id"],
        )
        recorded = json.load(open(receipt, encoding="utf-8"))
        problems, qualified = dc.validate_receipt(
            loaded, self.fixture.manifest["artifacts"][0], recorded,
            os.path.getsize(output), oa.sha256_file(output),
        )
        self.assertEqual(problems, [])
        self.assertTrue(qualified)
        self.assertEqual(recorded["provenance"]["mode"],
                         "recorded-existing-artifact")

    def test_record_refuses_an_archive_the_recipe_does_not_reproduce(self):
        output, _ = self.fixture.derive_to_temp()
        tampered = os.path.join(self.fixture.root, "tampered-qualified.a")
        data = bytearray(open(output, "rb").read())
        members = oa.read_archive(output)
        alpha = oa.find_member(members, "Alpha.cxx.o")
        data[alpha.offset + 60 + 12] ^= 0xFF
        with open(tampered, "wb") as handle:
            handle.write(data)
        with self.assertRaises(dv.DeriveError):
            dv.record_existing_slice(
                self.fixture.root, self.fixture.recipe_path, "simulator",
                self.fixture.base_path, self._object_path(), tampered,
                os.path.join(self.fixture.root, "refused.json"),
                recipe_sha256=sha256(open(self.fixture.recipe_path, "rb").read()),
                toolchain=dict(self.fixture.toolchain),
                tool_paths={"ranlib": "/usr/bin/ranlib", "nm": "/usr/bin/nm"},
                symbol_lister=self.fixture._lister,
                index_provider=self.fixture._index_provider,
                produced_at="2026-11-01T00:00:00Z",
            )

    def test_record_refuses_a_wrong_platform_object(self):
        output, _ = self.fixture.derive_to_temp()
        bad_object = os.path.join(self.fixture.root, "bad-object.o")
        with open(bad_object, "wb") as handle:
            handle.write(fake_macho("IOS", "16.0", "27.1"))
        with self.assertRaises(dv.DeriveError):
            dv.record_existing_slice(
                self.fixture.root, self.fixture.recipe_path, "simulator",
                self.fixture.base_path, bad_object, output,
                os.path.join(self.fixture.root, "refused.json"),
                recipe_sha256=sha256(open(self.fixture.recipe_path, "rb").read()),
                toolchain=dict(self.fixture.toolchain),
                tool_paths={"ranlib": "/usr/bin/ranlib", "nm": "/usr/bin/nm"},
                symbol_lister=self.fixture._lister,
                index_provider=self.fixture._index_provider,
                produced_at="2026-11-01T00:00:00Z",
            )


class TestBootstrapDerivedFlow(FixtureTestCase):
    def test_fresh_check_does_not_create_import_caches_or_change_files(self):
        self.prepare()
        self.fixture.set_expected_result(os.path.getsize(self.fixture.base_path),
                                         oa.sha256_file(self.fixture.base_path))
        script = os.path.join(self.fixture.root, "bootstrap.py")
        shutil.copyfile(BOOTSTRAP_PATH, script)
        for name in ("derivation_common.py", "occt_archive.py"):
            shutil.copyfile(os.path.join(DERIVATIONS, name),
                            os.path.join(self.fixture.derivations, name))

        def snapshot():
            files = {}
            directories = []
            for parent, names, entries in os.walk(self.fixture.root):
                directories.extend(os.path.relpath(os.path.join(parent, name),
                                                    self.fixture.root)
                                   for name in names)
                for name in entries:
                    path = os.path.join(parent, name)
                    files[os.path.relpath(path, self.fixture.root)] = (
                        os.stat(path).st_mtime_ns, oa.sha256_file(path))
            return sorted(directories), files

        environment = dict(os.environ)
        environment.pop("PYTHONDONTWRITEBYTECODE", None)
        environment.pop("PYTHONPYCACHEPREFIX", None)
        before = snapshot()
        for option in ("--check", "--release-check"):
            result = subprocess.run([sys.executable, script, option],
                                    capture_output=True, text=True,
                                    env=environment, timeout=30)
            self.assertEqual(result.returncode, 0,
                             result.stdout + result.stderr)
            self.assertEqual(snapshot(), before,
                             "A fresh read-only check must not write import caches")

    def test_check_reports_unprepared_pinned_base(self):
        rc, logs = self.fixture.run(check=True)
        self.assertEqual(rc, 2)
        self.assertTrue(any("UNPREP" in line for line in logs))
        self.assertTrue(any("lack the required derivation" in line for line in logs))

    def test_prepare_installs_derived_and_is_idempotent(self):
        rc, logs = self.prepare()
        self.assertEqual(rc, 0)
        self.assertNotEqual(open(self.fixture.base_path, "rb").read(),
                            self.fixture.base_bytes)
        self.assertTrue(os.path.exists(self.fixture.receipt_path))
        self.assertTrue(any("derived slice installed" in line for line in logs))
        calls = self.fixture.derive_calls
        with unittest.mock.patch.object(
                bs, "_run_derive_tool",
                side_effect=AssertionError("idempotent run must not re-derive")):
            rc, logs = self.fixture.run(check=False)
        self.assertEqual(rc, 0)
        self.assertEqual(self.fixture.derive_calls, calls)
        self.assertTrue(any("keep" in line for line in logs))

    def test_check_accepts_prepared_slice(self):
        self.prepare()
        rc, logs = self.fixture.run(check=True)
        self.assertEqual(rc, 0)
        self.assertTrue(any("PREPD" in line for line in logs))
        self.assertTrue(any("NOT the pinned upstream bytes" in line for line in logs))

    def test_stale_receipt_fails_closed(self):
        self.prepare()
        receipt = json.load(open(self.fixture.receipt_path, encoding="utf-8"))
        receipt["archive"]["sha256"] = "0" * 64
        with open(self.fixture.receipt_path, "w", encoding="utf-8") as handle:
            json.dump(receipt, handle)
        rc, logs = self.fixture.run(check=True)
        self.assertEqual(rc, 2)
        self.assertTrue(any("STALE" in line for line in logs))

    def test_missing_receipt_is_underived_in_official_mode(self):
        self.fixture.install(b"unpinned-but-not-base")
        rc, logs = self.fixture.run(check=True)
        self.assertEqual(rc, 2)
        self.assertTrue(any("UNDERI" in line for line in logs))

    def test_corrupt_non_target_member_is_rejected_and_repaired(self):
        self.prepare()
        data = bytearray(open(self.fixture.base_path, "rb").read())
        members = oa.read_archive(self.fixture.base_path)
        alpha = oa.find_member(members, "Alpha.cxx.o")
        data[alpha.offset + 60 + 12] ^= 0xFF
        with open(self.fixture.base_path, "wb") as handle:
            handle.write(data)
        rc, logs = self.fixture.run(check=True)
        self.assertEqual(rc, 2)
        self.assertTrue(any("STALE" in line for line in logs))
        with self.patched():
            rc, _ = self.fixture.run(check=False)
        self.assertEqual(rc, 0)
        rc, _ = self.fixture.run(check=True)
        self.assertEqual(rc, 0)

    def test_derivation_failure_preserves_existing_bytes(self):
        self.fixture.install()
        with self.patched(run=unittest.mock.Mock(
                side_effect=bs.DerivationError("injected compile failure"))):
            with self.assertRaises(bs.DerivationError):
                self.fixture.run(check=False)
        self.assertEqual(open(self.fixture.base_path, "rb").read(),
                         self.fixture.base_bytes)
        self.assertFalse(os.path.exists(self.fixture.receipt_path))
        leftovers = [name for name in os.listdir(os.path.dirname(self.fixture.base_path))
                     if name.startswith(".floecad-")]
        self.assertEqual(leftovers, [])

    def test_missing_base_is_fetched_but_never_installed(self):
        os.remove(self.fixture.base_path)
        rc, logs = self.prepare()
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.fixture.fetched), 1)
        self.assertFalse(os.path.exists(self.fixture.fetched[0]))
        self.assertTrue(any("fetch" in line for line in logs))
        self.assertNotEqual(open(self.fixture.base_path, "rb").read(),
                            self.fixture.base_bytes)
        rc, _ = self.fixture.run(check=True)
        self.assertEqual(rc, 0)

    def test_offline_missing_base_writes_nothing(self):
        os.remove(self.fixture.base_path)
        with self.assertRaises(bs.FetchError):
            self.fixture.run(check=False, offline=True)
        self.assertFalse(os.path.exists(self.fixture.base_path))

    def test_local_relink_keeps_user_bytes_but_plain_check_fails(self):
        self.fixture.install(b"deliberate local rebuild bytes")
        rc, logs = self.fixture.run(check=False, local_relink=True)
        self.assertEqual(rc, 0)
        self.assertEqual(open(self.fixture.base_path, "rb").read(),
                         b"deliberate local rebuild bytes")
        rc, logs = self.fixture.run(check=True, local_relink=True)
        self.assertEqual(rc, 0)
        self.assertTrue(any("LOCAL" in line for line in logs))
        rc, _ = self.fixture.run(check=True)
        self.assertEqual(rc, 2)

    def test_local_relink_does_not_accept_pinned_base(self):
        rc, logs = self.fixture.run(check=True, local_relink=True)
        self.assertEqual(rc, 2)
        self.assertTrue(any("UNPREP" in line for line in logs))
        rc, logs = self.prepare()
        self.assertEqual(rc, 0)

    def test_local_relink_stale_receipt_is_presence_only(self):
        self.prepare()
        receipt = json.load(open(self.fixture.receipt_path, encoding="utf-8"))
        receipt["archive"]["sha256"] = "0" * 64
        with open(self.fixture.receipt_path, "w", encoding="utf-8") as handle:
            json.dump(receipt, handle)
        rc, logs = self.fixture.run(check=True, local_relink=True)
        self.assertEqual(rc, 0)
        self.assertTrue(any("LOCAL*" in line for line in logs))
        rc, _ = self.fixture.run(check=True)
        self.assertEqual(rc, 2)

    def test_release_check_requires_expected_result_and_qualified_toolchain(self):
        self.prepare()
        rc, logs = self.fixture.run(check=True, release_check=True)
        self.assertEqual(rc, 2)
        self.assertTrue(any("REJECT" in line for line in logs))
        data = open(self.fixture.base_path, "rb").read()
        self.fixture.set_expected_result(len(data), sha256(data))
        rc, logs = self.fixture.run(check=True, release_check=True)
        self.assertEqual(rc, 0)
        self.assertTrue(any("qualified" in line for line in logs))
        self.fixture.set_expected_result(len(data), "0" * 64)
        rc, _ = self.fixture.run(check=True, release_check=True)
        self.assertEqual(rc, 2)

    def test_release_check_rejects_unqualified_toolchain(self):
        fixture = Fixture(toolchain=UNQUALIFIED_TOOLCHAIN)
        self.addCleanup(fixture.close)
        with unittest.mock.patch.object(bs, "_run_derive_tool", fixture.fake_run), \
                unittest.mock.patch.object(bs, "_fetch_verified_temp", fixture.fake_fetch):
            self.assertEqual(fixture.run(check=False)[0], 0)
        data = open(fixture.base_path, "rb").read()
        fixture.set_expected_result(len(data), sha256(data))
        rc, logs = fixture.run(check=True, release_check=True)
        self.assertEqual(rc, 2)
        self.assertTrue(any("not the qualified release toolchain" in line
                            for line in logs))

    def test_release_check_ignores_local_relink(self):
        self.fixture.install(b"deliberate local rebuild bytes")
        rc, logs = self.fixture.run(check=True, local_relink=True,
                                    release_check=True)
        self.assertEqual(rc, 2)
        self.assertTrue(any("ignores the local-relink opt-in" in line for line in logs))

    def test_receipt_path_escape_is_refused(self):
        self.fixture.install(b"not the pinned base")
        self.fixture.manifest["artifacts"][0]["derivation"]["receiptPath"] = "../evil.json"
        self.fixture.write_manifest()
        with self.assertRaises(bs.PathEscapeError):
            self.fixture.run(check=True)

    def test_recipe_hash_change_is_reported_stale(self):
        self.prepare()
        recipe = json.load(open(self.fixture.recipe_path, encoding="utf-8"))
        recipe["limitations"].append("changed after preparation")
        self.fixture.write_recipe(recipe)
        rc, logs = self.fixture.run(check=True)
        self.assertEqual(rc, 2)
        self.assertTrue(any("STALE" in line for line in logs))

    def test_non_reproducible_rederivation_is_refused(self):
        self.prepare()
        data = bytearray(open(self.fixture.base_path, "rb").read())
        members = oa.read_archive(self.fixture.base_path)
        alpha = oa.find_member(members, "Alpha.cxx.o")
        data[alpha.offset + 60 + 12] ^= 0xFF
        with open(self.fixture.base_path, "wb") as handle:
            handle.write(data)
        self.fixture.object_tag = b"OBJECT-V2"

        def mutate(data):
            return data + b"\x00" * 4

        self.fixture.object_mutator = mutate
        with self.patched():
            with self.assertRaises(bs.DerivationError):
                self.fixture.run(check=False)


class TestLocalRelinkSemantics(FixtureTestCase):
    def test_kept_local_bytes_are_not_rewritten(self):
        payload = b"my-own-local-occt-slice"
        self.fixture.install(payload)
        rc, _ = self.fixture.run(check=False, local_relink=True)
        self.assertEqual(rc, 0)
        self.assertEqual(open(self.fixture.base_path, "rb").read(), payload)
        self.assertFalse(os.path.exists(self.fixture.receipt_path))


if __name__ == "__main__":
    unittest.main(verbosity=2)
