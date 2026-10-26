"""Focused shared-Skills backend checks: real daemon source, fake git runner.

All state (shared skills root, cloud workspaces, agent state/config) is isolated
in a temporary directory. The fake runner exercises the daemon's pull/list/read
decision logic without network access; production validation (URL/ref/path
rules, argv arrays, immutability gates) remains fully in force. The mount-branch
check runs the launch-line shape against real /bin/sh with a docker shim; the
exact Swift generator bytes are pinned separately here and in the authored-only
RemoteSharedSkillMountTests until Main's unified compile batch.
"""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace

SKILL_URL = "https://git.example.invalid/library-skills.git"
REVISION = "b" * 40


def digest_of(entries):
    manifest = "\n".join(f"{path}:{digest}:{mode}" for path, digest, mode in sorted(entries))
    return hashlib.sha256(manifest.encode("utf-8")).hexdigest()


def entry_digest(files):
    return digest_of([(path, hashlib.sha256(data).hexdigest(),
                       "100755" if data.startswith(b"#!/") else "100644")
                      for path, data in sorted(files.items())])


class FakeGit:
    """Minimal git protocol emulation driven by the daemon's argv arrays."""

    def __init__(self):
        self.thread_local = threading.local()
        self.revision = REVISION
        self.fail_fetch = False
        self.shallow_fails = False
        self.fail_cat_file = set()
        self.tree_overrides = None
        self.calls = []
        self.fetches = []

    @property
    def files(self):
        return getattr(self.thread_local, "files", {})

    @files.setter
    def files(self, value):
        self.thread_local.files = value

    def use(self, files, subdirectory="skills/writing-guide"):
        self.files = {(f"{subdirectory}/{path}" if subdirectory else path): data for path, data in files.items()}

    def __call__(self, arguments, cwd, timeout):
        assert isinstance(arguments, list), "daemon must dispatch argv arrays"
        assert all(isinstance(argument, str) for argument in arguments)
        self.calls.append(list(arguments))
        argv = [argument for argument in arguments if argument != "-q"]
        if argv[:1] == ["init"]:
            return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        if argv[:3] == ["-C", None, "remote"] or (len(argv) > 2 and argv[2] == "remote"):
            return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        if len(argv) > 2 and argv[2] == "fetch":
            self.fetches.append(list(argv))
            if self.fail_fetch or (self.shallow_fails and "--depth" in argv):
                return SimpleNamespace(returncode=128, stdout=b"", stderr=b"cannot fetch\n")
            return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        if len(argv) > 2 and argv[2] == "rev-parse":
            return SimpleNamespace(returncode=0, stdout=(self.revision + "\n").encode(), stderr=b"")
        if len(argv) > 2 and argv[2] == "ls-tree":
            if self.tree_overrides is not None:
                return SimpleNamespace(returncode=0, stdout=self.tree_overrides, stderr=b"")
            records = []
            for path in sorted(self.files):
                data = self.files[path]
                mode = "100755" if data.startswith(b"#!/") else "100644"
                blob = hashlib.sha1(data).hexdigest()
                records.append(f"{mode} blob {blob} {len(data)}\t{path}".encode() + b"\0")
            return SimpleNamespace(returncode=0, stdout=b"".join(records), stderr=b"")
        if len(argv) > 2 and argv[2] == "cat-file":
            spec = argv[-1]
            path = spec.split(":", 1)[1]
            if path in self.fail_cat_file:
                return SimpleNamespace(returncode=128, stdout=b"", stderr=b"cat-file failed\n")
            if path not in self.files:
                return SimpleNamespace(returncode=128, stdout=b"", stderr=b"missing\n")
            return SimpleNamespace(returncode=0, stdout=self.files[path], stderr=b"")
        raise AssertionError(f"unexpected git argv: {arguments}")


class SharedSkillsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.TemporaryDirectory(prefix="floe-shared-skills-test-")
        cls.old_environment = dict(os.environ)
        for name in ("CLOUD", "STATE", "CONFIG"):
            os.environ[f"FLOE_{name}_ROOT"] = str(Path(cls.root.name) / name)
        os.environ["FLOE_SHARED_SKILLS_ROOT"] = str(Path(cls.root.name) / "shared-skills")
        source = Path(__file__).resolve().parents[1] / "Sources/FloeExecution/Resources/RemoteAgent/floe_remote_agent.py"
        spec = importlib.util.spec_from_file_location("skills_test_agent", source)
        cls.agent = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.agent)

    @classmethod
    def tearDownClass(cls):
        os.environ.clear()
        os.environ.update(cls.old_environment)
        cls.root.cleanup()

    def setUp(self):
        self.skills_root = Path(self.agent.SHARED_SKILLS)
        if self.skills_root.exists():
            shutil.rmtree(self.skills_root)
        self.skills_root.mkdir(parents=True)
        self.fake = FakeGit()
        self.agent.SKILL_GIT = self.fake

    def tearDown(self):
        self.agent.SKILL_GIT = None

    def skill_files(self, marker="first", version=None):
        frontmatter = ["---", "name: writing-guide", "display_name: Writing Guide"]
        if version:
            frontmatter.append(f"version: {version}")
        frontmatter += ["---", "", f"# Writing Guide {marker}"]
        files = {"SKILL.md": ("\n".join(frontmatter) + "\n").encode()}
        if version is None and marker == "with-manifest":
            files["floe.json"] = json.dumps({"id": "writing-guide", "version": "2.1.0"}).encode()
        else:
            files["scripts/run.sh"] = f"#!/bin/sh\necho {marker}\n".encode()
        return files

    def pull(self, skill_id="writing-guide", ref="main", subdirectory="skills/writing-guide", repository=SKILL_URL, body=None):
        self.fake.use(self.fake_base, subdirectory)
        payload = {"id": skill_id, "repository": repository, "ref": ref, "subdirectory": subdirectory}
        if body:
            payload.update(body)
        return self.agent.pull_skill(payload)

    def pull_content(self, files, **kwargs):
        self.fake_base = files
        return self.pull(**kwargs)

    # ---- frozen wire contract -------------------------------------------------

    def test_list_pull_and_fixed_read_match_native_wire(self):
        empty = self.agent.list_skills()
        self.assertEqual(empty, {"schema_version": 1, "skills": []})
        files = self.skill_files("first")
        entry = self.pull_content(files)
        self.assertEqual(
            set(entry), {"id", "name", "version", "repository", "ref", "subdirectory",
                         "revision", "digest", "relative_path", "updated_at"})
        self.assertEqual(entry["id"], "writing-guide")
        self.assertEqual(entry["name"], "Writing Guide")
        self.assertIsNone(entry["version"])
        self.assertEqual(entry["revision"], REVISION)
        self.assertRegex(entry["digest"], r"^[0-9a-f]{64}$")
        self.assertEqual(entry["digest"], entry_digest(files))
        self.assertEqual(entry["relative_path"], f"packages/writing-guide/{entry['digest']}")
        self.assertIsInstance(entry["updated_at"], float)
        listing = self.agent.list_skills()
        self.assertEqual(listing["schema_version"], 1)
        self.assertEqual(listing["skills"], [entry])
        self.assertTrue((self.skills_root / entry["relative_path"] / "SKILL.md").is_file())
        document = self.agent.read_skill(entry["id"], entry["digest"], "SKILL.md")
        self.assertEqual(document["skill_id"], entry["id"])
        self.assertEqual(document["digest"], entry["digest"])
        self.assertEqual(document["path"], "SKILL.md")
        self.assertEqual(document["content"], files["SKILL.md"].decode())
        self.assertEqual(document["byte_count"], len(document["content"].encode("utf-8")))
        nested = self.agent.read_skill(entry["id"], entry["digest"], "scripts/run.sh")
        self.assertEqual(nested["content"], files["scripts/run.sh"].decode())

    def test_capability_probe_and_agent_version_wire(self):
        source = (Path(__file__).resolve().parents[1] /
                  "Sources/FloeExecution/Resources/RemoteAgent/floe_remote_agent.py").read_text()
        self.assertIn('"shared_skills":True', source)
        self.assertIn('if parsed.path=="/v1/skills":', source)
        self.assertIn('if self.path=="/v1/skills/pull":', source)
        self.assertIn('return self._send(200,read_skill(pieces[2],pieces[4],relative))', source)
        payload = Path(__file__).resolve().parents[1] / "Sources/FloeExecution/RemoteAgentPayload.swift"
        swift = payload.read_text()
        self.assertIn(f'public static let version = "{self.agent.VERSION}"', swift)
        self.assertEqual(self.agent.VERSION, "1.5.0")

    # ---- rejection gates ------------------------------------------------------

    def test_global_skill_package_bounds_are_preserved(self):
        cases = [
            ({"SKILL.md": b"a" * (256 * 1024 + 1)}, "markdown size"),
            ({"SKILL.md": b"# Skill", "floe.json": b"a" * (64 * 1024 + 1)}, "manifest size"),
            ({"SKILL.md": b"# Skill", "large.bin": b"a" * (2 * 1024 * 1024 + 1)}, "per-file limit"),
            ({"SKILL.md": b"# Skill", **{f"data/{i}": b"a" * (2 * 1024 * 1024) for i in range(4)}}, "total size"),
        ]
        for files, reason in cases:
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(ValueError, reason):
                    self.pull_content(files)
                self.assertEqual(self.agent.list_skills()["skills"], [])

    def test_source_validation_rejects_before_any_git_dispatch(self):
        for repository in ("file:///tmp/x", "ext::sh -c whoami", "-u", "",
                           "https://user:pass@git.example.invalid/x.git",
                           "http://user@git.example.invalid/x.git",
                           "https://git.example.invalid/x y.git", "https://" + "a" * 600 + "/x"):
            with self.subTest(repository=repository):
                with self.assertRaises(ValueError):
                    self.agent.pull_skill({"id": "x", "repository": repository, "ref": "main", "subdirectory": ""})
        for ref in ("--upload-pack=evil", "-x", "a/../b", "", "refs/heads/..", "@{evil}"):
            with self.subTest(ref=ref):
                with self.assertRaises(ValueError):
                    self.agent.pull_skill({"id": "x", "repository": SKILL_URL, "ref": ref, "subdirectory": ""})
        for subdirectory in ("/abs", "../outside", ".git/config", "a/../../b", "x\\y"):
            with self.subTest(subdirectory=subdirectory):
                with self.assertRaises(ValueError):
                    self.agent.pull_skill({"id": "x", "repository": SKILL_URL, "ref": "main", "subdirectory": subdirectory})
        for bad_id in ("", "../x", "-x", "x" * 200):
            with self.subTest(bad_id=bad_id):
                with self.assertRaises(ValueError):
                    self.agent.pull_skill({"id": bad_id, "repository": SKILL_URL, "ref": "main", "subdirectory": ""})
        self.assertEqual(self.fake.calls, [])

    def test_malicious_tree_entries_are_rejected(self):
        base = self.skill_files("first")
        for label, record, expected in (
            ("symlink", b"120000 blob " + b"0" * 40 + b" 20\tskills/writing-guide/SKILL.md\0", "symbolic links"),
            ("gitlink", b"160000 commit " + b"0" * 40 + b" -\tskills/writing-guide/SKILL.md\0", "submodules"),
            ("mode", b"100600 blob " + b"0" * 40 + b" 1\tSKILL.md\0", "file mode"),
            ("escape", b"100644 blob " + b"0" * 40 + b" 1\telsewhere/SKILL.md\0", "subdirectory"),
            ("traversal", b"100644 blob " + b"0" * 40 + b" 1\tskills/writing-guide/../escape\0", "path is invalid"),
            ("metadata", b"100644 blob " + b"0" * 40 + b" 1\tskills/writing-guide/.git/config\0", "path is invalid"),
        ):
            with self.subTest(label):
                self.fake_base = base
                self.fake.tree_overrides = record
                with self.assertRaisesRegex(ValueError, expected):
                    self.pull()
                self.fake.tree_overrides = None
        self.assertFalse((self.skills_root / "index.json").exists())
        self.assertFalse((self.skills_root / "packages").exists())

    def test_missing_skill_markdown_rejected(self):
        self.fake_base = {"scripts/run.sh": b"#!/bin/sh\necho hi\n"}
        with self.assertRaisesRegex(ValueError, "SKILL.md"):
            self.pull()

    def test_read_rejects_escape_symlink_and_unknown_versions(self):
        files = self.skill_files("first")
        entry = self.pull_content(files)
        package = self.skills_root / entry["relative_path"]
        for path in ("/etc/passwd", "~/x", "", "a/../../b", "a/./b", ".git/config", "scripts\\run.sh", "SKILL.md\x01"):
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    self.agent.read_skill(entry["id"], entry["digest"], path)
        with self.assertRaises(ValueError):
            self.agent.read_skill(entry["id"], "not-a-digest", "SKILL.md")
        with self.assertRaises(ValueError):
            self.agent.read_skill(entry["id"], entry["digest"].upper(), "SKILL.md")
        with self.assertRaisesRegex(ValueError, "not published"):
            self.agent.read_skill(entry["id"], "c" * 64, "SKILL.md")
        with self.assertRaisesRegex(ValueError, "not published"):
            self.agent.read_skill("other-skill", entry["digest"], "SKILL.md")
        (package / "escape").symlink_to("/etc")
        with self.assertRaisesRegex(ValueError, "symbolic links"):
            self.agent.read_skill(entry["id"], entry["digest"], "escape/passwd")
        (package / "self").symlink_to(package / "SKILL.md")
        with self.assertRaisesRegex(ValueError, "symbolic links"):
            self.agent.read_skill(entry["id"], entry["digest"], "self")
        binary = package / "blob.bin"
        binary.write_bytes(b"\xff\xfe\x00binary")
        with self.assertRaisesRegex(ValueError, "UTF-8"):
            self.agent.read_skill(entry["id"], entry["digest"], "blob.bin")
        large = package / "huge.md"
        large.write_bytes(b"a" * (self.agent.SKILL_READ_MAX_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "too large"):
            self.agent.read_skill(entry["id"], entry["digest"], "huge.md")

    # ---- immutability, rollback and concurrency --------------------------------

    def test_failures_preserve_old_index_and_running_version(self):
        first = self.skill_files("first")
        entry = self.pull_content(first)
        before = (self.skills_root / "index.json").read_bytes()
        self.fake_base = self.skill_files("second")
        self.fake.revision = "d" * 40
        self.fake.fail_cat_file = {"skills/writing-guide/scripts/run.sh"}
        with self.assertRaisesRegex(ValueError, "cat-file"):
            self.pull()
        self.assertEqual((self.skills_root / "index.json").read_bytes(), before)
        self.assertEqual(self.agent.list_skills()["skills"], [entry])
        self.assertEqual(self.agent.read_skill(entry["id"], entry["digest"], "SKILL.md")["content"],
                         first["SKILL.md"].decode())
        self.fake.fail_cat_file = set()
        self.fake.fail_fetch = True
        with self.assertRaisesRegex(ValueError, "fetch failed"):
            self.pull()
        self.assertEqual((self.skills_root / "index.json").read_bytes(), before)
        self.fake.fail_fetch = False
        # the interrupted second digest never became a published directory
        second_digest = entry_digest(self.fake_base)
        self.assertFalse((self.skills_root / "packages/writing-guide" / second_digest).exists())

    def test_shallow_fetch_falls_back_to_full_fetch(self):
        self.fake_base = self.skill_files("first")
        self.fake.shallow_fails = True
        entry = self.pull()
        self.assertTrue(any("--depth" in argv for argv in self.fake.fetches))
        self.assertFalse(all("--depth" in argv for argv in self.fake.fetches))
        self.assertEqual(entry["revision"], REVISION)

    def test_same_semver_different_bytes_cannot_replace_published_release(self):
        first = self.skill_files("first", version="1.0.0")
        entry = self.pull_content(first)
        self.assertEqual(entry["version"], "1.0.0")
        before = (self.skills_root / "index.json").read_bytes()
        changed = dict(first)
        changed["SKILL.md"] = first["SKILL.md"].replace(b"first", b"replacement")
        self.fake_base = changed
        with self.assertRaisesRegex(ValueError, "already exists with different bytes"):
            self.pull()
        self.assertEqual((self.skills_root / "index.json").read_bytes(), before)
        self.assertEqual(self.agent.list_skills()["skills"], [entry])
        self.assertTrue(self.agent.read_skill(entry["id"], entry["digest"], "SKILL.md")["content"].endswith("first\n"))
        # identical bytes remain an idempotent no-op even after the rejection
        self.fake_base = first
        self.assertEqual(self.pull(), entry)
        # a bumped semver publishes honestly as a new immutable digest
        bumped = {path: data.replace(b"first", b"second").replace(b"version: 1.0.0", b"version: 1.0.1")
                  for path, data in first.items()}
        self.fake_base = bumped
        published = self.pull()
        self.assertEqual(published["version"], "1.0.1")
        self.assertNotEqual(published["digest"], entry["digest"])
        self.agent.read_skill(entry["id"], entry["digest"], "SKILL.md")  # old running version retained

    def test_semver_from_manifest_when_frontmatter_missing(self):
        self.fake_base = self.skill_files("with-manifest")
        entry = self.pull()
        self.assertEqual(entry["version"], "2.1.0")

    def test_without_semver_commit_and_digest_carry_identity(self):
        first = self.skill_files("first")
        entry = self.pull_content(first)
        self.assertIsNone(entry["version"])
        changed = {path: data.replace(b"first", b"second") for path, data in first.items()}
        self.fake_base = changed
        newer = self.pull_content(changed)
        self.assertEqual(newer["digest"], entry_digest(changed))
        self.assertNotEqual(newer["digest"], entry["digest"])
        self.assertEqual(self.agent.list_skills()["skills"][0]["digest"], newer["digest"])
        self.assertTrue((self.skills_root / entry["relative_path"] / "SKILL.md").read_bytes() == first["SKILL.md"])
        self.agent.read_skill(entry["id"], entry["digest"], "SKILL.md")  # retained for pinned tasks

    def test_repulling_an_older_commit_repins_current_honestly(self):
        first = self.skill_files("first")
        original = self.pull_content(first)
        changed = {path: data.replace(b"first", b"second") for path, data in first.items()}
        self.fake_base = changed
        self.fake.revision = "e" * 40
        newer = self.pull()
        self.fake_base = first
        self.fake.revision = REVISION
        back = self.pull()
        self.assertEqual(back["digest"], original["digest"])
        self.assertEqual(back["revision"], REVISION)
        self.assertEqual(self.agent.list_skills()["skills"], [back])
        self.agent.read_skill(newer["id"], newer["digest"], "SKILL.md")

    def test_concurrent_pulls_commit_atomically_and_pin_versions(self):
        results, errors = [], []
        results_lock = threading.Lock()
        barrier = threading.Barrier(2)

        def worker(marker):
            try:
                self.fake.use(self.skill_files(marker))
                barrier.wait(timeout=5)
                entry = self.agent.pull_skill(
                    {"id": "concurrent", "repository": SKILL_URL, "ref": "main", "subdirectory": "skills/writing-guide"})
                with results_lock:
                    results.append((marker, entry))
            except Exception as error:  # noqa: BLE001 - surfaced in assertion below
                with results_lock:
                    errors.append(error)

        threads = [threading.Thread(target=worker, args=(marker,)) for marker in ("first", "second")]
        for thread in threads: thread.start()
        for thread in threads: thread.join(timeout=30)
        self.assertEqual(errors, [])
        self.assertEqual(len(results), 2)
        index = json.loads((self.skills_root / "index.json").read_text())
        digests = set(index["published"]["concurrent"])
        self.assertEqual(len(digests), 2)
        current = index["skills"]["concurrent"]["digest"]
        self.assertIn(current, digests)
        for digest in digests:
            self.assertTrue((self.skills_root / "packages/concurrent" / digest / "SKILL.md").is_file())

    def test_staging_and_lock_cleanup(self):
        self.pull_content(self.skill_files("first"))
        stale = self.skills_root / ".staging" / "stale-entry"
        fresh = self.skills_root / ".staging" / "fresh-entry"
        stale.mkdir(parents=True); fresh.mkdir()
        old = time.time() - self.agent.SKILL_STAGING_TTL - 60
        os.utime(stale, (old, old))
        self.pull_content(self.skill_files("second"))
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.exists())  # only the daemon's own expired staging is removed
        shutil.rmtree(self.skills_root / ".staging" / "fresh-entry")
        self.assertEqual(list((self.skills_root / ".staging").iterdir()), [])

    # ---- container mount routing ----------------------------------------------

    def read_swift(self, relative):
        return (Path(__file__).resolve().parents[1] / relative).read_text()

    def test_swift_launch_line_pins_mount_and_status(self):
        swift = self.read_swift("Sources/FloeExecution/SSHCommandService.swift")
        for literal in ('-v \\"\\(skillsRoot):/opt/floe/skills:ro\\"',
                        'if [ -d \\"\\(skillsRoot)\\" ]',
                        'floeSharedSkillsMount=%s',
                        'let skillsRoot = "$HOME/.floe/shared/skills"'):
            self.assertIn(literal, swift)
        tool = self.read_swift("Sources/FloeExecution/Tools/SSHExecTool.swift")
        self.assertIn("floeSharedSkillsMount=present|missing", tool)
        self.assertIn("/opt/floe/skills/index.json", tool)

    def run_launch_line(self, home, exit_code):
        shim = Path(home) / "bin"
        shim.mkdir(parents=True, exist_ok=True)
        (shim / "docker").write_text(
            "#!/bin/sh\nfor arg in \"$@\"; do case \"$arg\" in"
            " *\":/opt/floe/skills:ro\") echo skills-mounted-readonly; exit %d;; esac; done\n"
            "echo skills-not-mounted; exit %d\n" % (exit_code, exit_code))
        (shim / "docker").chmod(0o755)
        skills_root = Path(home) / ".floe" / "shared" / "skills"
        if os.environ.get("FLOE_TEST_CREATE_SKILLS_ROOT") == "1":
            (skills_root / "packages").mkdir(parents=True, exist_ok=True)
            (skills_root / "index.json").write_text('{"schema_version": 1, "skills": []}')
        task_directory = Path(home) / ".floe" / "tasks" / "task-1"
        payload = base64.b64encode(b"printf 'inner\\n'\n").decode()
        launch = (f'docker run --rm --pull=never --network none --cpus 1 --memory 512m '
                  f'--pids-limit 128 --security-opt no-new-privileges -v "$HOME/.floe/tasks/task-1:/workspace"')
        script = f'sh -lc "echo {payload} | base64 -d | sh"'
        command = ('_floe_mount=missing; if [ -d "$HOME/.floe/shared/skills" ]; then _floe_mount=present; fi; '
                   f'mkdir -p "{task_directory}" && if [ "$_floe_mount" = present ]; then '
                   f'{launch} -v "$HOME/.floe/shared/skills:/opt/floe/skills:ro" -w /workspace ubuntu:24.04 {script}; '
                   f'else {launch} -w /workspace ubuntu:24.04 {script}; fi; _floe_status=$?; '
                   f'printf \'\\nfloeTaskDirectory={task_directory}\\nfloeSharedSkillsMount=%s\\n\' "$_floe_mount"; '
                   'exit $_floe_status')
        environment = dict(os.environ)
        environment.update({"PATH": f"{shim}:/usr/bin:/bin", "HOME": str(home),
                            "FLOE_TEST_CREATE_SKILLS_ROOT": os.environ.get("FLOE_TEST_CREATE_SKILLS_ROOT", "")})
        result = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True, env=environment, timeout=30)
        return result

    def test_mount_present_old_missing_branching(self):
        with tempfile.TemporaryDirectory(prefix="floe-mount-present-") as home:
            os.environ["FLOE_TEST_CREATE_SKILLS_ROOT"] = "1"
            result = self.run_launch_line(home, 7)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertIn("skills-mounted-readonly", result.stdout)
            self.assertIn("floeSharedSkillsMount=present", result.stdout)
            self.assertFalse((Path(home) / ".floe" / "shared" / "skills" / "packages").is_symlink())
        with tempfile.TemporaryDirectory(prefix="floe-mount-missing-") as home:
            os.environ.pop("FLOE_TEST_CREATE_SKILLS_ROOT", None)
            result = self.run_launch_line(home, 7)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertIn("skills-not-mounted", result.stdout)
            self.assertIn("floeSharedSkillsMount=missing", result.stdout)
            self.assertFalse((Path(home) / ".floe" / "shared").exists())  # no phantom root auto-created
        os.environ.pop("FLOE_TEST_CREATE_SKILLS_ROOT", None)


if __name__ == "__main__":
    unittest.main()
