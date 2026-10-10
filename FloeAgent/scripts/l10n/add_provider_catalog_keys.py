#!/usr/bin/env python3
"""Add the provider-catalog add-flow localization keys.

These keys are hand-maintained (not extracted from SwiftUI literals) because
several resolve through `FloeL10n.l` with format arguments in the catalog add
sheet, the provider list footer and the editor's preset footer. Idempotent:
existing keys are left untouched. (Entry-point copy: 从目录添加 / Add from
catalog.)
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, "FloeApp/Resources/Localizable.xcstrings")

KEYS = {
    # Entry points.
    "providers.add_from_catalog": ("Add from catalog", "从目录添加"),
    "providers.catalog.title": ("Add from catalog", "从目录添加"),
    "providers.catalog.official": ("Official catalog", "官方目录"),
    "providers.catalog.refresh": ("Refresh catalog", "刷新目录"),
    "providers.catalog.official_footer": (
        "Source: %@ · %d providers",
        "来源：%@ · %d 个提供方"),
    # Search and filters.
    "providers.catalog.search_placeholder": (
        "Search providers, aliases or models",
        "搜索提供方、别名或模型"),
    "providers.catalog.filter.all": ("All", "全部"),
    "providers.catalog.filter.configured": ("Configured", "已配置"),
    "providers.catalog.filter.available": ("Available", "可用"),
    "providers.catalog.filter.local": ("Local", "本地"),
    "providers.catalog.filter_label": ("Filter", "筛选"),
    "providers.catalog.protocol.openai_responses": (
        "OpenAI Responses",
        "OpenAI Responses"),
    "providers.catalog.protocol.openai_chat": (
        "OpenAI Chat Completions",
        "OpenAI Chat Completions"),
    "providers.catalog.protocol.anthropic": (
        "Anthropic Messages",
        "Anthropic Messages"),
    # Rows and catalog metadata.
    "providers.catalog.configured_badge": ("Configured", "已配置"),
    "providers.catalog.unsupported_badge": ("Unsupported", "暂不支持"),
    "providers.catalog.alias": ("Alias: %@", "别名：%@"),
    "providers.catalog.models_count": ("%d models", "%d 个模型"),
    "providers.catalog.document_hash": (
        "Document SHA-256: %@",
        "文档 SHA-256：%@"),
    "providers.catalog.fetched_at": ("Fetched: %@", "抓取时间：%@"),
    "providers.catalog.provider_count": (
        "Catalog providers: %d",
        "目录提供方：%d"),
    "providers.catalog.empty_title": (
        "No matching providers",
        "没有匹配的提供方"),
    "providers.catalog.empty_hint": (
        "Try another search, or add a custom compatible endpoint from the provider list.",
        "请尝试其他关键词，或在提供方列表中手动添加自定义兼容端点。"),
    # Editor footer showing the catalog preset identity.
    "providers.catalog.preset_footer": ("Catalog preset: %@", "目录预设：%@"),
}


def main():
    cat = json.load(open(CATALOG, encoding="utf-8"))
    strings = cat["strings"]
    added = 0
    for key, (en, zh) in KEYS.items():
        if key in strings:
            continue
        strings[key] = {
            "extractionState": "manual",
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": en}},
                "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
            },
        }
        added += 1
    cat.setdefault("sourceLanguage", "en")
    cat.setdefault("version", "1.0")
    cat["strings"] = dict(sorted(strings.items()))
    json.dump(cat, open(CATALOG, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("provider-catalog keys added:", added, "total:", len(strings))


if __name__ == "__main__":
    main()
