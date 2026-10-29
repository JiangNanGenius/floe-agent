"""Offline checks for the provider-catalog importer.

No network access and no repository writes: synthetic upstream documents drive
the pure builder, declarative-override merge/conflict checks run against the
versioned config, and invariants cover the committed ProviderCatalog.json plus
the mutable content-package declaration. Run with:
  python3 content-hub/providers/test_import_models_dev.py
"""
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import import_models_dev as imp  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
BUNDLED = REPO_ROOT / "FloeAgent" / "FloeApp" / "Resources" / "ProviderCatalog.json"
PUBLISHED = REPO_ROOT / "content-hub" / "providers" / "ProviderCatalog.json"
PUBLISHED_SOURCE_COPY = (
    REPO_ROOT / "content-hub" / "sources" / "providers"
    / "floe.providers.compatibility" / "ProviderCatalog.json"
)
OVERRIDES = REPO_ROOT / "content-hub" / "providers" / "curated-overrides.json"
CONTENT = (
    REPO_ROOT / "content-hub" / "sources" / "providers"
    / "floe.providers.compatibility" / "content.json"
)

MODALITIES = ("text", "image", "audio", "video", "pdf")


def model(document, provider_id, model_id, **fields):
    document.setdefault(provider_id, {"models": {}})
    document[provider_id]["models"][model_id] = {"id": model_id, **fields}
    return document


def synthetic_document():
    """Two upstream providers with deliberately messy metadata."""
    document = {}
    model(document, "vendor", "vision-chat",
          modalities={"input": ["text", "image", "bogus"], "output": ["text"]},
          tool_call=True, attachment=True, reasoning=True)
    model(document, "vendor", "plain-chat",
          modalities={"input": ["text"], "output": ["text"]},
          tool_call=True)
    model(document, "vendor", "image-maker",
          modalities={"input": ["text", "image"], "output": ["image"]},
          tool_call=False)
    model(document, "vendor", "silent-model",
          modalities={"input": ["audio"], "output": ["audio"]})
    model(document, "vendor", "no-metadata")
    model(document, "images", "pic-one",
          modalities={"input": ["text"], "output": ["image"]})
    model(document, "images", "pic-two",
          modalities={"input": ["text"], "output": ["image"]},
          tool_call=False)
    return document


def full_synthetic_document():
    """Synthetic document that satisfies every CURATED upstream id."""
    document = synthetic_document()
    for config in imp.CURATED:
        for upstream_id in config["upstream"]:
            document.setdefault(upstream_id, {"models": {}})
    return document


def synthetic_config(**overrides):
    config = dict(
        presetID="vendor", upstream=["vendor"], name="Vendor",
        aliases=["Vendor"], kind="custom",
        defaultProtocol="openai-chat-completions",
        baseURL="https://api.vendor.example/v1", domains=["api.vendor.example"],
        authStyle="bearer", availability="available", unsupportedReason=None,
        toolNameCompatibility=False, modelFilter=None, serviceOffers=None,
    )
    config.update(overrides)
    return config


