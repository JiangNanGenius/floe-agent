#!/usr/bin/env python3
"""Build Floe's bundled provider catalog from the public models.dev document.

Reads https://models.dev/api.json (upstream project sst/models.dev, MIT) and
emits a curated, deterministic catalog of providers that Floe can genuinely
target with its existing protocols and authentication shapes. Reviewed
first-party facts that are not in models.dev (official subscription plans and
a few PAYG media rows) live in `content-hub/providers/curated-overrides.json`
and are merged deterministically after the upstream baseline; the importer
never reads the generated app catalog as an input.

  * available    — wire protocol + auth style map onto a Floe adapter today.
  * unsupported  — real public provider, but needs OAuth or a nonstandard
                   request transform; kept so search never silently drops it.

Outputs (relative to the repository root):
  FloeAgent/FloeApp/Resources/ProviderCatalog.json   bundled resource
  content-hub/providers/ProviderCatalog.json         canonical published copy
  content-hub/providers/SOURCE.json                  provenance record

Inputs: the pinned models.dev api.json (or a supplied --api-json snapshot) and
content-hub/providers/curated-overrides.json. The generated app catalog is
never an input, so regenerating cannot silently erase reviewed overrides.

Only provider names, model identifiers, public documentation URLs and
non-secret per-model capability metadata (input/output modalities plus the
tool-call/attachment/reasoning booleans) are copied. API keys, user auth data
and upstream JS SDK content are never read into or written by this script.

The emitted `modelMetadata` map is deliberately narrow: it lets the app give a
NEWLY created model truthful capability defaults (for example image input ->
vision) without ever rewriting a saved model, and it never claims audio/video
wire support. `serviceOffers` stays the only place a non-chat product role is
declared (for example Google Gemini's OpenAI-compatible chat route).

Modes:
  python3 content-hub/providers/import_models_dev.py                fetch + write
  python3 content-hub/providers/import_models_dev.py --check        read-only verify
  python3 content-hub/providers/import_models_dev.py --check-offline
        read-only local check: bundled/published equality, declarative
        overrides represented, SOURCE.json current. It cannot prove the
        pinned upstream bytes and says so; use --check when the pinned
        api.json is available.
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
order). Given the same pinned document bytes and the same curated-overrides
file the regenerated bundled file is byte-identical except for
`source.fetchedAt`, which is preserved from the committed file. If the network
is unavailable, --check exits 2 with a clear message and writes nothing;
--check-offline never touches the network.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

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
# Service-offer model lists are a curated subset, not the provider's whole
# catalog: keep them well below the app-side 100-identifier bound.
MAX_OFFER_MODELS = 25
# Modality tokens the app understands in per-model metadata. Unknown tokens
# are dropped here so a catalog can never carry an unimplemented capability.
KNOWN_MODALITIES = ("text", "image", "audio", "video", "pdf")

OUTPUT_PATH = REPO_ROOT / "FloeAgent" / "FloeApp" / "Resources" / "ProviderCatalog.json"
# Published copy fetched by the app at an immutable commit for catalog
# refresh; kept byte-identical to the bundled resource.
PUBLISHED_PATH = REPO_ROOT / "content-hub" / "providers" / "ProviderCatalog.json"
SOURCE_PATH = REPO_ROOT / "content-hub" / "providers" / "SOURCE.json"
# Single declarative source for reviewed first-party facts that are not in
# models.dev (official subscription plans and a few PAYG media rows). The
# importer merges this file AFTER generating the pinned upstream baseline.
OVERRIDES_PATH = REPO_ROOT / "content-hub" / "providers" / "curated-overrides.json"
OVERRIDES_SCHEMA_VERSION = 1
PRESET_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
REVISION_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$")
HOST_RE = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)
VALID_KINDS = {"openAI", "anthropic", "volcengineArk", "alibabaStudio",
               "googleGemini", "local", "custom"}
VALID_PROTOCOLS = {"openai-responses", "openai-chat-completions",
                   "anthropic-messages"}
VALID_AUTH_STYLES = {"bearer", "apiKeyHeader", "none"}
VALID_ROLES = ("conversation", "image", "video")
PATCH_FIELDS = {"name", "serviceOffers", "modelMetadata"}
PROVIDER_FIELDS = {
    "presetID", "name", "aliases", "kind", "defaultProtocol", "baseURL",
    "domains", "models", "availability", "unsupportedReason", "upstreamID",
    "authStyle", "toolNameCompatibility", "serviceOffers", "modelMetadata",
}
REQUIRED_PROVIDER_FIELDS = {
    "presetID", "name", "aliases", "kind", "defaultProtocol", "baseURL",
    "domains", "models", "availability", "unsupportedReason", "upstreamID",
    "authStyle", "toolNameCompatibility",
}
OFFER_FIELDS = {"role", "baseURL", "authStyle", "protocols", "models", "note"}
METADATA_FIELDS = {"input", "output", "toolCall", "attachment", "reasoning",
                   "contextTokens", "maxOutputTokens"}
MODALITY_FIELDS = ("input", "output")
BOOLEAN_METADATA_FIELDS = ("toolCall", "attachment", "reasoning")
TOKEN_METADATA_FIELDS = ("contextTokens", "maxOutputTokens")

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
        # so only image-output models are listed for the main search list.
        # The declared conversation offer is the documented OpenAI-compatible
        # route (v1beta/openai, Bearer API key): a DIFFERENT endpoint/auth
        # shape from the native image route, so the resolver reports it as a
        # separate connection instead of sharing the image credential.
        presetID="google", upstream=["google"], name="Google Gemini Images",
        aliases=["Google", "谷歌", "Gemini", "Google AI"],
        kind="googleGemini", defaultProtocol="openai-chat-completions",
        baseURL="https://generativelanguage.googleapis.com/v1",
        domains=["generativelanguage.googleapis.com"],
        authStyle="apiKeyHeader", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter="output_image",
        serviceOffers=[
            dict(
                role="conversation",
                baseURL="https://generativelanguage.googleapis.com/v1beta/openai",
                authStyle="bearer",
                protocols=["openai-chat-completions"],
                modelFilter="output_text_tool",
            ),
        ],
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


def _bounded_string(value, label, maximum, allow_empty=False):
    if not isinstance(value, str):
        raise CatalogError(f"{label} must be a string")
    if not allow_empty and not value.strip():
        raise CatalogError(f"{label} must not be empty")
    if len(value) > maximum:
        raise CatalogError(f"{label} exceeds {maximum} characters")
    if any(ord(character) < 32 for character in value):
        raise CatalogError(f"{label} contains control characters")
    return value


def _model_identifier(value, label):
    value = _bounded_string(value, label, 256)
    if any(character.isspace() for character in value):
        raise CatalogError(f"{label} must not contain whitespace")
    return value


def _https_url(value, label):
    value = _bounded_string(value, label, 512)
    try:
        parts = urlsplit(value)
    except ValueError as error:
        raise CatalogError(f"{label} is not a valid URL: {error}") from error
    try:
        hostname = parts.hostname
        port = parts.port
    except ValueError as error:
        raise CatalogError(f"{label} is not a valid URL: {error}") from error
    if parts.scheme.lower() != "https" or not hostname:
        raise CatalogError(f"{label} must be an https URL with a host")
    if parts.username or parts.password or parts.query or parts.fragment or port is not None:
        raise CatalogError(
            f"{label} must not carry credentials, query, fragment or port"
        )
    return value


def _normalize_modalities(value, label):
    if not isinstance(value, list) or not value:
        raise CatalogError(f"{label} must be a non-empty array")
    if len(value) > len(KNOWN_MODALITIES):
        raise CatalogError(f"{label} has too many modality tokens")
    seen = set()
    for token in value:
        if not isinstance(token, str) or token not in KNOWN_MODALITIES:
            raise CatalogError(f"{label} contains unknown modality {token!r}")
        if token in seen:
            raise CatalogError(f"{label} contains duplicate modality {token!r}")
        seen.add(token)
    return sorted(seen)


def _normalize_model_metadata(value, label):
    if not isinstance(value, dict) or not value:
        raise CatalogError(f"{label} must be a non-empty object")
    normalized = {}
    for model_id, facts in value.items():
        _model_identifier(model_id, f"{label} model id")
        if not isinstance(facts, dict) or not facts:
            raise CatalogError(f"{label}.{model_id} must be a non-empty object")
        unknown = set(facts) - METADATA_FIELDS
        if unknown:
            raise CatalogError(f"{label}.{model_id} has unknown fields {sorted(unknown)}")
        entry = {}
        for field in MODALITY_FIELDS:
            if field in facts:
                entry[field] = _normalize_modalities(
                    facts[field], f"{label}.{model_id}.{field}"
                )
        for field in BOOLEAN_METADATA_FIELDS:
            if field in facts:
                if not isinstance(facts[field], bool):
                    raise CatalogError(f"{label}.{model_id}.{field} must be a boolean")
                entry[field] = facts[field]
        for field in TOKEN_METADATA_FIELDS:
            if field in facts:
                token_count = facts[field]
                if isinstance(token_count, bool) or not isinstance(token_count, int):
                    raise CatalogError(f"{label}.{model_id}.{field} must be an integer")
                if not 1 <= token_count <= 10_000_000:
                    raise CatalogError(
                        f"{label}.{model_id}.{field} must be within 1...10000000"
                    )
                entry[field] = token_count
        if not entry:
            raise CatalogError(f"{label}.{model_id} must carry at least one fact")
        normalized[model_id] = entry
    return normalized


def _normalize_service_offers(value, label):
    if value is None:
        return None
    if not isinstance(value, list) or not value:
        raise CatalogError(f"{label} must be a non-empty array")
    if len(value) > 4:
        raise CatalogError(f"{label} exceeds the four-offer limit")
    roles = set()
    normalized = []
    for index, offer in enumerate(value):
        item_label = f"{label}[{index}]"
        if not isinstance(offer, dict):
            raise CatalogError(f"{item_label} must be an object")
        unknown = set(offer) - OFFER_FIELDS
        if unknown:
            raise CatalogError(f"{item_label} has unknown fields {sorted(unknown)}")
        role = offer.get("role")
        if role not in VALID_ROLES:
            raise CatalogError(f"{item_label}.role must be one of {list(VALID_ROLES)}")
        if role in roles:
            raise CatalogError(f"{label} contains duplicate role {role}")
        roles.add(role)
        models = offer.get("models")
        if not isinstance(models, list) or not models:
            raise CatalogError(f"{item_label}.models must be a non-empty array")
        if len(models) > 100:
            raise CatalogError(f"{item_label}.models exceeds the 100-identifier bound")
        checked = []
        for model_index, model_id in enumerate(models):
            checked.append(_model_identifier(
                model_id, f"{item_label}.models[{model_index}]"
            ))
        if len(set(checked)) != len(checked):
            raise CatalogError(f"{item_label}.models contains duplicates")
        entry = {"role": role, "models": sorted(checked)}
        if "baseURL" in offer and offer["baseURL"] is not None:
            entry["baseURL"] = _https_url(offer["baseURL"], f"{item_label}.baseURL")
        if "authStyle" in offer and offer["authStyle"] is not None:
            if offer["authStyle"] not in VALID_AUTH_STYLES:
                raise CatalogError(f"{item_label}.authStyle is unknown")
            entry["authStyle"] = offer["authStyle"]
        if "protocols" in offer and offer["protocols"] is not None:
            protocols = offer["protocols"]
            if not isinstance(protocols, list) or not 1 <= len(protocols) <= 3:
                raise CatalogError(f"{item_label}.protocols must have 1...3 entries")
            for protocol in protocols:
                if protocol not in VALID_PROTOCOLS:
                    raise CatalogError(f"{item_label}.protocols has unknown {protocol!r}")
            if len(set(protocols)) != len(protocols):
                raise CatalogError(f"{item_label}.protocols contains duplicates")
            entry["protocols"] = sorted(protocols)
        if "note" in offer and offer["note"] is not None:
            entry["note"] = _bounded_string(offer["note"], f"{item_label}.note", 256)
        normalized.append(entry)
    return normalized


def _normalize_patch(preset_id, patch):
    if not isinstance(patch, dict) or not patch:
        raise CatalogError(f"providerPatches.{preset_id} must be a non-empty object")
    unknown = set(patch) - PATCH_FIELDS
    if unknown:
        raise CatalogError(
            f"providerPatches.{preset_id} has unknown fields {sorted(unknown)}"
        )
    normalized = {}
    if "name" in patch:
        normalized["name"] = _bounded_string(
            patch["name"], f"providerPatches.{preset_id}.name", 128
        )
    if "serviceOffers" in patch:
        normalized["serviceOffers"] = _normalize_service_offers(
            patch["serviceOffers"], f"providerPatches.{preset_id}.serviceOffers"
        )
    if "modelMetadata" in patch:
        normalized["modelMetadata"] = _normalize_model_metadata(
            patch["modelMetadata"], f"providerPatches.{preset_id}.modelMetadata"
        )
    if not normalized:
        raise CatalogError(f"providerPatches.{preset_id} has no supported fields")
    return normalized


def _normalize_additional_provider(entry, index):
    label = f"additionalProviders[{index}]"
    if not isinstance(entry, dict):
        raise CatalogError(f"{label} must be an object")
    unknown = set(entry) - PROVIDER_FIELDS
    if unknown:
        raise CatalogError(f"{label} has unknown fields {sorted(unknown)}")
    missing = REQUIRED_PROVIDER_FIELDS - set(entry)
    if missing:
        raise CatalogError(f"{label} is missing fields {sorted(missing)}")
    preset_id = entry["presetID"]
    if not isinstance(preset_id, str) or not PRESET_ID_RE.fullmatch(preset_id):
        raise CatalogError(f"{label}.presetID is invalid")
    if preset_id in {config["presetID"] for config in CURATED}:
        raise CatalogError(f"{label}.presetID collides with the curated upstream set")
    name = _bounded_string(entry["name"], f"{label}.name", 128)
    aliases = entry["aliases"]
    if not isinstance(aliases, list) or len(aliases) > 16:
        raise CatalogError(f"{label}.aliases must be an array of at most 16 entries")
    checked_aliases = [
        _bounded_string(alias, f"{label}.aliases[{alias_index}]", 64)
        for alias_index, alias in enumerate(aliases)
    ]
    if len(set(checked_aliases)) != len(checked_aliases):
        raise CatalogError(f"{label}.aliases contains duplicates")
    kind = entry["kind"]
    if kind not in VALID_KINDS:
        raise CatalogError(f"{label}.kind is unknown")
    protocol = entry["defaultProtocol"]
    if protocol not in VALID_PROTOCOLS:
        raise CatalogError(f"{label}.defaultProtocol is unknown")
    base_url = entry["baseURL"]
    if base_url is not None:
        _https_url(base_url, f"{label}.baseURL")
    domains = entry["domains"]
    if not isinstance(domains, list) or len(domains) > 16:
        raise CatalogError(f"{label}.domains must be an array of at most 16 entries")
    checked_domains = []
    for domain_index, domain in enumerate(domains):
        domain = _bounded_string(
            domain, f"{label}.domains[{domain_index}]", 253
        )
        if not HOST_RE.fullmatch(domain):
            raise CatalogError(f"{label}.domains[{domain_index}] is not host-shaped")
        checked_domains.append(domain)
    if len(set(checked_domains)) != len(checked_domains):
        raise CatalogError(f"{label}.domains contains duplicates")
    models = entry["models"]
    if not isinstance(models, list) or not models:
        raise CatalogError(f"{label}.models must be a non-empty array")
    if len(models) > 200:
        raise CatalogError(f"{label}.models exceeds the 200-identifier bound")
    checked_models = [
        _model_identifier(model_id, f"{label}.models[{model_index}]")
        for model_index, model_id in enumerate(models)
    ]
    if len(set(checked_models)) != len(checked_models):
        raise CatalogError(f"{label}.models contains duplicates")
    availability = entry["availability"]
    if availability not in ("available", "unsupported"):
        raise CatalogError(f"{label}.availability is unknown")
    reason = entry["unsupportedReason"]
    if reason is not None:
        reason = _bounded_string(reason, f"{label}.unsupportedReason", 512)
    if availability == "available" and reason is not None:
        raise CatalogError(f"{label}: available entry must not carry unsupportedReason")
    if availability == "unsupported" and not reason:
        raise CatalogError(f"{label}: unsupported entry requires a reason")
    upstream_id = _bounded_string(
        entry["upstreamID"], f"{label}.upstreamID", 128
    )
    auth_style = entry["authStyle"]
    if auth_style not in VALID_AUTH_STYLES:
        raise CatalogError(f"{label}.authStyle is unknown")
    tool_compatibility = entry["toolNameCompatibility"]
    if not isinstance(tool_compatibility, bool):
        raise CatalogError(f"{label}.toolNameCompatibility must be a boolean")
    offers = _normalize_service_offers(entry.get("serviceOffers"), f"{label}.serviceOffers")
    metadata = _normalize_model_metadata(
        entry.get("modelMetadata"), f"{label}.modelMetadata"
    ) if entry.get("modelMetadata") is not None else None
    declared = set(checked_models)
    for offer in offers or []:
        declared.update(offer["models"])
    if metadata:
        undeclared = set(metadata) - declared
        if undeclared:
            raise CatalogError(
                f"{label}: metadata keys outside declared ids {sorted(undeclared)}"
            )
    if availability == "available":
        if base_url is None:
            raise CatalogError(f"{label}: available entry requires a baseURL")
        if kind in {"openAI", "volcengineArk", "alibabaStudio"}:
            if protocol not in {"openai-responses", "openai-chat-completions"}:
                raise CatalogError(f"{label}: {kind} requires an OpenAI protocol")
        elif kind == "anthropic" and protocol != "anthropic-messages":
            raise CatalogError(f"{label}: anthropic requires anthropic-messages")
        elif kind == "googleGemini" and protocol != "openai-chat-completions":
            raise CatalogError(
                f"{label}: googleGemini requires openai-chat-completions"
            )
        if kind == "local":
            if auth_style != "none":
                raise CatalogError(f"{label}: local kind requires authStyle none")
        elif protocol == "anthropic-messages":
            if auth_style != "apiKeyHeader":
                raise CatalogError(
                    f"{label}: anthropic-messages requires authStyle apiKeyHeader"
                )
        elif auth_style not in {"bearer", "apiKeyHeader"}:
            raise CatalogError(
                f"{label}: OpenAI protocols require bearer or apiKeyHeader"
            )
    normalized = {
        "presetID": preset_id,
        "name": name,
        "aliases": checked_aliases,
        "kind": kind,
        "defaultProtocol": protocol,
        "baseURL": base_url,
        "domains": sorted(checked_domains),
        "models": sorted(checked_models),
        "availability": availability,
        "unsupportedReason": reason,
        "upstreamID": upstream_id,
        "authStyle": auth_style,
        "toolNameCompatibility": tool_compatibility,
    }
    if offers is not None:
        normalized["serviceOffers"] = offers
    if metadata is not None:
        normalized["modelMetadata"] = metadata
    return normalized


def normalize_overrides(document):
    if not isinstance(document, dict):
        raise CatalogError("curated overrides must be a JSON object")
    allowed = {
        "schemaVersion", "revision", "reviewedAt", "upstreamPin", "policy",
        "provenance", "providerPatches", "additionalProviders",
    }
    unknown = set(document) - allowed
    if unknown:
        raise CatalogError(f"curated overrides has unknown fields {sorted(unknown)}")
    if (not isinstance(document.get("schemaVersion"), int)
            or isinstance(document.get("schemaVersion"), bool)
            or document.get("schemaVersion") != OVERRIDES_SCHEMA_VERSION):
        raise CatalogError(
            f"curated overrides schemaVersion must be {OVERRIDES_SCHEMA_VERSION}"
        )
    revision = _bounded_string(document.get("revision"), "revision", 64)
    if not REVISION_RE.fullmatch(revision):
        raise CatalogError("revision must look like YYYY-MM-DD.N")
    reviewed_at = _bounded_string(document.get("reviewedAt"), "reviewedAt", 64)
    pin = document.get("upstreamPin")
    if not isinstance(pin, dict):
        raise CatalogError("upstreamPin must be an object")
    pin_allowed = {"project", "url", "documentURL", "documentSHA256", "fetchedAt"}
    pin_unknown = set(pin) - pin_allowed
    if pin_unknown:
        raise CatalogError(f"upstreamPin has unknown fields {sorted(pin_unknown)}")
    if pin.get("project") != "models.dev":
        raise CatalogError("upstreamPin.project must be models.dev")
    for key in ("url", "documentURL", "fetchedAt"):
        _bounded_string(pin.get(key), f"upstreamPin.{key}", 256)
    digest = pin.get("documentSHA256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise CatalogError("upstreamPin.documentSHA256 must be 64 lowercase hex")
    policy = document.get("policy")
    if not isinstance(policy, dict):
        raise CatalogError("policy must be an object")
    for key in ("mergeOrder", "officialFacts", "noDiscovery", "sourceOfTruth"):
        _bounded_string(policy.get(key), f"policy.{key}", 512)
    provenance = document.get("provenance")
    if not isinstance(provenance, dict):
        raise CatalogError("provenance must be an object")
    for preset_id, record in provenance.items():
        if not isinstance(preset_id, str) or not PRESET_ID_RE.fullmatch(preset_id):
            raise CatalogError(f"provenance has invalid preset id {preset_id!r}")
        if not isinstance(record, dict):
            raise CatalogError(f"provenance.{preset_id} must be an object")
        _bounded_string(record.get("scope"), f"provenance.{preset_id}.scope", 256)
        sources = record.get("sources")
        if not isinstance(sources, list):
            raise CatalogError(f"provenance.{preset_id}.sources must be an array")
        for source_index, source in enumerate(sources):
            if not isinstance(source, dict):
                raise CatalogError(
                    f"provenance.{preset_id}.sources[{source_index}] must be an object"
                )
            _https_url(
                source.get("url"),
                f"provenance.{preset_id}.sources[{source_index}].url",
            )
            if "usedFor" in source:
                _bounded_string(
                    source["usedFor"],
                    f"provenance.{preset_id}.sources[{source_index}].usedFor",
                    512,
                )
            if "note" in source:
                _bounded_string(
                    source["note"],
                    f"provenance.{preset_id}.sources[{source_index}].note",
                    512,
                )
        if "note" in record:
            _bounded_string(record["note"], f"provenance.{preset_id}.note", 512)
    patches = document.get("providerPatches")
    if not isinstance(patches, dict) or not patches:
        raise CatalogError("providerPatches must be a non-empty object")
    curated_ids = {config["presetID"] for config in CURATED}
    normalized_patches = {}
    for preset_id in sorted(patches):
        if not isinstance(preset_id, str) or not PRESET_ID_RE.fullmatch(preset_id):
            raise CatalogError(f"providerPatches has invalid preset id {preset_id!r}")
        if preset_id not in curated_ids:
            raise CatalogError(
                f"providerPatches.{preset_id} does not target the curated upstream set"
            )
        normalized_patches[preset_id] = _normalize_patch(preset_id, patches[preset_id])
    additional = document.get("additionalProviders")
    if not isinstance(additional, list) or not additional:
        raise CatalogError("additionalProviders must be a non-empty array")
    if len(additional) > 64:
        raise CatalogError("additionalProviders exceeds the 64-entry limit")
    normalized_additional = []
    additional_ids = set()
    for index, entry in enumerate(additional):
        normalized = _normalize_additional_provider(entry, index)
        if normalized["presetID"] in additional_ids:
            raise CatalogError(
                f"duplicate additional provider {normalized['presetID']}"
            )
        if normalized["presetID"] in normalized_patches:
            raise CatalogError(
                f"{normalized['presetID']} cannot be both patched and additional"
            )
        additional_ids.add(normalized["presetID"])
        normalized_additional.append(normalized)
    expected_provenance = set(normalized_patches) | additional_ids
    if set(provenance) != expected_provenance:
        raise CatalogError(
            "provenance must cover exactly the patched and additional providers "
            f"(expected {sorted(expected_provenance)}, got {sorted(provenance)})"
        )
    return {
        "schemaVersion": OVERRIDES_SCHEMA_VERSION,
        "revision": revision,
        "reviewedAt": reviewed_at,
        "upstreamPin": {
            "project": pin["project"],
            "url": pin["url"],
            "documentURL": pin["documentURL"],
            "documentSHA256": digest,
            "fetchedAt": pin["fetchedAt"],
        },
        "policy": dict(policy),
        "provenance": dict(provenance),
        "providerPatches": normalized_patches,
        "additionalProviders": normalized_additional,
    }


def load_overrides(path=None):
    path = OVERRIDES_PATH if path is None else Path(path)
    if not path.is_file():
        raise CatalogError(f"curated overrides file is missing: {path}")
    raw = path.read_bytes()
    if len(raw) > 1_048_576:
        raise CatalogError("curated overrides file exceeds the 1 MiB limit")
    try:
        document = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        raise CatalogError(f"curated overrides is not valid JSON: {error}") from error
    return normalize_overrides(document), raw


def _as_catalog_provider(entry):
    provider = {
        "presetID": entry["presetID"],
        "name": entry["name"],
        "aliases": list(entry["aliases"]),
        "kind": entry["kind"],
        "defaultProtocol": entry["defaultProtocol"],
        "baseURL": entry["baseURL"],
        "domains": list(entry["domains"]),
        "models": list(entry["models"]),
        "availability": entry["availability"],
        "unsupportedReason": entry["unsupportedReason"],
        "upstreamID": entry["upstreamID"],
        "authStyle": entry["authStyle"],
        "toolNameCompatibility": entry["toolNameCompatibility"],
    }
    if "serviceOffers" in entry:
        provider["serviceOffers"] = copy.deepcopy(entry["serviceOffers"])
    if "modelMetadata" in entry:
        provider["modelMetadata"] = copy.deepcopy(entry["modelMetadata"])
    return provider


def merge_provider_overrides(providers, overrides):
    merged = []
    by_id = {}
    for provider in providers:
        if not isinstance(provider, dict) or "presetID" not in provider:
            raise CatalogError("generated provider is malformed")
        preset_id = provider["presetID"]
        if preset_id in by_id:
            raise CatalogError(f"duplicate generated provider {preset_id}")
        copy_provider = dict(provider)
        copy_provider["aliases"] = list(provider.get("aliases") or [])
        copy_provider["domains"] = list(provider.get("domains") or [])
        copy_provider["models"] = list(provider.get("models") or [])
        merged.append(copy_provider)
        by_id[preset_id] = copy_provider
    for preset_id in sorted(overrides["providerPatches"]):
        if preset_id not in by_id:
            raise CatalogError(
                f"providerPatches.{preset_id} targets a provider absent from the document"
            )
        target = by_id[preset_id]
        patch = overrides["providerPatches"][preset_id]
        if "name" in patch:
            target["name"] = patch["name"]
        if "serviceOffers" in patch:
            target["serviceOffers"] = copy.deepcopy(patch["serviceOffers"])
        if "modelMetadata" in patch:
            metadata = dict(target.get("modelMetadata") or {})
            for model_id, facts in patch["modelMetadata"].items():
                if model_id in metadata:
                    raise CatalogError(
                        f"{preset_id}: override metadata conflicts with generated "
                        f"metadata for {model_id}"
                    )
                metadata[model_id] = copy.deepcopy(facts)
            target["modelMetadata"] = metadata
    for entry in overrides["additionalProviders"]:
        preset_id = entry["presetID"]
        if preset_id in by_id:
            raise CatalogError(f"additional provider {preset_id} already exists")
        provider = _as_catalog_provider(entry)
        merged.append(provider)
        by_id[preset_id] = provider
    for provider in merged:
        declared = set(provider["models"])
        for offer in provider.get("serviceOffers") or []:
            declared.update(offer["models"])
        undeclared = set(provider.get("modelMetadata") or {}) - declared
        if undeclared:
            raise CatalogError(
                f"{provider['presetID']}: metadata keys outside declared ids "
                f"{sorted(undeclared)}"
            )
        if provider["models"] != sorted(provider["models"]):
            raise CatalogError(f"{provider['presetID']}: model list is not sorted")
        for offer in provider.get("serviceOffers") or []:
            if offer["models"] != sorted(offer["models"]):
                raise CatalogError(
                    f"{provider['presetID']}: {offer['role']} offer is not sorted"
                )
    return merged


def verify_overrides_represented(providers, overrides):
    by_id = {}
    for provider in providers:
        if provider["presetID"] in by_id:
            raise CatalogError(f"duplicate committed provider {provider['presetID']}")
        by_id[provider["presetID"]] = provider
    for preset_id, patch in overrides["providerPatches"].items():
        target = by_id.get(preset_id)
        if target is None:
            raise CatalogError(f"committed catalog is missing patched provider {preset_id}")
        if "name" in patch and target.get("name") != patch["name"]:
            raise CatalogError(f"{preset_id}: committed name does not match override")
        if "serviceOffers" in patch and target.get("serviceOffers") != patch["serviceOffers"]:
            raise CatalogError(
                f"{preset_id}: committed serviceOffer does not match override"
            )
        for model_id, facts in patch.get("modelMetadata", {}).items():
            if (target.get("modelMetadata") or {}).get(model_id) != facts:
                raise CatalogError(
                    f"{preset_id}: committed metadata for {model_id} does not match override"
                )
    additional_ids = [entry["presetID"] for entry in overrides["additionalProviders"]]
    for entry in overrides["additionalProviders"]:
        target = by_id.get(entry["presetID"])
        if target is None:
            raise CatalogError(
                f"committed catalog is missing additional provider {entry['presetID']}"
            )
        if target != _as_catalog_provider(entry):
            raise CatalogError(
                f"{entry['presetID']}: committed entry does not match the declarative "
                "additional provider"
            )
    if [provider["presetID"] for provider in providers[-len(additional_ids):]] != additional_ids:
        raise CatalogError(
            "additional providers must appear after the upstream baseline in declared order"
        )


def source_record_problems(source, document, overrides, overrides_raw):
    problems = []
    if not isinstance(source, dict):
        return ["SOURCE.json is missing or not an object"]
    document_source = document.get("source") or {}
    digest = overrides["upstreamPin"]["documentSHA256"]
    if document_source.get("documentSHA256") != digest:
        problems.append("bundled source.documentSHA256 does not match the override pin")
    if source.get("documentSHA256") != digest:
        problems.append("SOURCE.json documentSHA256 does not match the override pin")
    if source.get("fetchedAt") != document_source.get("fetchedAt"):
        problems.append("SOURCE.json fetchedAt does not match the bundled document")
    if overrides["upstreamPin"]["fetchedAt"] != document_source.get("fetchedAt"):
        problems.append("curated-overrides.json upstreamPin.fetchedAt is stale")
    if source.get("providerCount") != len(document.get("providers") or []):
        problems.append("SOURCE.json providerCount is stale")
    providers = document.get("providers") or []
    expected_counts = {
        "availableCount": sum(
            1 for provider in providers if provider.get("availability") == "available"
        ),
        "unsupportedCount": sum(
            1 for provider in providers if provider.get("availability") == "unsupported"
        ),
        "modelEntryCount": sum(len(provider.get("models") or []) for provider in providers),
        "modelMetadataEntryCount": sum(
            len(provider.get("modelMetadata") or {}) for provider in providers
        ),
        "serviceOfferCount": sum(
            len(provider.get("serviceOffers") or []) for provider in providers
        ),
    }
    for key, value in expected_counts.items():
        if source.get(key) != value:
            problems.append(f"SOURCE.json {key} should be {value}")
    curated = source.get("curatedOverrides")
    if not isinstance(curated, dict):
        problems.append("SOURCE.json curatedOverrides is missing")
    else:
        if curated.get("sha256") != hashlib.sha256(overrides_raw).hexdigest():
            problems.append("SOURCE.json curatedOverrides.sha256 is stale")
        if curated.get("revision") != overrides["revision"]:
            problems.append("SOURCE.json curatedOverrides.revision is stale")
        if curated.get("path") != OVERRIDES_PATH.relative_to(REPO_ROOT).as_posix():
            problems.append("SOURCE.json curatedOverrides.path is stale")
        if curated.get("upstreamDocumentSHA256") != digest:
            problems.append("SOURCE.json curatedOverrides pin is stale")
    return problems


def check_offline():
    try:
        overrides, overrides_raw = load_overrides()
    except CatalogError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    if not OUTPUT_PATH.is_file() or not PUBLISHED_PATH.is_file():
        print("FAIL: bundled or published catalog is missing", file=sys.stderr)
        return 1
    bundled_bytes = OUTPUT_PATH.read_bytes()
    published_bytes = PUBLISHED_PATH.read_bytes()
    if bundled_bytes != published_bytes:
        print(
            "FAIL: content-hub/providers/ProviderCatalog.json differs from the "
            "bundled resource; rerun the importer",
            file=sys.stderr,
        )
        return 1
    try:
        document = json.loads(bundled_bytes.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        print(f"FAIL: committed catalog is not valid JSON: {error}", file=sys.stderr)
        return 1
    try:
        verify_overrides_represented(document["providers"], overrides)
    except (CatalogError, KeyError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    source = load_source_record()
    problems = source_record_problems(source, document, overrides, overrides_raw)
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}", file=sys.stderr)
        return 1
    print(
        "PASS (offline): bundled/published copies match, declarative overrides "
        f"{overrides['revision']} are represented, SOURCE.json is current; "
        "the pinned network upstream check was NOT executed"
    )
    return 0


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
    modalities = (model or {}).get("modalities") or {}
    output = modalities.get("output") or []
    if mode == "output_image":
        return "image" in output
    if mode == "output_text_tool":
        # Chat-capable inference models: text output AND upstream tool_call.
        # This excludes embedding and audio-only models without guessing.
        return "text" in output and (model or {}).get("tool_call") is True
    raise CatalogError(f"unknown model filter: {mode}")


def collect_models(config, document):
    """Merged {identifier: upstream model} across every upstream id."""
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
    return models


def selected_models(config, document, mode, limit):
    models = collect_models(config, document)
    selected = [
        identifier for identifier in sorted(models)
        if matches_filter(models[identifier], mode)
    ]
    return cap_models(selected, models, limit)


def entry_models(config, document):
    return selected_models(config, document, config["modelFilter"], MAX_MODELS_PER_PROVIDER)


def entry_service_offers(config, document):
    specs = config.get("serviceOffers") or []
    if not specs:
        return None
    offers = []
    for spec in specs:
        models = selected_models(config, document, spec["modelFilter"], MAX_OFFER_MODELS)
        offer = {"role": spec["role"], "models": models}
        for key in ("baseURL", "authStyle", "protocols", "note"):
            if spec.get(key) is not None:
                offer[key] = spec[key]
        offers.append(offer)
    return offers or None


def model_metadata(model):
    """Narrow, non-secret capability facts for one upstream model entry."""
    if not isinstance(model, dict):
        return None
    modalities = model.get("modalities") or {}
    metadata = {}
    for key, upstream_key in (("input", "input"), ("output", "output")):
        values = modalities.get(upstream_key) or []
        normalized = sorted({
            str(value) for value in values if str(value) in KNOWN_MODALITIES
        })
        if normalized:
            metadata[key] = normalized
    for field, upstream_key in (
        ("toolCall", "tool_call"),
        ("attachment", "attachment"),
        ("reasoning", "reasoning"),
    ):
        value = model.get(upstream_key)
        if isinstance(value, bool):
            metadata[field] = value
    return metadata or None


def entry_model_metadata(config, document, identifiers):
    """Per-model metadata for exactly the identifiers this entry declares."""
    if config["availability"] != "available":
        # Unsupported entries are never offered for adding; skip their
        # metadata so the document stays small.
        return None
    models = collect_models(config, document)
    metadata = {}
    for identifier in sorted(set(identifiers)):
        facts = model_metadata(models.get(identifier))
        if facts:
            metadata[identifier] = facts
    return metadata or None


def cap_models(identifiers, models, limit):
    if len(identifiers) <= limit:
        return identifiers
    identifiers = sorted(
        identifiers,
        key=lambda item: (model_recency(models.get(item) or {}), item),
        reverse=True,
    )[:limit]
    return sorted(identifiers)


def build_provider(config, document):
    missing = [item for item in config["upstream"] if item not in document]
    if missing:
        raise CatalogError(
            f"{config['presetID']}: upstream provider(s) missing from document: {missing}"
        )
    models = entry_models(config, document)
    offers = entry_service_offers(config, document)
    referenced = list(models)
    for offer in offers or []:
        referenced.extend(offer["models"])
    provider = {
        "presetID": config["presetID"],
        "name": config["name"],
        "aliases": sorted(config["aliases"]),
        "kind": config["kind"],
        "defaultProtocol": config["defaultProtocol"],
        "baseURL": config["baseURL"],
        "domains": sorted(config["domains"]),
        "models": models,
        "availability": config["availability"],
        "unsupportedReason": config["unsupportedReason"],
        "upstreamID": config["upstream"][0],
        "upstreamIDs": list(config["upstream"]),
        "authStyle": config["authStyle"],
        "toolNameCompatibility": config["toolNameCompatibility"],
    }
    metadata = entry_model_metadata(config, document, referenced)
    if metadata:
        provider["modelMetadata"] = metadata
    if offers:
        provider["serviceOffers"] = offers
    return provider


def build_document(document, raw, fetched_at, overrides=None):
    if overrides is None:
        overrides, _ = load_overrides()
    providers = [build_provider(config, document) for config in CURATED]
    providers = merge_provider_overrides(providers, overrides)
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


def make_source_record(raw, document, fetched_at, overrides=None,
                       overrides_raw=None, revision_info=None):
    if overrides is None or overrides_raw is None:
        loaded, loaded_raw = load_overrides()
        if overrides is None:
            overrides = loaded
        if overrides_raw is None:
            overrides_raw = loaded_raw
    if revision_info is None:
        revision, revision_date = fetch_git_revision()
    else:
        revision, revision_date = revision_info
    providers = document["providers"]
    available = sum(1 for p in providers if p["availability"] == "available")
    unsupported = len(providers) - available
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
        "providerCount": len(providers),
        "availableCount": available,
        "unsupportedCount": unsupported,
        "modelEntryCount": sum(len(p["models"]) for p in providers),
        "modelMetadataEntryCount": sum(
            len(p.get("modelMetadata") or {}) for p in providers
        ),
        "serviceOfferCount": sum(
            len(p.get("serviceOffers") or []) for p in providers
        ),
        "serviceOfferModelEntryCount": sum(
            len(offer.get("models") or [])
            for p in providers
            for offer in (p.get("serviceOffers") or [])
        ),
        "generatedBy": "content-hub/providers/import_models_dev.py",
        "generatedWith": [
            "content-hub/providers/import_models_dev.py",
            OVERRIDES_PATH.relative_to(REPO_ROOT).as_posix(),
        ],
        "curatedOverrides": {
            "path": OVERRIDES_PATH.relative_to(REPO_ROOT).as_posix(),
            "sha256": hashlib.sha256(overrides_raw).hexdigest(),
            "revision": overrides["revision"],
            "reviewedAt": overrides["reviewedAt"],
            "upstreamDocumentSHA256": overrides["upstreamPin"]["documentSHA256"],
            "additionalProviderCount": len(overrides["additionalProviders"]),
            "patchedProviderCount": len(overrides["providerPatches"]),
            "note": (
                "Official plan entries and PAYG media rows come from first-party "
                "Floe review, not models.dev. The models.dev documentSHA256 pin "
                "covers the upstream baseline only."
            ),
        },
        "attributionNotes": [
            "Provider names, model identifiers and documentation links in the upstream baseline are derived from the open models.dev catalog (MIT).",
            "Floe curates, filters and maps the data to its own provider kinds, protocols and auth styles.",
            "No upstream code, JS SDK content, API keys or user credentials are copied.",
            "Merged upstream ids are listed in each provider's upstreamIDs field.",
            "Official Volcengine Agent Plan / Alibaba Token Plan entries and the patched PAYG media rows are first-party Floe review facts declared in curated-overrides.json; they are not models.dev content.",
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


def check(document, raw, overrides=None):
    if overrides is None:
        try:
            overrides, overrides_raw = load_overrides()
        except CatalogError as error:
            print(f"FAIL: {error}", file=sys.stderr)
            return 1
    else:
        try:
            overrides_raw = OVERRIDES_PATH.read_bytes()
        except OSError as error:
            print(f"FAIL: cannot read curated overrides: {error}", file=sys.stderr)
            return 1
    if not OUTPUT_PATH.is_file():
        print(f"FAIL: committed catalog missing: {OUTPUT_PATH}", file=sys.stderr)
        return 1
    committed_bytes = OUTPUT_PATH.read_bytes()
    fetched_at = committed_fetched_at()
    if fetched_at is None:
        print("FAIL: committed catalog has no source.fetchedAt", file=sys.stderr)
        return 1
    digest = hashlib.sha256(raw).hexdigest()
    if overrides["upstreamPin"]["documentSHA256"] != digest:
        print(
            "FAIL: pinned api.json hash does not match curated-overrides.json "
            "upstreamPin.documentSHA256",
            file=sys.stderr,
        )
        return 1
    regenerated = build_document(document, raw, fetched_at, overrides)
    expected = canonical(regenerated)
    if expected != committed_bytes:
        print(
            "FAIL: committed ProviderCatalog.json does not match the pinned document "
            "plus declarative overrides (run --update-source to re-pin and regenerate)",
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
    source = load_source_record()
    problems = source_record_problems(source, regenerated, overrides, overrides_raw)
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}", file=sys.stderr)
        return 1
    print(
        "PASS: ProviderCatalog.json matches the pinned models.dev document {} plus "
        "curated overrides {} ({} providers)".format(
            digest[:12], overrides["revision"], len(regenerated["providers"])
        )
    )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="read-only verification")
    parser.add_argument(
        "--check-offline", action="store_true",
        help="read-only local verification without the pinned upstream document",
    )
    parser.add_argument(
        "--update-source", action="store_true",
        help="explicitly re-pin to the downloaded document and rewrite SOURCE.json",
    )
    parser.add_argument(
        "--api-json", metavar="PATH",
        help="use a local models.dev api.json snapshot instead of the network",
    )
    args = parser.parse_args(argv)
    if sum((args.check, args.check_offline, args.update_source)) > 1:
        print(
            "FAIL: --check, --check-offline and --update-source are mutually exclusive",
            file=sys.stderr,
        )
        return 1
    try:
        overrides, overrides_raw = load_overrides()
    except CatalogError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    if args.check_offline:
        return check_offline()

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
            if overrides["upstreamPin"]["documentSHA256"] != digest:
                print(
                    "FAIL: update curated-overrides.json upstreamPin explicitly "
                    "before re-pinning; the declarative pin still names "
                    f"{overrides['upstreamPin']['documentSHA256'][:12]}",
                    file=sys.stderr,
                )
                return 1
            built = build_document(document, raw, fetched_at, overrides)
            source_record = make_source_record(
                raw, built, fetched_at, overrides, overrides_raw
            )
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
        if overrides["upstreamPin"]["documentSHA256"] != digest:
            print(
                "FAIL: downloaded api.json hash does not match "
                "curated-overrides.json upstreamPin.documentSHA256; update the "
                "declarative pin together with SOURCE.json explicitly",
                file=sys.stderr,
            )
            return 1

        if args.check:
            return check(document, raw, overrides)

        effective_fetched_at = committed_fetched_at() or fetched_at
        built = build_document(document, raw, effective_fetched_at, overrides)
        expected = canonical(built)
        if OUTPUT_PATH.is_file() and OUTPUT_PATH.read_bytes() == expected:
            print(
                "Up to date: ProviderCatalog.json already matches pinned document {} "
                "plus curated overrides {} ({} providers)".format(
                    digest[:12], overrides["revision"], len(built["providers"])
                )
            )
            return 0
        write_outputs(built, None, write_source=False)
        print(f"Regenerated from pinned document {digest} plus curated overrides")
        return 0
    except (CatalogError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
