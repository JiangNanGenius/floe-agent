import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ensure_linux_gitee_repository import ensure, REPOSITORY


def response(status=200, **overrides):
    value = {"full_name": REPOSITORY, "owner": {"login": "JiangNanGenius"}, "private": False}
    value.update(overrides)
    return SimpleNamespace(status=status, body=json.dumps(value).encode())


class Client:
    def __init__(self, *responses):
        self.responses = iter(responses)
        self.calls = []

    def request(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        return next(self.responses)


class LinuxMirrorRepositoryTests(unittest.TestCase):
    def test_existing_repository_is_read_only(self):
        client = Client(response())
        self.assertEqual(ensure(client, "fixture", create=True), REPOSITORY)
        self.assertEqual([x[0] for x in client.calls], ["GET"])

    def test_missing_repository_does_not_create_implicitly(self):
        client = Client(response(404))
        with self.assertRaises(RuntimeError):
            ensure(client, "fixture")
        self.assertEqual(len(client.calls), 1)

    def test_creation_is_once_then_verified(self):
        client = Client(response(404), response(201), response())
        ensure(client, "fixture", create=True)
        self.assertEqual([x[0] for x in client.calls], ["GET", "POST", "GET"])
        post = client.calls[1][2]
        self.assertEqual(post["retries"], 0)
        self.assertIs(json.loads(post["body"])["private"], False)

    def test_existing_private_repository_not_made_public(self):
        client = Client(response(private=True))
        with self.assertRaises(RuntimeError):
            ensure(client, "fixture", create=True)
        self.assertEqual(len(client.calls), 1)

    def test_wrong_owner_is_rejected(self):
        with self.assertRaises(RuntimeError):
            ensure(Client(response(owner={"login": "another-user"})), "fixture", create=True)

    def test_wrong_repository_is_rejected(self):
        with self.assertRaises(RuntimeError):
            ensure(Client(response(full_name="JiangNanGenius/other")), "fixture", create=True)

    def test_empty_private_repository_gets_readme_but_remains_blocked(self):
        client = Client(response(private=True), SimpleNamespace(status=200, body=b"[]"), response(201))
        with self.assertRaises(RuntimeError):
            ensure(client, "fixture", seed_empty=True)
        self.assertEqual([x[0] for x in client.calls], ["GET", "GET", "POST"])
        self.assertTrue(client.calls[-1][1].endswith("/contents/README.md"))
        self.assertEqual(client.calls[-1][2]["retries"], 0)

    def test_existing_branch_is_never_overwritten(self):
        client = Client(response(), SimpleNamespace(status=200, body=b'[{"name":"main"}]'))
        ensure(client, "fixture", seed_empty=True)
        self.assertEqual([x[0] for x in client.calls], ["GET", "GET"])

    def test_unknown_branch_response_does_not_write(self):
        client = Client(response(), SimpleNamespace(status=200, body=b"{}"))
        with self.assertRaises(RuntimeError):
            ensure(client, "fixture", seed_empty=True)
        self.assertEqual([x[0] for x in client.calls], ["GET", "GET"])


if __name__ == "__main__":
    unittest.main()