class ModelMetadataTests(unittest.TestCase):
    def test_metadata_is_narrow_sorted_and_omits_unknown_tokens(self):
        document = synthetic_document()
        models = imp.collect_models(synthetic_config(), document)
        facts = imp.model_metadata(models["vision-chat"])
        self.assertEqual(facts["input"], ["image", "text"])
        self.assertEqual(facts["output"], ["text"])
        self.assertTrue(facts["toolCall"])
        self.assertTrue(facts["attachment"])
        self.assertTrue(facts["reasoning"])
        self.assertNotIn("bogus", facts["input"])

    def test_absent_modalities_and_flags_are_omitted_not_invented(self):
        document = synthetic_document()
        models = imp.collect_models(synthetic_config(), document)
        self.assertIsNone(imp.model_metadata(models["no-metadata"]))
        silent = imp.model_metadata(models["silent-model"])
        self.assertEqual(silent, {"input": ["audio"], "output": ["audio"]})
        self.assertNotIn("toolCall", silent)

    def test_entry_metadata_covers_declared_ids_only_and_skips_unsupported(self):
        document = synthetic_document()
        config = synthetic_config(
            serviceOffers=[dict(role="conversation",
                                baseURL="https://api.vendor.example/v1beta",
                                authStyle="bearer",
                                protocols=["openai-chat-completions"],
                                modelFilter="output_text_tool")],
        )
        built = imp.build_provider(config, document)
        declared = set(built["models"])
        for offer in built["serviceOffers"]:
            declared.update(offer["models"])
        self.assertTrue(set(built["modelMetadata"]).issubset(declared))
        self.assertIn("vision-chat", built["modelMetadata"])
        self.assertIn("plain-chat", built["modelMetadata"])
        self.assertNotIn("no-metadata", built["modelMetadata"])

        unsupported = imp.build_provider(
            synthetic_config(availability="unsupported",
                             unsupportedReason="requires OAuth device flow"),
            document,
        )
        self.assertNotIn("modelMetadata", unsupported)

    def test_output_text_tool_filter_requires_text_output_and_tool_call(self):
        document = synthetic_document()
        config = synthetic_config()
        # vision-chat and plain-chat qualify; image-maker outputs an image and
        # silent-model/the embedding-like entry output audio only.
        selected = imp.selected_models(config, document, "output_text_tool", 10)
        self.assertEqual(selected, ["plain-chat", "vision-chat"])

    def test_offer_models_are_capped_by_recency(self):
        document = {}
        for index in range(imp.MAX_OFFER_MODELS + 5):
            model(document, "vendor", f"chat-{index:02d}",
                  modalities={"input": ["text"], "output": ["text"]},
                  tool_call=True,
                  last_updated=f"2026-01-{index + 1:02d}")
        config = synthetic_config(
            serviceOffers=[dict(role="conversation",
                                protocols=["openai-chat-completions"],
                                modelFilter="output_text_tool")],
        )
        built = imp.build_provider(config, document)
        offer_models = built["serviceOffers"][0]["models"]
        self.assertEqual(len(offer_models), imp.MAX_OFFER_MODELS)
        self.assertIn("chat-29", offer_models)  # newest by last_updated
        self.assertNotIn("chat-00", offer_models)
        self.assertEqual(offer_models, sorted(offer_models))

    def test_unknown_filter_is_rejected(self):
        with self.assertRaises(imp.CatalogError):
            imp.selected_models(synthetic_config(), synthetic_document(), "nonexistent", 10)

    def test_document_build_is_deterministic(self):
        document = full_synthetic_document()
        raw = json.dumps(document, sort_keys=True).encode("utf-8")
        first = imp.canonical(imp.build_document(document, raw, "2026-10-15T00:00:00Z"))
        second = imp.canonical(imp.build_document(document, raw, "2026-10-15T00:00:00Z"))
        self.assertEqual(first, second)


