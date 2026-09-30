#!/usr/bin/env python3
"""Check or explicitly create the public Linux component mirror; never delete data."""
import argparse
import json
import os
import sys

from sync_release_to_gitee import HttpClient

REPOSITORY = "JiangNanGenius/floe-linux-images"
API = "https://gitee.com/api/v5"


def ensure(client, token, create=False):
    headers = {"Authorization": "token " + token, "Accept": "application/json"}
    result = client.request("GET", API + "/repos/" + REPOSITORY,
                            headers=headers, allow_404=True)
    if result.status == 404:
        if not create:
            raise RuntimeError("Linux mirror repository missing; explicit creation is required")
        body = json.dumps({
            "name": "floe-linux-images", "path": "floe-linux-images",
            "private": False, "auto_init": False,
            "description": "Verified Linux component mirror for Floe Agent. GitHub is the source of truth.",
            "homepage": "https://github.com/JiangNanGenius/floe-agent",
            "has_issues": False, "has_wiki": False,
        }).encode()
        # Do not retry an ambiguous creation. A subsequent run checks existence first.
        client.request("POST", API + "/user/repos", headers={**headers, "Content-Type": "application/json"},
                       body=body, retries=0, expect=(201,))
        result = client.request("GET", API + "/repos/" + REPOSITORY, headers=headers)
    repository = json.loads(result.body)
    if repository.get("full_name", "").casefold() != REPOSITORY.casefold():
        raise RuntimeError("Unexpected repository identity")
    if repository.get("private") is not False or repository.get("public") is False:
        raise RuntimeError("Mirror is not public; visibility will not be changed automatically")
    if repository.get("owner", {}).get("login", "").casefold() != "jiangnangenius":
        raise RuntimeError("Unexpected repository owner")
    return REPOSITORY


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--create", action="store_true")
    args = parser.parse_args()
    token = os.environ.get("GITEE_TOKEN", "")
    if not token:
        print("GITEE_TOKEN is required", file=sys.stderr)
        return 1
    try:
        print("Verified public repository: " + ensure(HttpClient(timeout=60, retries=1), token, args.create))
    except Exception as error:
        # API response bodies can contain account metadata; keep them out of logs.
        print("Repository check failed: " + type(error).__name__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
