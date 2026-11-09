"""Independently verify one content-package publication from immutable Git refs."""
import argparse
import json
import re
import subprocess

COMPATIBILITY_ID = "floe.providers.compatibility"


def verify(before, after, changes, identifier):
    if identifier != COMPATIBILITY_ID:
        raise ValueError("only compatibility-package publication is supported")
    if set(before) != set(after) or any(before[key] != after[key]
            for key in before if key not in {"entries", "generatedAt"}):
        raise ValueError("publication changed feed metadata")
    old = {entry["id"]: entry for entry in before["entries"]}
    new = {entry["id"]: entry for entry in after["entries"]}
    if len(old) != len(before["entries"]) or len(new) != len(after["entries"]):
        raise ValueError("duplicate feed package IDs")
    if old.keys() != new.keys() or identifier not in old:
        raise ValueError("publication added or removed package IDs")
    if any(old[key] != new[key] for key in old if key != identifier):
        raise ValueError("publication changed an unselected package entry")
    version = new[identifier]["version"]
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("invalid selected package version")
    old_version = tuple(map(int, old[identifier]["version"].split(".")))
    new_version = tuple(map(int, version.split(".")))
    if new_version < old_version or (new_version == old_version and new[identifier] != old[identifier]):
        raise ValueError("publication downgraded or rewrote a selected version")
    package_path = f"content-hub/packages/{identifier}/{version}/{identifier}.zip"
    if new[identifier]["path"] != package_path:
        raise ValueError("selected package pointer is not canonical")
    for change in changes.splitlines():
        fields = change.split("\t")
        if len(fields) != 2:
            raise ValueError("unexpected publication diff record")
        status, path = fields
        if (status == "M" and path in {"content-hub/index.json", "content-hub/index.sig"}) \
                or (status == "A" and path == package_path):
            continue
        raise ValueError(f"publication changed an unselected path: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--only-package", required=True, choices=[COMPATIBILITY_ID])
    args = parser.parse_args()
    if not all(re.fullmatch(r"[0-9a-f]{40}", ref) for ref in (args.before, args.after)):
        parser.error("before and after must be immutable commit SHAs")
    def index(ref):
        return json.loads(subprocess.check_output(["git", "show", f"{ref}:content-hub/index.json"]))
    changes = subprocess.check_output([
        "git", "diff", "--name-status", "--no-renames", args.before, args.after
    ], text=True)
    verify(index(args.before), index(args.after), changes, args.only_package)
    print("Verified selected compatibility entry and unchanged publication boundaries")


if __name__ == "__main__":
    main()