UNTOUCHED_PROVIDER_DIGESTS = {
    'openai': '6094cde564a6dd902127b8dbcadf8ef051cea1ec2f1471515c4a5403fe71a3e6',
    'anthropic': '18dcb6d4cebe6d0cca5a2079ce754e4294383f227990a1ba0da9c56b1d6688ca',
    'google': 'ca819aaa9e6e24e6df55291d7824350fa08d9bbdbce0104efa0cb7d9f31ba0c8',
    'deepseek': '60fb04639556045b4d1bd129f6c0f876bffd0606e786ce4033de2d4b9b50052b',
    'moonshot': 'ff51d55979404d00064154e4dbbcf26c178d944e66cd92372c0bc4e64c2c32dd',
    'zhipu': '8c63d48982778f72f4d51710a4292a07b57ae76e8be7c4013545583bf841ebd5',
    'minimax': 'ec86615f332022ed40a056ebc5ec70b11da3937637fd38449f022ceca923f875',
    'xai': '446c2d012b31704fd25980138c98a16ff3c23c3561a40cb5d41afa40b53e82a7',
    'groq': '1d6ccdcdb54d4aba1d0ea342ad088ca3d88b32ce87adcae865d13bb00c185429',
    'mistral': 'c71087f5ca621b660677ee511b028800c372cf0438e20ff59162e3e366b3b72c',
    'together': 'ca67554a8f1bcbfa4b5fdb6f1f63d8e22f88457a9b962de05ee54a367c382614',
    'openrouter': 'e1d61e4a41398c633842c6ebf5d265b4b468de4dc249fcc09344f0e427e0d593',
    'fireworks': '684f57abd19e1c2b1ad923ab597c2dcd33ad3fdaf2825c407da948681d931083',
    'siliconflow': '7b96eb0adabb242a27d483042d7560b74a54449ef7041da55680623d43063331',
    'github-copilot': 'b404a79bff9ed7464ed9ae9a8ab85766bd325526c23de0d4522cc5be7311b3fb',
    'azure': '0ca88210731848e671cfcab54fbf7238b9a1809aaeddbf2c8cefac1b578111eb',
    'amazon-bedrock': '3c093bb8ce596603100526b3d5f74ddcd5760c33fe3fc9aa44530375761d6a8e',
    'google-vertex': '9674a3a934fa0915972ad9f32b2be0f93fd43bf9db4e99401a00182a966f8cb0',
}
ALIBABA_MODELS_DIGEST = '4df38185723829d601fe5d1613f949cd0405cc506b722bdc41ee24d0f0b6c8e4'
ALIBABA_BASE_METADATA_DIGEST = 'b259ada0a6a21c53a8cc425e4f88779d4f73a7cd1810158c3287e48303a4044f'
ALIBABA_STABLE_FIELDS_DIGEST = 'ea276cb53b24777c31b35caafbfbe16f7553cf2c2c4706f03a580879b37a08b5'
VOLCENGINE_STABLE_FIELDS_DIGEST = '3840e13de407ee4b6a4e6d2600520f5563d2e986bd6281ef468c563eaa7d95bd'
PIN = '4f5cb775b475a8f3dc0253c986223ca8dcd55a21f29ab3e036e397e560879eef'
AGENT_PLAN_MODELS = [
    "ark-code-latest",
    "deepseek-v4-flash",
    "deepseek-v4-pro",
    "deepseek-v4.1-flash",
    "deepseek-v4.1-flash-economy",
    "doubao-seed-2.0-mini",
    "doubao-seed-2.1-lite",
    "doubao-seed-2.1-pro",
    "doubao-seed-evolving",
    "glm-5.3",
    "glm-5.3-flash",
    "kimi-k2.8-preview",
    "kimi-k3",
    "kimi-k3.1-pro",
]
TOKEN_PLAN_MODELS = [
    "auto",
    "deepseek-v4-flash-0731",
    "deepseek-v4-pro",
    "deepseek-v4-pro-0813",
    "deepseek-v4.1-flash",
    "deepseek-v4.1-flash-1017",
    "glm-5.2",
    "glm-5.3",
    "qwen3.6-flash",
    "qwen3.7-max",
    "qwen3.7-plus",
    "qwen3.8-flash",
    "qwen3.8-max",
]
AGENT_PLAN_IMAGE = [
    "doubao-seedream-5-0-pro",
    "doubao-seedream-5.0-flash",
    "doubao-seedream-5.0-lite",
]
TOKEN_PLAN_IMAGE = ["qwen-image-3.0-pro", "wan2.7-image", "wan2.7-image-pro"]
TOKEN_PLAN_VIDEO = ["happyhorse-1.1-i2v", "happyhorse-1.1-t2v", "wan3.0-video"]
ADDED_ALIBABA_METADATA = {
    "qwen-image-2.1-pro",
    "qwen-image-2.1-turbo",
    "qwen-image-3.0",
    "qwen-image-3.0-pro",
    "wan2.7-image",
    "wan2.7-image-pro",
    "wan3.0-video",
}


def digest(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    ).hexdigest()


