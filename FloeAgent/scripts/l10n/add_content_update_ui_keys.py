#!/usr/bin/env python3
"""Manual keys for the content-update UI corrections (signed content hub
review surface, inline nonmodal failure status, source display name).
Idempotent."""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, "FloeApp/Resources/Localizable.xcstrings")

KEYS = {
    "settings.internal_prompts.built_in_source": ("Source", "来源"),
    "settings.internal_prompts.built_in_source.value": (
        "Compiled into the app", "已随应用内置"),
    "settings.internal_prompts.source": ("Content source", "内容来源"),
    "settings.internal_prompts.source.value": ("Official content hub", "官方内容中心"),
    "settings.internal_prompts.source.details": ("Technical details", "技术详情"),
    "settings.internal_prompts.source.repository": ("Repository", "仓库"),
    "settings.internal_prompts.source.ref": ("Ref", "引用"),
    "settings.internal_prompts.source.index": ("Signed index", "签名索引"),
    "settings.internal_prompts.source.signature": ("Index signature", "索引签名"),
    "settings.internal_prompts.source.pinned_commit": ("Pinned commit", "固定提交"),
    "settings.internal_prompts.sections.footer.built_in": (
        "These are the compiled built-in sections — exactly what the runtime uses while no signed prompts package is installed. They ship with the app and are never downloaded.",
        "以上为应用内置段落，即未安装签名提示词内容包时运行时所使用的内容。它们随应用发布，从不经网络下载。"),
    "settings.content_updates.error.built_in_active": (
        "Built-in content remains active.", "内置内容继续生效。"),
    "settings.content_updates.error.retry": ("Retry", "重试"),
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
    with open(CATALOG, "w", encoding="utf-8") as fh:
        json.dump(cat, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"added {added} keys")


if __name__ == "__main__":
    main()
