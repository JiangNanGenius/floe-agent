#!/usr/bin/env python3
"""Check or explicitly create the public Linux component mirror; never delete data."""
import argparse
import base64
import json
import os
from pathlib import Path
import sys

from sync_release_to_gitee import HttpClient, HttpError

REPOSITORY = "JiangNanGenius/floe-linux-images"
API = "https://gitee.com/api/v5"


class RepositoryCheckError(RuntimeError):
    """Only locally authored, non-sensitive diagnostic messages."""


def ensure(client, token, create=False, seed_empty=False, install_license=False):
    headers = {"Authorization": "token " + token, "Accept": "application/json"}
    print("Checking Linux mirror repository", flush=True)
    result = client.request("GET", API + "/repos/" + REPOSITORY,
                            headers=headers, allow_404=True)
    if result.status == 404:
        if not create:
            raise RepositoryCheckError("Linux mirror repository missing; explicit creation is required")
        print("Repository absent; creating dedicated Linux mirror once", flush=True)
        body = json.dumps({
            "name": "floe-linux-images", "path": "floe-linux-images",
            "private": False, "auto_init": False,
            "description": "Verified Linux component mirror for Floe Agent. GitHub is the source of truth.",
            "homepage": "https://github.com/JiangNanGenius/floe-agent",
            "has_issues": False, "has_wiki": False,
        }).encode()
        # Do not retry an ambiguous creation. A subsequent run checks existence first.
        client.request("POST", API + "/user/repos", headers={**headers, "Content-Type": "application/json"},
                       body=body, retries=0, timeout=180, expect=(201,))
        print("Verifying created repository", flush=True)
        result = client.request("GET", API + "/repos/" + REPOSITORY, headers=headers)
    repository = json.loads(result.body)
    if repository.get("full_name", "").casefold() != REPOSITORY.casefold():
        raise RepositoryCheckError("Unexpected repository identity")
    if repository.get("owner", {}).get("login", "").casefold() != "jiangnangenius":
        raise RepositoryCheckError("Unexpected repository owner")
    if seed_empty:
        branches = client.request("GET", API + "/repos/" + REPOSITORY + "/branches?per_page=1",
                                  headers=headers)
        branch_list = json.loads(branches.body)
        if branch_list == []:
            readme = ("# Floe Linux image mirror / Linux 镜像备用源\n\n"
                      "This repository hosts verified copies of Floe Linux components. "
                      "GitHub remains the source of truth: https://github.com/JiangNanGenius/floe-agent\n\n"
                      "本仓库用于存放经过校验的 Linux 镜像副本。镜像、摘要和源码说明将在校验完成后发布到 Releases。\n\n"
                      "An empty Releases page means the mirror is not ready for downloads. "
                      "Each published component must retain its source offer and checksum metadata.\n")
            payload = {"content": base64.b64encode(readme.encode()).decode(),
                       "message": "Initialize Linux component mirror documentation"}
            print("Seeding verified empty repository with public README", flush=True)
            client.request("POST", API + "/repos/" + REPOSITORY + "/contents/README.md",
                           headers={**headers, "Content-Type": "application/json"},
                           body=json.dumps(payload).encode(), retries=0, expect=(201,))
            print("README created; repository is no longer empty", flush=True)
        elif not isinstance(branch_list, list):
            raise RepositoryCheckError("Cannot verify repository branches; no README written")
        else:
            print("Repository already has a branch; existing content left unchanged", flush=True)
    # Only the visibility booleans are printed; no account or API response data.
    visibility = {key: repository.get(key) if isinstance(repository.get(key), bool) else None
                  for key in ("private", "public", "internal")}
    print("Repository visibility: " + json.dumps(visibility, sort_keys=True), flush=True)
    if repository.get("private") is not False or repository.get("public") is False:
        raise RepositoryCheckError("Mirror is not public; visibility will not be changed automatically")
    if install_license:
        documents = {
            "LICENSE": (Path(__file__).resolve().parents[2] / "LICENSE").read_bytes(),
            "THIRD_PARTY_NOTICE.md": (
                "# Component licenses / 组件许可\n\n"
                "The LICENSE file contains Floe Agent's Mozilla Public License 2.0. "
                "It does not relicense the Linux image or its third-party components.\n\n"
                "Linux images contain independently licensed software. Preserve and consult "
                "each release's SOURCE-OFFER.md, provenance and package copyright notices "
                "(including /usr/share/doc/*/copyright inside the guest) for the applicable "
                "licenses and corresponding source.\n\n"
                "LICENSE 为 Floe Agent 的 MPL-2.0 许可证，不改变镜像内第三方组件的许可。"
                "各组件仍遵循其原有许可证；请参阅 Release 的源码提供说明、来源信息及客体内的软件包版权文件。\n"
            ).encode(),
        }
        for name, content in documents.items():
            url = API + "/repos/" + REPOSITORY + "/contents/" + name
            existing = client.request("GET", url, headers=headers, allow_404=True)
            entry = json.loads(existing.body) if existing.status != 404 else None
            # Gitee also returns HTTP 200 with [] for a missing content path.
            if entry not in (None, []):
                if not isinstance(entry, dict) or entry.get("type") != "file":
                    raise RepositoryCheckError("Unexpected license content response: " + name)
                recorded = base64.b64decode(entry.get("content", ""))
                if recorded != content:
                    raise RepositoryCheckError("Existing license document differs; refusing overwrite: " + name)
                continue
            client.request("POST", url,
                           headers={**headers, "Content-Type": "application/json"},
                           body=json.dumps({"content": base64.b64encode(content).decode(),
                                            "message": "Add mirror license and component notice"}).encode(),
                           retries=0, expect=(201,))
            print("Created " + name, flush=True)
    return REPOSITORY


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--create", action="store_true")
    parser.add_argument("--seed-empty", action="store_true")
    parser.add_argument("--install-license", action="store_true")
    args = parser.parse_args()
    token = os.environ.get("GITEE_TOKEN", "")
    if not token:
        print("GITEE_TOKEN is required", file=sys.stderr)
        return 1
    try:
        print("Verified public repository: " + ensure(HttpClient(timeout=60, retries=1), token, args.create, args.seed_empty, args.install_license))
    except Exception as error:
        # API response bodies can contain account metadata; keep them out of logs.
        detail = (" HTTP " + str(error.status)) if isinstance(error, HttpError) else ""
        if isinstance(error, RepositoryCheckError):
            detail = ": " + str(error)
        print("Repository check failed: " + type(error).__name__ + detail, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