class CommittedCatalogTests(unittest.TestCase):
    def load(self):
        with BUNDLED.open("rb") as handle:
            return json.load(handle)

    def providers(self):
        return {provider["presetID"]: provider for provider in self.load()["providers"]}

    def test_bundled_published_and_package_copies_are_identical(self):
        expected = BUNDLED.read_bytes()
        self.assertEqual(expected, PUBLISHED.read_bytes())
        self.assertEqual(expected, PUBLISHED_SOURCE_COPY.read_bytes())

    def test_committed_metadata_invariants(self):
        document = self.load()
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["source"]["project"], "models.dev")
        self.assertEqual(document["source"]["license"], "MIT")
        self.assertEqual(document["source"]["documentSHA256"], PIN)
        offered = 0
        metadata_count = 0
        model_count = 0
        provider_fields = {
            "presetID", "name", "aliases", "kind", "defaultProtocol", "baseURL",
            "domains", "models", "availability", "unsupportedReason", "upstreamID",
            "authStyle", "toolNameCompatibility", "serviceOffers", "modelMetadata",
            "upstreamIDs",
        }
        metadata_fields = {
            "input", "output", "toolCall", "attachment", "reasoning",
            "contextTokens", "maxOutputTokens",
        }
        for provider in document["providers"]:
            self.assertTrue(set(provider).issubset(provider_fields))
            declared = set(provider["models"])
            model_count += len(declared)
            roles = set()
            for offer in provider.get("serviceOffers") or []:
                self.assertLessEqual(len(offer["models"]), 100)
                self.assertTrue(offer["models"])
                self.assertEqual(offer["models"], sorted(offer["models"]))
                self.assertNotIn(offer["role"], roles)
                roles.add(offer["role"])
                declared.update(offer["models"])
                if offer["role"] == "conversation" and provider["presetID"] == "google":
                    self.assertEqual(
                        offer["baseURL"],
                        "https://generativelanguage.googleapis.com/v1beta/openai",
                    )
                    self.assertEqual(offer["authStyle"], "bearer")
                    self.assertEqual(offer["protocols"], ["openai-chat-completions"])
            metadata = provider.get("modelMetadata") or {}
            metadata_count += len(metadata)
            self.assertTrue(set(metadata).issubset(declared),
                            f"{provider['presetID']}: metadata key outside declared ids")
            if provider["availability"] == "unsupported":
                self.assertEqual(metadata, {})
            for facts in metadata.values():
                self.assertTrue(set(facts).issubset(metadata_fields))
                self.assertTrue(facts)
                for key in ("input", "output"):
                    if key not in facts:
                        continue
                    for modality in facts[key]:
                        self.assertIn(modality, MODALITIES)
                    self.assertEqual(facts[key], sorted(set(facts[key])))
                for key in ("toolCall", "attachment", "reasoning"):
                    if key in facts:
                        self.assertIsInstance(facts[key], bool)
                for key in ("contextTokens", "maxOutputTokens"):
                    if key in facts:
                        self.assertIsInstance(facts[key], int)
                        self.assertGreaterEqual(facts[key], 1)
                        self.assertLessEqual(facts[key], 10_000_000)
            if provider["availability"] == "available":
                offered += 1
                self.assertIsNotNone(provider["baseURL"])
        self.assertEqual(offered, 18)
        self.assertEqual(model_count, 609)
        self.assertEqual(metadata_count, 459)

    def test_plan_entries_are_exact_and_agent_plan_has_no_video(self):
        providers = self.providers()
        agent = providers["volcengine-agent-plan"]
        self.assertEqual(agent["models"], AGENT_PLAN_MODELS)
        self.assertEqual(agent["serviceOffers"], [{"models": AGENT_PLAN_IMAGE, "role": "image"}])
        self.assertEqual(len(agent["modelMetadata"]), 17)
        self.assertEqual(
            agent["modelMetadata"]["ark-code-latest"],
            {"attachment": True, "input": ["image", "text"], "output": ["text"]},
        )
        self.assertNotIn("contextTokens", agent["modelMetadata"]["ark-code-latest"])
        self.assertNotIn("maxOutputTokens", agent["modelMetadata"]["ark-code-latest"])

        token = providers["alibaba-token-plan"]
        self.assertEqual(token["models"], TOKEN_PLAN_MODELS)
        self.assertEqual(
            token["serviceOffers"],
            [
                {"models": TOKEN_PLAN_IMAGE, "role": "image"},
                {"models": TOKEN_PLAN_VIDEO, "role": "video"},
            ],
        )
        self.assertEqual(len(token["modelMetadata"]), 19)
        self.assertEqual(token["modelMetadata"]["qwen3.8-max"]["contextTokens"], 983_616)
        self.assertEqual(token["modelMetadata"]["qwen3.8-max"]["maxOutputTokens"], 131_072)

        # A /models listing is never claimed by either plan entry.
        for entry in (agent, token):
            self.assertFalse(any("discovery" in key.lower() for key in entry))
            self.assertNotIn("supportsModelDiscovery", entry)

    def test_plan_metadata_facts_and_capabilities_are_preserved(self):
        providers = self.providers()
        agent = providers["volcengine-agent-plan"]
        limits = {
            "deepseek-v4-flash": (1_048_576, 393_216),
            "deepseek-v4-pro": (1_048_576, 393_216),
            "deepseek-v4.1-flash": (1_048_576, 393_216),
            "deepseek-v4.1-flash-economy": (1_048_576, 393_216),
            "doubao-seed-2.0-mini": (262_144, 131_072),
            "doubao-seed-2.1-lite": (1_048_576, 262_144),
            "doubao-seed-2.1-pro": (1_048_576, 262_144),
            "doubao-seed-evolving": (1_048_576, 262_144),
            "glm-5.3": (1_048_576, 131_072),
            "glm-5.3-flash": (1_048_576, 131_072),
            "kimi-k2.8-preview": (1_048_576, 1_048_576),
            "kimi-k3": (1_048_576, 131_072),
            "kimi-k3.1-pro": (1_048_576, 1_048_576),
        }
        image_input = {
            "ark-code-latest", "deepseek-v4.1-flash",
            "deepseek-v4.1-flash-economy", "doubao-seed-2.0-mini",
            "doubao-seed-2.1-lite", "doubao-seed-2.1-pro",
            "doubao-seed-evolving", "glm-5.3-flash",
        }
        always_reasoning = {"glm-5.3", "kimi-k3"}
        metadata = agent["modelMetadata"]
        for model_id, (context, output) in limits.items():
            facts = metadata[model_id]
            self.assertEqual(facts["contextTokens"], context, model_id)
            self.assertEqual(facts["maxOutputTokens"], output, model_id)
            self.assertEqual(facts["output"], ["text"], model_id)
            self.assertEqual("image" in facts.get("input", []), model_id in image_input, model_id)
            self.assertEqual(facts.get("reasoning") is True, model_id in always_reasoning, model_id)
        self.assertEqual(metadata["ark-code-latest"]["input"], ["image", "text"])
        self.assertEqual(metadata["ark-code-latest"]["output"], ["text"])
        self.assertEqual(metadata["ark-code-latest"]["attachment"], True)
        self.assertNotIn("contextTokens", metadata["ark-code-latest"])
        self.assertNotIn("maxOutputTokens", metadata["ark-code-latest"])
        for model_id in AGENT_PLAN_IMAGE:
            facts = metadata[model_id]
            self.assertEqual(facts["input"], ["image", "text"])
            self.assertEqual(facts["output"], ["image"])

        token = providers["alibaba-token-plan"]
        for model_id in ("qwen3.8-flash", "qwen3.8-max"):
            facts = token["modelMetadata"][model_id]
            self.assertEqual(facts["contextTokens"], 983_616)
            self.assertEqual(facts["maxOutputTokens"], 131_072)
        for model_id in TOKEN_PLAN_IMAGE:
            self.assertEqual(token["modelMetadata"][model_id]["output"], ["image"])
        for model_id in TOKEN_PLAN_VIDEO:
            self.assertEqual(token["modelMetadata"][model_id]["output"], ["video"])

    def test_hidden_presets_are_still_in_the_document_for_editing(self):
        document = self.load()
        ids = {provider["presetID"] for provider in document["providers"]}
        for hidden in ("github-copilot", "azure", "amazon-bedrock", "google-vertex"):
            self.assertIn(hidden, ids)

    def test_override_patches_do_not_rewrite_the_upstream_baseline(self):
        providers = self.providers()
        for preset_id, expected in UNTOUCHED_PROVIDER_DIGESTS.items():
            self.assertEqual(digest(providers[preset_id]), expected, preset_id)

        alibaba = providers["alibaba"]
        self.assertEqual(alibaba["name"], "Alibaba Cloud · Pay as you go")
        self.assertEqual(digest(alibaba["models"]), ALIBABA_MODELS_DIGEST)
        self.assertEqual(
            digest({
                key: value for key, value in alibaba["modelMetadata"].items()
                if key not in ADDED_ALIBABA_METADATA
            }),
            ALIBABA_BASE_METADATA_DIGEST,
        )
        self.assertEqual(
            digest({
                key: value for key, value in alibaba.items()
                if key not in {"name", "serviceOffers", "modelMetadata"}
            }),
            ALIBABA_STABLE_FIELDS_DIGEST,
        )
        self.assertEqual(
            alibaba["serviceOffers"],
            [
                {
                    "models": [
                        "qwen-image-2.1-pro", "qwen-image-2.1-turbo",
                        "qwen-image-3.0", "qwen-image-3.0-pro",
                        "wan2.7-image", "wan2.7-image-pro",
                    ],
                    "role": "image",
                },
                {"models": ["wan3.0-video"], "role": "video"},
            ],
        )
        self.assertEqual(
            set(alibaba["modelMetadata"]) & ADDED_ALIBABA_METADATA,
            ADDED_ALIBABA_METADATA,
        )

        volcengine = providers["volcengine"]
        self.assertEqual(volcengine["name"], "Volcengine Ark · Pay as you go")
        self.assertEqual(
            digest({key: value for key, value in volcengine.items() if key != "name"}),
            VOLCENGINE_STABLE_FIELDS_DIGEST,
        )
        self.assertNotIn("serviceOffers", volcengine)

    def test_source_record_matches_document_pin_and_overrides(self):
        source = json.loads(
            (Path(__file__).resolve().parent / "SOURCE.json").read_text(encoding="utf-8")
        )
        document = self.load()
        overrides_raw = OVERRIDES.read_bytes()
        overrides = json.loads(overrides_raw)
        self.assertEqual(source["documentSHA256"], PIN)
        self.assertEqual(source["fetchedAt"], "2026-10-15T12:36:41Z")
        self.assertEqual(source["providerCount"], len(document["providers"]))
        self.assertEqual(source["availableCount"], 18)
        self.assertEqual(source["unsupportedCount"], 4)
        self.assertEqual(source["modelEntryCount"], 609)
        self.assertEqual(source["modelMetadataEntryCount"], 459)
        self.assertEqual(source["serviceOfferCount"], 6)
        self.assertEqual(source["serviceOfferModelEntryCount"], 39)
        self.assertEqual(source["generatedBy"], "content-hub/providers/import_models_dev.py")
        self.assertEqual(
            source["generatedWith"],
            [
                "content-hub/providers/import_models_dev.py",
                "content-hub/providers/curated-overrides.json",
            ],
        )
        curated = source["curatedOverrides"]
        self.assertEqual(curated["path"], "content-hub/providers/curated-overrides.json")
        self.assertEqual(curated["sha256"], hashlib.sha256(overrides_raw).hexdigest())
        self.assertEqual(curated["revision"], overrides["revision"])
        self.assertEqual(curated["upstreamDocumentSHA256"], PIN)
        self.assertEqual(curated["additionalProviderCount"], 2)
        self.assertEqual(curated["patchedProviderCount"], 2)
        self.assertIn("not models.dev", curated["note"])

    def test_content_source_version_and_plan_mappings(self):
        content = json.loads(CONTENT.read_text(encoding="utf-8"))
        self.assertEqual(content["version"], "1.1.2")
        self.assertEqual(content["minimumAppVersion"], "1.7.64")
        self.assertEqual(content["id"], "floe.providers.compatibility")
        self.assertEqual(content["kind"], "providers")
        self.assertFalse(content["containsScripts"])
        for locale in ("zh-Hans", "en"):
            self.assertTrue(content["releaseNotes"][locale])
            self.assertTrue(content["catalogNotice"][locale])
        mappings = {mapping["id"]: mapping for mapping in content["providerMappings"]}
        for preset_id in ("volcengine-agent-plan", "alibaba-token-plan"):
            self.assertIn(preset_id, mappings)
            self.assertFalse(mappings[preset_id]["supportsModelDiscovery"])
            self.assertEqual(mappings[preset_id]["authStyle"], "bearer")
            self.assertIn("openai-chat-completions", mappings[preset_id]["supportedProtocols"])


