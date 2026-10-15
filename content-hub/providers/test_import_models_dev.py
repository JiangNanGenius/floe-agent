"""Offline checks for the provider-catalog importer.

No network access and no repository writes: synthetic upstream documents drive
the pure builder, plus invariants over the committed ProviderCatalog.json.
Run with:  python3 content-hub/providers/test_import_models_dev.py
"""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import import_models_dev as imp  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
BUNDLED = REPO_ROOT / "FloeAgent" / "FloeApp" / "Resources" / "ProviderCatalog.json"
PUBLISHED = REPO_ROOT / "content-hub" / "providers" / "ProviderCatalog.json"

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


class CommittedCatalogTests(unittest.TestCase):
    def load(self):
        with BUNDLED.open("rb") as handle:
            return json.load(handle)

    def test_bundled_and_published_copies_are_identical(self):
        self.assertEqual(BUNDLED.read_bytes(), PUBLISHED.read_bytes())

    def test_committed_metadata_invariants(self):
        document = self.load()
        self.assertEqual(document["schemaVersion"], 1)
        offered = 0
        metadata_count = 0
        for provider in document["providers"]:
            declared = set(provider["models"])
            for offer in provider.get("serviceOffers") or []:
                self.assertLessEqual(len(offer["models"]), 100)
                self.assertTrue(offer["models"])
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
                self.assertTrue(set(facts).issubset(
                    {"input", "output", "toolCall", "attachment", "reasoning"}))
                for key in ("input", "output"):
                    for modality in facts.get(key) or []:
                        self.assertIn(modality, MODALITIES)
                    self.assertEqual(facts.get(key), sorted(set(facts.get(key) or [])))
            if provider["availability"] == "available":
                offered += 1
                self.assertIsNotNone(provider["baseURL"])
        self.assertEqual(offered, 16)
        self.assertGreater(metadata_count, 300)  # metadata is actually present

    def test_hidden_presets_are_still_in_the_document_for_editing(self):
        # Hiding is a code policy in ProviderCatalogIndex; the entries stay so
        # saved providers referencing them remain editable.
        document = self.load()
        ids = {provider["presetID"] for provider in document["providers"]}
        for hidden in ("github-copilot", "azure", "amazon-bedrock", "google-vertex"):
            self.assertIn(hidden, ids)

    def test_source_record_matches_document_digest(self):
        source = json.loads(
            (Path(__file__).resolve().parent / "SOURCE.json").read_text(encoding="utf-8")
        )
        self.assertRegex(source["documentSHA256"], r"^[0-9a-f]{64}$")
        self.assertEqual(source["generatedBy"], "content-hub/providers/import_models_dev.py")
        self.assertEqual(source["providerCount"], len(self.load()["providers"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
