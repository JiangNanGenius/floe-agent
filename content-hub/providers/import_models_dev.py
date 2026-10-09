#!/usr/bin/env python3
"""Build Floe's bundled provider catalog from the public models.dev document.

Reads https://models.dev/api.json (upstream project sst/models.dev, MIT) and
emits a curated, deterministic catalog of providers that Floe can genuinely
target with its existing protocols and authentication shapes:

  * available    — wire protocol + auth style map onto a Floe adapter today.
  * unsupported  — real public provider, but needs OAuth or a nonstandard
                   request transform; kept so search never silently drops it.

Outputs (relative to the repository root):
  FloeAgent/FloeApp/Resources/ProviderCatalog.json   bundled resource
  content-hub/providers/SOURCE.json                  provenance record

Only provider names, model identifiers and public documentation URLs are
copied. API keys, user auth data and upstream JS SDK content are never read
into or written by this script.

Modes:
  python3 content-hub/providers/import_models_dev.py                fetch + write
  python3 content-hub/providers/import_models_dev.py --check        read-only verify
  python3 content-hub/providers/import_models_dev.py --update-source
        explicitly re-pin: accept the downloaded document hash, rewrite
        SOURCE.json and ProviderCatalog.json with fresh fetch metadata

Pin policy: the canonical pin is `SOURCE.json.documentSHA256`, the SHA-256 of
the served api.json bytes. The upstream repository revision recorded alongside
it is informational only: models.dev serves a generated document, so a git
commit is not assumed to be byte-identical to the served response. Plain runs
and --check refuse to proceed when the downloaded hash differs from the pin;
only --update-source moves the pin.

Determinism: output is canonical JSON (sorted keys, stable provider and model
order). Given the same pinned document bytes the regenerated bundled file is
byte-identical except for `source.fetchedAt`, which is preserved from the
committed file. If the network is unavailable, --check exits 2 with a clear
message and writes nothing.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DOC_URL = "https://models.dev/api.json"
DOC_HOME = "https://models.dev"
UPSTREAM_PROJECT = "sst/models.dev"
CANONICAL_REPO = "anomalyco/models.dev"
LICENSE = "MIT"
LICENSE_URL = "https://github.com/sst/models.dev/blob/dev/LICENSE"
COMMITS_URL = "https://api.github.com/repos/sst/models.dev/commits?per_page=1"
USER_AGENT = "floe-agent-provider-catalog/1.0"
TIMEOUT_SECONDS = 120
MAX_MODELS_PER_PROVIDER = 50

OUTPUT_PATH = REPO_ROOT / "FloeAgent" / "FloeApp" / "Resources" / "ProviderCatalog.json"
# Published copy fetched by the app at an immutable commit for catalog
# refresh; kept byte-identical to the bundled resource.
PUBLISHED_PATH = REPO_ROOT / "content-hub" / "providers" / "ProviderCatalog.json"
SOURCE_PATH = REPO_ROOT / "content-hub" / "providers" / "SOURCE.json"

# Curated mapping. `baseURL=None` marks endpoints that cannot be expressed as
# a single public root (deployment-scoped or project-scoped). `models_from`
# merges several upstream ids into one user-facing preset. Model lists are
# capped deterministically: the newest ids by last_updated/release_date win,
# then the surviving ids are sorted ascending.
CURATED = [
    dict(
        presetID="openai", upstream=["openai"], name="OpenAI",
        aliases=["OpenAI", "开放人工智能"],
        kind="openAI", defaultProtocol="openai-responses",
        baseURL="https://api.openai.com/v1", domains=["api.openai.com"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="anthropic", upstream=["anthropic"], name="Anthropic",
        aliases=["Anthropic", "Claude", "克劳德"],
        kind="anthropic", defaultProtocol="anthropic-messages",
        baseURL="https://api.anthropic.com", domains=["api.anthropic.com"],
        authStyle="apiKeyHeader", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        # Floe's googleGemini preset is image-only (native generateContent),
        # so only image-output models are listed for search.
        presetID="google", upstream=["google"], name="Google Gemini Images",
        aliases=["Google", "谷歌", "Gemini", "Google AI"],
        kind="googleGemini", defaultProtocol="openai-chat-completions",
        baseURL="https://generativelanguage.googleapis.com/v1",
        domains=["generativelanguage.googleapis.com"],
        authStyle="apiKeyHeader", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter="output_image",
    ),
    dict(
        presetID="alibaba", upstream=["alibaba", "alibaba-cn"],
        name="Alibaba Cloud DashScope",
        aliases=["阿里云", "百炼", "DashScope", "通义", "通义千问", "Qwen"],
        kind="alibabaStudio", defaultProtocol="openai-chat-completions",
        baseURL="https://dashscope.aliyuncs.com/compatible-mode/v1",
        domains=["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="deepseek", upstream=["deepseek"], name="DeepSeek",
        aliases=["DeepSeek", "深度求索", "深寻"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.deepseek.com", domains=["api.deepseek.com"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=True, modelFilter=None,
    ),
    dict(
        presetID="moonshot", upstream=["moonshotai", "moonshotai-cn"],
        name="Moonshot AI",
        aliases=["Moonshot", "Moonshot AI", "月之暗面", "Kimi"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.moonshot.ai/v1",
        domains=["api.moonshot.ai", "api.moonshot.cn"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="zhipu", upstream=["zhipuai", "zai"], name="Zhipu AI",
        aliases=["智谱", "智谱AI", "GLM", "ChatGLM", "Z.ai"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://open.bigmodel.cn/api/paas/v4",
        domains=["open.bigmodel.cn", "api.z.ai"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        # models.dev documents MiniMax's Anthropic-compatible endpoint; Floe
        # maps it to MiniMax's OpenAI-compatible root so it works with the
        # bearer Chat Completions adapter.
        presetID="minimax", upstream=["minimax"], name="MiniMax",
        aliases=["MiniMax", "海螺", "Hailuo"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.minimax.io/v1",
        domains=["api.minimax.io", "api.minimax.cn"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="xai", upstream=["xai"], name="xAI",
        aliases=["xAI", "Grok"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.x.ai/v1", domains=["api.x.ai"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="groq", upstream=["groq"], name="Groq",
        aliases=["Groq", "Groq Cloud"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.groq.com/openai/v1", domains=["api.groq.com"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="mistral", upstream=["mistral"], name="Mistral",
        aliases=["Mistral", "Mistral AI", "米斯特拉尔"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.mistral.ai/v1", domains=["api.mistral.ai"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="together", upstream=["togetherai"], name="Together AI",
        aliases=["Together", "Together AI"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.together.xyz/v1", domains=["api.together.xyz"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="openrouter", upstream=["openrouter"], name="OpenRouter",
        aliases=["OpenRouter"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://openrouter.ai/api/v1", domains=["openrouter.ai"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="fireworks", upstream=["fireworks-ai"], name="Fireworks AI",
        aliases=["Fireworks", "Fireworks AI"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.fireworks.ai/inference/v1",
        domains=["api.fireworks.ai"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="siliconflow", upstream=["siliconflow", "siliconflow-cn"],
        name="SiliconFlow",
        aliases=["SiliconFlow", "硅基流动"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.siliconflow.cn/v1",
        domains=["api.siliconflow.com", "api.siliconflow.cn"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="volcengine", upstream=["volcengine"], name="Volcengine Ark",
        aliases=["Volcengine", "Volcengine Ark", "火山", "火山引擎", "方舟", "火山方舟"],
        kind="volcengineArk", defaultProtocol="openai-chat-completions",
        baseURL="https://ark.cn-beijing.volces.com/api/v3",
        domains=["ark.cn-beijing.volces.com"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="github-copilot", upstream=["github-copilot"],
        name="GitHub Copilot",
        aliases=["GitHub Copilot", "Copilot"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL="https://api.githubcopilot.com",
        domains=["api.githubcopilot.com"],
        authStyle="bearer", availability="unsupported",
        unsupportedReason="requires GitHub Copilot OAuth device flow",
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="azure", upstream=["azure"], name="Azure OpenAI",
        aliases=["Azure OpenAI", "Azure", "微软云"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL=None, domains=["openai.azure.com"],
        authStyle="apiKeyHeader", availability="unsupported",
        unsupportedReason="requires a deployment-specific endpoint and api-version parameter",
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="amazon-bedrock", upstream=["amazon-bedrock"],
        name="Amazon Bedrock",
        aliases=["Amazon Bedrock", "AWS Bedrock", "Bedrock", "亚马逊云"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL=None, domains=["amazonaws.com"],
        authStyle="none", availability="unsupported",
        unsupportedReason="requires AWS SigV4 request signing",
        toolNameCompatibility=False, modelFilter=None,
    ),
    dict(
        presetID="google-vertex", upstream=["google-vertex"],
        name="Google Vertex AI",
        aliases=["Vertex AI", "Google Vertex", "Google Cloud", "谷歌云"],
        kind="custom", defaultProtocol="openai-chat-completions",
        baseURL=None, domains=["aiplatform.googleapis.com", "googleapis.com"],
        authStyle="none", availability="unsupported",
        unsupportedReason="requires Google Cloud OAuth2 service-account credentials",
        toolNameCompatibility=False, modelFilter=None,
    ),
]


class CatalogError(Exception):
    pass


def fetch(url, accept="application/json"):
    request = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": accept,
    })
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return response.read()


def load_document(api_json_path):
    if api_json_path is not None:
        raw = Path(api_json_path).read_bytes()
        return raw, json.loads(raw.decode("utf-8"))
    try:
        raw = fetch(DOC_URL)
    except (urllib.error.URLError, OSError, TimeoutError) as error:
        raise CatalogError(f"offline or upstream unavailable: {error}") from error
    return raw, json.loads(raw.decode("utf-8"))


def fetch_git_revision():
    """Best-effort upstream revision; never fails the import."""
    try:
        raw = fetch(COMMITS_URL)
        commits = json.loads(raw.decode("utf-8"))
        if not isinstance(commits, list) or not commits:
            return None, None
        first = commits[0]
        sha = first.get("sha")
        date = (first.get("commit") or {}).get("committer", {}).get("date")
        if isinstance(sha, str) and len(sha) == 40:
            return sha, date
        return None, None
    except Exception:
        return None, None


def model_recency(model):
    return str(model.get("last_updated") or model.get("release_date") or "")


def matches_filter(model, mode):
    if mode is None:
        return True
    if mode == "output_image":
        modalities = (model or {}).get("modalities") or {}
        return "image" in (modalities.get("output") or [])
    raise CatalogError(f"unknown model filter: {mode}")


def entry_models(config, document):
    models = {}
    for upstream_id in config["upstream"]:
        provider = document.get(upstream_id)
        if not isinstance(provider, dict):
            continue
        for model_id, model in (provider.get("models") or {}).items():
            identifier = (model or {}).get("id") or model_id
            if not isinstance(identifier, str) or not identifier.strip():
                continue
            identifier = identifier.strip()
            if len(identifier.encode("utf-8")) > 256:
                continue
            models[identifier] = model or {}
    selected = []
    for identifier in sorted(models):
        if matches_filter(models[identifier], config["modelFilter"]):
            selected.append(identifier)
    return cap_models(selected, models)


def cap_models(identifiers, models):
    if len(identifiers) <= MAX_MODELS_PER_PROVIDER:
        return identifiers
    identifiers = sorted(
        identifiers,
        key=lambda item: (model_recency(models.get(item) or {}), item),
        reverse=True,
    )[:MAX_MODELS_PER_PROVIDER]
    return sorted(identifiers)


def build_provider(config, document):
    missing = [item for item in config["upstream"] if item not in document]
    if missing:
        raise CatalogError(
            f"{config['presetID']}: upstream provider(s) missing from document: {missing}"
        )
    return {
        "presetID": config["presetID"],
        "name": config["name"],
        "aliases": sorted(config["aliases"]),
        "kind": config["kind"],
        "defaultProtocol": config["defaultProtocol"],
        "baseURL": config["baseURL"],
        "domains": sorted(config["domains"]),
        "models": entry_models(config, document),
        "availability": config["availability"],
        "unsupportedReason": config["unsupportedReason"],
        "upstreamID": config["upstream"][0],
        "upstreamIDs": list(config["upstream"]),
        "authStyle": config["authStyle"],
        "toolNameCompatibility": config["toolNameCompatibility"],
    }


def build_document(document, raw, fetched_at):
    providers = [build_provider(config, document) for config in CURATED]
    return {
        "schemaVersion": 1,
        "source": {
            "project": "models.dev",
            "url": DOC_HOME,
            "license": LICENSE,
            "documentSHA256": hashlib.sha256(raw).hexdigest(),
            "fetchedAt": fetched_at,
        },
        "providers": providers,
    }


def canonical(document):
    return json.dumps(
        document, ensure_ascii=False, sort_keys=True, indent=2
    ).encode("utf-8") + b"\n"


def make_source_record(raw, document, fetched_at):
    revision, revision_date = fetch_git_revision()
    available = sum(1 for p in document["providers"] if p["availability"] == "available")
    unsupported = len(document["providers"]) - available
    source = {
        "project": UPSTREAM_PROJECT,
        "canonicalProject": CANONICAL_REPO,
        "url": DOC_HOME,
        "documentURL": DOC_URL,
        "license": LICENSE,
        "licenseURL": LICENSE_URL,
        "documentSHA256": hashlib.sha256(raw).hexdigest(),
        "fetchedAt": fetched_at,
        "pinPolicy": (
            "canonical pin is documentSHA256 of the served api.json; the recorded "
            "repository revision is informational and not assumed byte-identical to "
            "the served response"
        ),
        "repositoryRevisionAtFetchTime": revision,
        "repositoryRevisionDate": revision_date,
        "providerCount": len(document["providers"]),
        "availableCount": available,
        "unsupportedCount": unsupported,
        "modelEntryCount": sum(len(p["models"]) for p in document["providers"]),
        "generatedBy": "content-hub/providers/import_models_dev.py",
        "attributionNotes": [
            "Provider names, model identifiers and documentation links are derived from the open models.dev catalog (MIT).",
            "Floe curates, filters and maps the data to its own provider kinds, protocols and auth styles.",
            "No upstream code, JS SDK content, API keys or user credentials are copied.",
            "Merged upstream ids are listed in each provider's upstreamIDs field.",
        ],
    }
    if revision is None:
        source["repositoryRevisionNote"] = (
            "Upstream repository revision unavailable at fetch time (network or rate limit)."
        )
    return source


def load_source_record():
    if not SOURCE_PATH.is_file():
        return None
    try:
        record = json.loads(SOURCE_PATH.read_bytes().decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return record if isinstance(record, dict) else None


def committed_fetched_at():
    if not OUTPUT_PATH.is_file():
        return None
    try:
        committed = json.loads(OUTPUT_PATH.read_bytes().decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    fetched_at = (committed.get("source") or {}).get("fetchedAt")
    return fetched_at if isinstance(fetched_at, str) and fetched_at else None


def write_outputs(document, source_record, write_source=True):
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    data = canonical(document)
    OUTPUT_PATH.write_bytes(data)
    PUBLISHED_PATH.parent.mkdir(parents=True, exist_ok=True)
    PUBLISHED_PATH.write_bytes(data)
    if write_source:
        SOURCE_PATH.write_bytes(canonical(source_record))
    if source_record is None:
        providers = document["providers"]
        available = sum(1 for p in providers if p["availability"] == "available")
        summary = (len(providers), sum(len(p["models"]) for p in providers), available)
    else:
        summary = (
            source_record["providerCount"],
            source_record["modelEntryCount"],
            source_record["availableCount"],
        )
    print(
        "Wrote {} providers ({} models, {} available, {} unsupported) to {}".format(
            summary[0], summary[1], summary[2], summary[0] - summary[2],
            OUTPUT_PATH.relative_to(REPO_ROOT),
        )
    )
    if write_source:
        print(f"Wrote {SOURCE_PATH.relative_to(REPO_ROOT)}")


def check(document, raw):
    if not OUTPUT_PATH.is_file():
        print(f"FAIL: committed catalog missing: {OUTPUT_PATH}", file=sys.stderr)
        return 1
    committed_bytes = OUTPUT_PATH.read_bytes()
    fetched_at = committed_fetched_at()
    if fetched_at is None:
        print("FAIL: committed catalog has no source.fetchedAt", file=sys.stderr)
        return 1
    digest = hashlib.sha256(raw).hexdigest()
    regenerated = build_document(document, raw, fetched_at)
    expected = canonical(regenerated)
    if expected != committed_bytes:
        print(
            "FAIL: committed ProviderCatalog.json does not match the pinned document "
            "(run --update-source to re-pin and regenerate)",
            file=sys.stderr,
        )
        return 1
    if not PUBLISHED_PATH.is_file() or PUBLISHED_PATH.read_bytes() != expected:
        print(
            "FAIL: content-hub/providers/ProviderCatalog.json is missing or differs "
            "from the bundled resource; rerun the importer",
            file=sys.stderr,
        )
        return 1
    print(
        "PASS: ProviderCatalog.json matches the pinned models.dev document {} "
        "({} providers)".format(digest[:12], len(regenerated["providers"]))
    )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="read-only verification")
    parser.add_argument(
        "--update-source", action="store_true",
        help="explicitly re-pin to the downloaded document and rewrite SOURCE.json",
    )
    parser.add_argument(
        "--api-json", metavar="PATH",
        help="use a local models.dev api.json snapshot instead of the network",
    )
    args = parser.parse_args(argv)
    if args.check and args.update_source:
        print("FAIL: --check and --update-source cannot be combined", file=sys.stderr)
        return 1

    fetched_at = datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        raw, document = load_document(args.api_json)
    except (CatalogError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2
    if not isinstance(document, dict) or "openai" not in document:
        print("FAIL: downloaded document does not look like models.dev/api.json", file=sys.stderr)
        return 2

    digest = hashlib.sha256(raw).hexdigest()
    try:
        if args.update_source:
            built = build_document(document, raw, fetched_at)
            source_record = make_source_record(raw, built, fetched_at)
            write_outputs(built, source_record)
            print(f"Pinned documentSHA256 {digest}")
            return 0

        pinned = load_source_record()
        pinned_digest = (pinned or {}).get("documentSHA256")
        if pinned is None:
            print(
                "FAIL: SOURCE.json is missing; run with --update-source to create the pin",
                file=sys.stderr,
            )
            return 1
        if pinned_digest != digest:
            print(
                "FAIL: downloaded api.json hash {} does not match pinned "
                "SOURCE.json.documentSHA256 {}; run --update-source to re-pin".format(
                    digest[:12], str(pinned_digest)[:12]
                ),
                file=sys.stderr,
            )
            return 1

        if args.check:
            return check(document, raw)

        effective_fetched_at = committed_fetched_at() or fetched_at
        built = build_document(document, raw, effective_fetched_at)
        expected = canonical(built)
        if OUTPUT_PATH.is_file() and OUTPUT_PATH.read_bytes() == expected:
            print(
                "Up to date: ProviderCatalog.json already matches pinned document {} "
                "({} providers)".format(digest[:12], len(built["providers"]))
            )
            return 0
        write_outputs(built, None, write_source=False)
        print(f"Regenerated from pinned document {digest}")
        return 0
    except (CatalogError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