class DeclarativeOverrideTests(unittest.TestCase):
    def load(self):
        overrides, raw = imp.load_overrides()
        return overrides, raw

    def test_config_is_versioned_pinned_and_provenanced(self):
        overrides, raw = self.load()
        self.assertEqual(overrides["schemaVersion"], 1)
        self.assertEqual(overrides["revision"], "2026-10-30.1")
        self.assertEqual(overrides["upstreamPin"]["documentSHA256"], PIN)
        self.assertEqual(overrides["upstreamPin"]["fetchedAt"], "2026-10-15T12:36:41Z")
        expected = set(overrides["providerPatches"]) | {
            entry["presetID"] for entry in overrides["additionalProviders"]
        }
        self.assertEqual(set(overrides["provenance"]), expected)
        for preset_id in expected:
            self.assertTrue(overrides["provenance"][preset_id]["scope"])
        self.assertLess(len(raw), 1_048_576)

    def test_synthetic_regeneration_keeps_plan_entries_and_is_deterministic(self):
        document = full_synthetic_document()
        raw = json.dumps(document, sort_keys=True).encode("utf-8")
        first = imp.canonical(imp.build_document(document, raw, "2026-10-15T00:00:00Z"))
        second = imp.canonical(imp.build_document(document, raw, "2026-10-15T00:00:00Z"))
        self.assertEqual(first, second)

        built = json.loads(first)
        providers = {provider["presetID"]: provider for provider in built["providers"]}
        self.assertEqual(list(providers)[-2:], ["volcengine-agent-plan", "alibaba-token-plan"])
        agent = providers["volcengine-agent-plan"]
        self.assertEqual(agent["models"], AGENT_PLAN_MODELS)
        self.assertEqual(agent["serviceOffers"], [{"models": AGENT_PLAN_IMAGE, "role": "image"}])
        self.assertEqual(len(agent["modelMetadata"]), 17)
        token = providers["alibaba-token-plan"]
        self.assertEqual(token["models"], TOKEN_PLAN_MODELS)
        self.assertEqual(
            token["serviceOffers"],
            [
                {"models": TOKEN_PLAN_IMAGE, "role": "image"},
                {"models": TOKEN_PLAN_VIDEO, "role": "video"},
            ],
        )

        alibaba = providers["alibaba"]
        self.assertEqual(alibaba["name"], "Alibaba Cloud · Pay as you go")
        self.assertEqual(
            alibaba["serviceOffers"],
            [
                {
                    "models": [
                        "qwen-image-2.1-pro", "qwen-image-2.1-turbo",
                        "qwen-image-3.0", "qwen-image-3.0-pro",
                        "wan2.7-image", "wan2.7-image-pro",
                    ],
                    "role": "image",
                },
                {"models": ["wan3.0-video"], "role": "video"},
            ],
        )
        self.assertTrue(set(alibaba["modelMetadata"]).issuperset(ADDED_ALIBABA_METADATA))
        self.assertEqual(providers["volcengine"]["name"], "Volcengine Ark · Pay as you go")

    def test_conflicting_metadata_is_rejected_instead_of_overwriting_upstream(self):
        overrides, _ = self.load()
        conflicting = copy.deepcopy(overrides)
        conflicting["providerPatches"] = {
            "alibaba": {
                "modelMetadata": {
                    "existing-chat": {"input": ["image"], "output": ["text"]},
                }
            }
        }
        providers = [{
            "presetID": "alibaba",
            "aliases": [],
            "domains": [],
            "models": ["existing-chat"],
            "modelMetadata": {
                "existing-chat": {"input": ["text"], "output": ["text"]},
            },
        }]
        with self.assertRaisesRegex(imp.CatalogError, "conflicts"):
            imp.merge_provider_overrides(providers, conflicting)

    def test_unknown_discovery_or_private_field_is_rejected(self):
        raw = json.loads(OVERRIDES.read_text(encoding="utf-8"))
        mutated = copy.deepcopy(raw)
        mutated["additionalProviders"][0]["supportsModelDiscovery"] = False
        with self.assertRaisesRegex(imp.CatalogError, "unknown fields"):
            imp.normalize_overrides(mutated)

    def test_tracked_config_has_no_private_path_or_secret_pattern(self):
        text = OVERRIDES.read_text(encoding="utf-8")
        for forbidden in ("/Users/", "Local/Private", "sk-", "API_KEY", "Bearer "):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
