#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Deterministic builder for the built-in Floe help package.

Compiles the explicitly selected shared + iOS bilingual guides from
docs/DOCUMENTATION_CATALOG.json, four real local
screenshots, and three short settings how-tos into the offline help package
`floe.help.quickstart` version 1.2.0:

  * per-locale search indexes and categories (HelpIndex JSON)
  * stable, language-independent section anchors
  * controlled static HTML + one shared CSS (no scripts, no remote assets)
  * losslessly re-encoded bounded images (cwebp, deterministic flags)
  * a legacy `documents` Markdown projection for schema-1 readers
  * root content.json (schema 1 + helpManifest) and help/manifest.json

Outputs are written byte-identically to the App built-in resource directory
and the content-hub authoring directory. `check` re-builds everything in
memory and compares against the on-disk bytes without modifying anything.

Usage:
  python3 FloeAgent/scripts/build_help_content.py build [--source-revision HEX]
  python3 FloeAgent/scripts/build_help_content.py check [--source-revision HEX]
  python3 FloeAgent/scripts/build_help_content.py --check [--source-revision HEX]

The baked sourceRevision defaults to the explicitly allowed empty string so a
build/commit/check cycle stays reproducible; pass --source-revision to pin a
document input revision.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import unicodedata
import posixpath
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple
from documentation_catalog import load_catalog, select_documents

PACKAGE_ID = "floe.help.quickstart"
PACKAGE_VERSION = "1.2.0"
PLATFORM = "ios"
MANIFEST_PATH = "help/manifest.json"
MAX_FILE_BYTES = 1_048_576
MAX_MANIFEST_BYTES = 262_144
IDENTIFIER_RE = re.compile(r"^[a-z0-9]+([.-][a-z0-9]+)*$")
KNOWN_SETTING_IDS = ("general.hardwareReturn", "general.voiceOutput", "execution.memory")
CWEBP = "/opt/homebrew/bin/cwebp"

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOCS_DIR = os.path.join(REPO_ROOT, "docs")
GUIDE_IMAGES_DIR = os.path.join(DOCS_DIR, "assets", "guide")
BUILTIN_OUT = os.path.join(REPO_ROOT, "FloeAgent", "FloeApp", "Resources", "Help")
AUTHORING_OUT = os.path.join(REPO_ROOT, "content-hub", "sources", "help", PACKAGE_ID)

LOCALES = ("en", "zh-Hans")
SOURCE_LOCALE_SUFFIX = {"en": "", "zh-Hans": ".zh-CN"}

GUIDE_SOURCES = {
    "quickstart": "QUICKSTART",
    "user-manual": "USER_GUIDE",
    "workspaces": "WORKSPACES_GUIDE",
}
GUIDE_AUDIENCES: Dict[str, str] = {}


def configure_guide_sources() -> None:
    """Fail closed on missing classification; never scan all Markdown files."""
    global GUIDE_SOURCES, GUIDE_AUDIENCES
    try:
        catalog = load_catalog(os.path.join(DOCS_DIR, "DOCUMENTATION_CATALOG.json"))
        selected = select_documents(catalog, PLATFORM, help_only=True)
    except (OSError, ValueError) as error:
        raise BuildError(f"invalid documentation catalog: {error}") from error
    sources = {}
    for entry in selected:
        en = entry["sources"]["en"]
        stem = en.removesuffix(".md")
        if entry["sources"]["zh-Hans"] != stem + ".zh-CN.md":
            raise BuildError(f"help source locale naming mismatch: {entry['id']}")
        sources[entry["id"]] = stem
    if not {"shared-basics", "quickstart", "user-manual", "workspaces"} <= set(sources):
        raise BuildError("missing required iOS/shared help guides")
    GUIDE_SOURCES = sources
    GUIDE_AUDIENCES = {entry["id"]: entry["audience"] for entry in selected}

PUBLIC_BLOB_BASE = "https://github.com/JiangNanGenius/floe-agent/blob/main"

IMAGE_FILES = ("home-current", "workbench-current", "notes-current", "canvas-current")
IMAGE_MIME = "image/webp"

# ---------------------------------------------------------------------------
# Bilingual how-to articles (authored here, matching current App settings).
# ---------------------------------------------------------------------------

HOWTOS: Dict[str, Dict[str, dict]] = {
    "input.keyboard": {
        "settingIDs": ["general.hardwareReturn"],
        "keywords": {
            "en": ["keyboard", "return", "send", "newline", "hardware", "enter"],
            "zh-Hans": ["键盘", "回车", "发送", "换行", "实体键盘"],
        },
        "title": {"en": "Hardware keyboard Return key", "zh-Hans": "实体键盘回车键"},
        "summary": {
            "en": "Choose whether the Return key on a hardware keyboard inserts a newline or sends the message.",
            "zh-Hans": "选择实体键盘上的回车键是换行还是直接发送消息。",
        },
        "sections": {
            "en": [
                ("section-1", "Where it is", 2, None,
                 "Settings > General > Hardware Keyboard > Return Key."),
                ("section-2", "Change it", 2, None,
                 "Open Settings, tap General, then Hardware Keyboard. Pick Return Key and choose Newline or Send."),
                ("section-3", "Notes", 2, None,
                 "The setting applies to external keyboards connected to this device. The on-screen keyboard keeps its own send button."),
            ],
            "zh-Hans": [
                ("section-1", "设置路径", 2, None,
                 "设置 > 通用 > 实体键盘 > 回车键。"),
                ("section-2", "修改方法", 2, None,
                 "打开设置，进入通用，再进入实体键盘，选择回车键，然后选择换行或发送。"),
                ("section-3", "说明", 2, None,
                 "此设置只作用于连接到本设备的实体键盘；屏幕键盘仍使用自带的发送按钮。"),
            ],
        },
    },
    "voice.output": {
        "settingIDs": ["general.voiceOutput"],
        "keywords": {
            "en": ["voice output", "tts", "read aloud", "voice", "speech"],
            "zh-Hans": ["语音输出", "朗读", "语音", "声音"],
        },
        "title": {"en": "Voice output", "zh-Hans": "语音输出"},
        "summary": {
            "en": "Pick the voice Floe uses when it reads replies aloud.",
            "zh-Hans": "选择 Floe 朗读回复时使用的声音。",
        },
        "sections": {
            "en": [
                ("section-1", "Where it is", 2, None,
                 "Settings > General > Voice Output."),
                ("section-2", "Change it", 2, None,
                 "Open Settings, tap General, then Voice Output, and choose the voice you prefer."),
                ("section-3", "Notes", 2, None,
                 "The voice applies to read-aloud playback in the current conversation and voice replies."),
            ],
            "zh-Hans": [
                ("section-1", "设置路径", 2, None,
                 "设置 > 通用 > 语音输出。"),
                ("section-2", "修改方法", 2, None,
                 "打开设置，进入通用，再进入语音输出，选择喜欢的声音。"),
                ("section-3", "说明", 2, None,
                 "该声音用于当前会话的朗读播放和语音回复。"),
            ],
        },
    },
    "environment.memory": {
        "settingIDs": ["execution.memory"],
        "keywords": {
            "en": ["memory", "shared runtime", "linux", "guest memory", "ram"],
            "zh-Hans": ["内存", "共享运行环境", "运行环境", "Linux"],
        },
        "title": {"en": "Shared runtime memory", "zh-Hans": "共享运行环境内存"},
        "summary": {
            "en": "Adjust how much memory the shared Linux runtime may use.",
            "zh-Hans": "调整共享 Linux 运行环境可使用的内存大小。",
        },
        "sections": {
            "en": [
                ("section-1", "Where it is", 2, None,
                 "Settings > Execution Environment > Shared runtime > Memory."),
                ("section-2", "Change it", 2, None,
                 "Open Settings, tap Execution Environment, then Shared runtime, and pick Memory."),
                ("section-3", "Notes", 2, None,
                 "Memory options appear after the shared runtime is ready. Lowering the limit waits for current projects to close."),
            ],
            "zh-Hans": [
                ("section-1", "设置路径", 2, None,
                 "设置 > 执行环境 > 共享运行环境 > 内存。"),
                ("section-2", "修改方法", 2, None,
                 "打开设置，进入执行环境，再进入共享运行环境，选择内存。"),
                ("section-3", "说明", 2, None,
                 "共享运行环境准备好后才显示内存选项；调低内存会等待当前项目关闭。"),
            ],
        },
    },
}

HOWTO_ARTICLE_ORDER = ("input.keyboard", "voice.output", "environment.memory")

# ---------------------------------------------------------------------------
# Categories (stable ids, bilingual titles).
# ---------------------------------------------------------------------------

CATEGORY_DEFS = [
    ("getting-started", {"en": "Getting started", "zh-Hans": "快速开始"}),
    ("models-settings", {"en": "Models and settings", "zh-Hans": "模型与设置"}),
    ("tasks-permissions", {"en": "Tasks and permissions", "zh-Hans": "任务与权限"}),
    ("notes-files", {"en": "Notes and files", "zh-Hans": "手记与文件"}),
    ("space-creative", {"en": "Space and creative", "zh-Hans": "空间与创作"}),
    ("development-connections", {"en": "Development and connections", "zh-Hans": "开发与连接"}),
    ("troubleshooting", {"en": "Troubleshooting and feedback", "zh-Hans": "常见问题与反馈"}),
]

CATEGORY_ENTRIES = {
    "getting-started": [
        ("quickstart", None),
        ("shared-basics", None),
        ("user-manual", "section-1"),
        ("user-manual", "section-2"),
    ],
    "models-settings": [
        ("user-manual", "section-2"),
        ("input.keyboard", None),
        ("voice.output", None),
        ("user-manual", "section-16"),
    ],
    "tasks-permissions": [
        ("user-manual", "section-3"),
        ("user-manual", "section-4"),
        ("user-manual", "section-5"),
        ("user-manual", "section-19"),
    ],
    "notes-files": [
        ("user-manual", "section-6"),
        ("user-manual", "section-7"),
        ("user-manual", "section-8"),
    ],
    "space-creative": [
        ("workspaces", None),
        ("user-manual", "section-15"),
        ("user-manual", "section-22"),
        ("user-manual", "section-14"),
    ],
    "development-connections": [
        ("user-manual", "section-9"),
        ("user-manual", "section-10"),
        ("user-manual", "section-11"),
        ("user-manual", "section-12"),
        ("user-manual", "section-13"),
        ("environment.memory", None),
    ],
    "troubleshooting": [
        ("user-manual", "section-20"),
        ("user-manual", "section-21"),
        ("quickstart", "section-7"),
    ],
}

# Extra per-section aliases and per-article keywords for search quality.
SECTION_ALIASES = {
    "user-manual": {
        "section-2": {"en": ["provider", "api key", "model configuration"], "zh-Hans": ["模型配置", "服务商", "密钥"]},
        "section-2-2": {"en": ["mac bridge", "bridge"], "zh-Hans": ["桥", "mac 桥"]},
        "section-7": {"en": ["apple pencil", "applepencil", "pencil", "handwriting", "notes"], "zh-Hans": ["笔记", "手写", "书写", "pencil", "applepencil"]},
        "section-8": {"en": ["office", "excel", "word", "ppt"], "zh-Hans": ["办公", "表格", "文档"]},
        "section-9": {"en": ["terminal", "linux", "performance"], "zh-Hans": ["终端", "linux", "性能"]},
        "section-15": {"en": ["canvas", "image", "audio", "video", "media"], "zh-Hans": ["画布", "图片", "音视频", "媒体"]},
        "section-16": {"en": ["voice", "tts", "read aloud", "transcription"], "zh-Hans": ["语音", "朗读", "转录"]},
        "section-19": {"en": ["temporary chat", "ram-only"], "zh-Hans": ["临时聊天", "内存"]},
    },
}

ARTICLE_KEYWORDS = {
    "quickstart": {"en": ["quickstart", "install", "first task"], "zh-Hans": ["快速上手", "安装", "新手"]},
    "user-manual": {"en": ["manual", "guide"], "zh-Hans": ["手册", "指南"]},
    "workspaces": {"en": ["space", "workbench", "meetings", "music", "diagram"], "zh-Hans": ["空间", "工作台", "会议", "音乐", "图示"]},
}


class BuildError(Exception):
    pass


# ---------------------------------------------------------------------------
# Minimal Markdown model
# ---------------------------------------------------------------------------

@dataclass
class Inline:
    kind: str          # text | bold | code | link | image
    text: str
    target: str = ""


@dataclass
class Block:
    kind: str          # h | p | ul | ol | table | quote
    level: int = 0
    inlines: List[Inline] = field(default_factory=list)
    items: List[List[Inline]] = field(default_factory=list)
    rows: List[List[List[Inline]]] = field(default_factory=list)
    anchor: str = ""


@dataclass
class Section:
    id: str
    title: str
    level: int
    parent: Optional[str]
    blocks: List[Block] = field(default_factory=list)
    text: str = ""
    aliases: List[str] = field(default_factory=list)


@dataclass
class Article:
    id: str
    locale: str
    title: str
    summary: str
    source_path: str
    sections: List[Section] = field(default_factory=list)  # excludes implicit root
    preamble: List[Block] = field(default_factory=list)
    keywords: List[str] = field(default_factory=list)
    setting_ids: List[str] = field(default_factory=list)


def parse_inlines(text: str) -> List[Inline]:
    out: List[Inline] = []
    pattern = re.compile(
        r"!\[([^\]]*)\]\(([^)]+)\)|\[([^\]]+)\]\(([^)]+)\)|`([^`]+)`"
        r"|\*\*([^*]+)\*\*|\*([^*\n]+)\*"
    )
    pos = 0
    for match in pattern.finditer(text):
        if match.start() > pos:
            out.append(Inline("text", text[pos:match.start()]))
        if match.group(2) is not None:
            out.append(Inline("image", match.group(1), match.group(2)))
        elif match.group(4) is not None:
            out.append(Inline("link", match.group(3), match.group(4)))
        elif match.group(5) is not None:
            out.append(Inline("code", match.group(5)))
        elif match.group(6) is not None:
            # Bold content keeps its inline markdown; rendering re-parses so
            # nested code/italic work.
            out.append(Inline("bold", match.group(6)))
        else:
            out.append(Inline("italic", match.group(7)))
        pos = match.end()
    if pos < len(text):
        out.append(Inline("text", text[pos:]))
    return out


def github_slug(title: str) -> str:
    slug = title.strip().lower()
    slug = re.sub(r"[^\w\s\-\u4e00-\u9fff]", "", slug, flags=re.UNICODE)
    slug = re.sub(r"[\s]+", "-", slug)
    return slug


def parse_markdown(path: str) -> List[Block]:
    """Parse a guide markdown file into blocks."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    blocks: List[Block] = []
    i = 0
    paragraph: List[str] = []

    def flush_paragraph() -> None:
        if paragraph:
            text = " ".join(part.strip() for part in paragraph).strip()
            if text:
                blocks.append(Block("p", inlines=parse_inlines(text)))
            paragraph.clear()

    while i < len(lines):
        line = lines[i]
        heading = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
        if heading:
            flush_paragraph()
            level = len(heading.group(1))
            title = heading.group(2).strip()
            block = Block("h", level=level, inlines=parse_inlines(title))
            blocks.append(block)
            i += 1
            continue
        if not line.strip():
            flush_paragraph()
            i += 1
            continue
        if line.strip() == "<!-- -->":
            i += 1
            continue
        anchor_comment = re.match(r"^<!--\s*doc-anchor:\s*([A-Za-z0-9-]+)\s*-->$", line.strip())
        if anchor_comment:
            i += 1
            continue
        if line.strip().startswith("<!--"):
            # Maintenance comments (docs-updated markers etc.) are not
            # reader content.
            i += 1
            continue
        if line.lstrip().startswith("```"):
            flush_paragraph()
            i += 1
            code_lines = []
            while i < len(lines) and not lines[i].lstrip().startswith("```"):
                code_lines.append(lines[i])
                i += 1
            i += 1
            blocks.append(Block("p", inlines=[Inline("code", "\n".join(code_lines))]))
            continue
        if re.match(r"^\s*[-*]\s+", line):
            flush_paragraph()
            items = []
            while i < len(lines) and re.match(r"^\s*[-*]\s+", lines[i]):
                item_text = re.sub(r"^\s*[-*]\s+", "", lines[i]).strip()
                continuation = []
                i += 1
                while i < len(lines) and lines[i].strip() and not re.match(
                        r"^\s*[-*]\s+", lines[i]) and not re.match(r"^#{1,6}\s", lines[i]) \
                        and not re.match(r"^\s*\|", lines[i]):
                    continuation.append(lines[i].strip())
                    i += 1
                full = " ".join([item_text] + continuation)
                items.append(parse_inlines(full))
            blocks.append(Block("ul", items=items))
            continue
        if re.match(r"^\s*\d+\.\s+", line):
            flush_paragraph()
            items = []
            while i < len(lines) and re.match(r"^\s*\d+\.\s+", lines[i]):
                items.append(parse_inlines(re.sub(r"^\s*\d+\.\s+", "", lines[i]).strip()))
                i += 1
            blocks.append(Block("ol", items=items))
            continue
        if re.match(r"^\s*\|", line):
            flush_paragraph()
            rows = []
            while i < len(lines) and re.match(r"^\s*\|", lines[i]):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if not all(re.match(r"^:?-{3,}:?$", c) for c in cells):
                    rows.append([parse_inlines(c) for c in cells])
                i += 1
            blocks.append(Block("table", rows=rows))
            continue
        if line.lstrip().startswith(">"):
            flush_paragraph()
            quote_lines = []
            while i < len(lines) and lines[i].lstrip().startswith(">"):
                quote_lines.append(lines[i].lstrip()[1:].strip())
                i += 1
            blocks.append(Block("quote", inlines=parse_inlines(" ".join(quote_lines))))
            continue
        paragraph.append(line)
        i += 1
    flush_paragraph()
    return blocks


def inline_plain_text(inlines: Sequence[Inline]) -> str:
    parts = []
    for item in inlines:
        if item.kind == "bold":
            parts.append(item.text.replace("`", ""))
        else:
            parts.append(item.text)
    return "".join(parts)


def block_plain_text(block: Block) -> str:
    if block.kind == "h":
        return inline_plain_text(block.inlines)
    if block.kind in ("p", "quote"):
        return inline_plain_text(block.inlines)
    if block.kind in ("ul", "ol"):
        return "\n".join("• " + inline_plain_text(item) for item in block.items)
    if block.kind == "table":
        rows = []
        for row in block.rows:
            rows.append(" | ".join(inline_plain_text(cell) for cell in row))
        return "\n".join(rows)
    return ""


# ---------------------------------------------------------------------------
# Anchor assignment
# ---------------------------------------------------------------------------

SKIP_ANCHOR_TITLES = {"contents", "目录"}


def assign_anchors(blocks: List[Block]) -> Tuple[List[Tuple[Block, str, Optional[str]]], Dict[str, str]]:
    """Assign stable language-independent anchors to heading blocks.

    H2 with a leading number N -> section-N; unnumbered H2 -> ordinal.
    Deeper headings get their parent anchor plus a 1-based ordinal.
    Headings that only list the manual's own contents are not content
    chapters and receive no anchor; links to them target the indexed
    "overview" reading start instead.

    Returns (heading descriptors, fragment map). The fragment map resolves
    both GitHub-style heading slugs and exact raw heading text to anchors,
    because maintained guides use both fragment styles.
    """
    headings: List[Tuple[Block, str, Optional[str]]] = []
    fragment_to_anchor: Dict[str, str] = {}
    h2_ordinal = 0
    unnumbered_ordinal = 0
    counters: List[int] = [0] * 7
    parent_stack: List[Tuple[int, str]] = []
    pending: List[Tuple[str, Block]] = []
    has_numbered_h2 = any(
        block.kind == "h" and block.level == 2
        and re.match(r"^\d+[\.、]\s*", inline_plain_text(block.inlines).strip())
        for block in blocks
    )

    for block in blocks:
        if block.kind != "h":
            continue
        level = block.level
        title = inline_plain_text(block.inlines).strip()
        slug = github_slug(title)
        if level == 1:
            pending.append((slug, block))
            continue
        if level == 2 and slug in (github_slug(t) for t in SKIP_ANCHOR_TITLES):
            # Manual contents lists resolve to the indexed overview.
            fragment_to_anchor[slug] = "overview"
            fragment_to_anchor[title] = "overview"
            continue
        while parent_stack and parent_stack[-1][0] >= level:
            parent_stack.pop()
        parent: Optional[str] = None
        if level == 2:
            h2_ordinal += 1
            number = re.match(r"^(\d+)[\.、]\s*", title)
            if number:
                base = f"section-{number.group(1)}"
            elif has_numbered_h2:
                # Mixed chapter lists: keep unnumbered preface/epilogue
                # chapters distinct from numbered chapter identities.
                unnumbered_ordinal += 1
                base = f"section-u{unnumbered_ordinal}"
            else:
                base = f"section-{h2_ordinal}"
            counters = [0] * 7
        else:
            parent = parent_stack[-1][1] if parent_stack else f"section-{h2_ordinal}"
            counters[level] += 1
            base = f"{parent}-{counters[level]}"
        parent_stack.append((level, base))
        block.anchor = base
        fragment_to_anchor.setdefault(slug, base)
        fragment_to_anchor.setdefault(title, base)
        for slug2, _ in pending:
            fragment_to_anchor.setdefault(slug2, base)
        pending.clear()
        headings.append((block, base, parent))
    for slug, _ in pending:
        fragment_to_anchor.setdefault(slug, "")
    return headings, fragment_to_anchor


# ---------------------------------------------------------------------------
# Article assembly
# ---------------------------------------------------------------------------

def build_guide_article(article_id: str, locale: str, source_revision: str) -> Article:
    stem = GUIDE_SOURCES[article_id]
    suffix = SOURCE_LOCALE_SUFFIX[locale]
    rel_source = f"docs/{stem}{suffix}.md"
    path = os.path.join(DOCS_DIR, f"{stem}{suffix}.md")
    if not os.path.exists(path):
        raise BuildError(f"missing source guide: {path}")
    blocks = parse_markdown(path)
    assign_anchors(blocks)

    title_block = next((b for b in blocks if b.kind == "h" and b.level == 1), None)
    title = inline_plain_text(title_block.inlines) if title_block else article_id

    sections: List[Section] = []
    current: Optional[Section] = None
    preamble: List[Block] = []
    for block in blocks:
        if block.kind == "h" and block.level == 1:
            continue
        if block.kind == "h":
            if not block.anchor:
                # Non-chapter headings (e.g. the manual's own contents list)
                # stay out of the section identity.
                continue
            parent = None
            if block.anchor and "-" in block.anchor[8:]:
                parent = block.anchor.rsplit("-", 1)[0]
            current = Section(id=block.anchor, title=inline_plain_text(block.inlines),
                              level=block.level, parent=parent)
            sections.append(current)
        elif current is None:
            preamble.append(block)
        else:
            current.blocks.append(block)
    if not sections:
        raise BuildError(f"guide has no sections: {path}")

    # Introductory text before the first chapter must stay readable and
    # searchable, so it becomes a real shared "overview" section instead of
    # living only in the HTML preamble.
    if preamble:
        overview_text = "\n\n".join(p for p in (block_plain_text(b) for b in preamble) if p).strip()
        if overview_text:
            overview_title = "Overview" if locale == "en" else "概览"
            sections.insert(0, Section(id="overview", title=overview_title, level=2,
                                       parent=None, blocks=list(preamble),
                                       text=overview_text))
    for section in sections:
        pieces = [block_plain_text(block) for block in section.blocks]
        section.text = "\n\n".join(p for p in pieces if p).strip()

    first_text = sections[0].text if sections else ""
    summary = first_text.split("\n")[0][:220] if first_text else title

    article = Article(id=article_id, locale=locale, title=title, summary=summary,
                      source_path=rel_source)
    article.preamble = preamble
    article.keywords = ARTICLE_KEYWORDS.get(article_id, {}).get(locale, [])
    alias_map = SECTION_ALIASES.get(article_id, {})
    for section in sections:
        section.aliases = alias_map.get(section.id, {}).get(locale, [])
    article.sections = sections
    return article


def build_howto_article(article_id: str, locale: str, source_revision: str) -> Article:
    spec = HOWTOS[article_id]
    blocks: List[Block] = [Block("h", level=1, inlines=[Inline("text", spec["title"][locale])])]
    summary = spec["summary"][locale]
    blocks.append(Block("p", inlines=[Inline("text", summary)]))
    sections: List[Section] = []
    for section_id, title, level, parent, text in spec["sections"][locale]:
        blocks.append(Block("h", level=2, inlines=[Inline("text", title)], anchor=section_id))
        blocks.append(Block("p", inlines=[Inline("text", text)]))
        sections.append(Section(id=section_id, title=title, level=level, parent=parent,
                                blocks=[Block("p", inlines=[Inline("text", text)])],
                                text=text))
    paths = {
        "input.keyboard": {
            "en": "Settings > General > Hardware Keyboard > Return Key",
            "zh-Hans": "设置 > 通用 > 实体键盘 > 回车键",
        },
        "voice.output": {"en": "Settings > General > Voice Output",
                         "zh-Hans": "设置 > 通用 > 语音输出"},
        "environment.memory": {
            "en": "Settings > Execution Environment > Shared runtime > Memory",
            "zh-Hans": "设置 > 执行环境 > 共享运行环境 > 内存",
        },
    }
    quote = Block("quote", inlines=[Inline("text", paths[article_id][locale])])
    blocks.insert(2, quote)
    sections[0].blocks.insert(0, quote)
    sections[0].text = paths[article_id][locale] + "\n\n" + sections[0].text

    article = Article(id=article_id, locale=locale, title=spec["title"][locale],
                      summary=summary, source_path="(built-in how-to)")
    article.keywords = list(spec["keywords"][locale])
    article.setting_ids = list(spec["settingIDs"])
    article.sections = sections
    article.preamble = []
    return article


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def html_for_inlines(inlines: Sequence[Inline], locale: str, link_resolver) -> str:
    parts = []
    for item in inlines:
        if item.kind == "text":
            parts.append(html.escape(item.text))
        elif item.kind == "bold":
            parts.append("<strong>" + html_for_inlines(parse_inlines(item.text), locale, link_resolver) + "</strong>")
        elif item.kind == "italic":
            parts.append("<em>" + html_for_inlines(parse_inlines(item.text), locale, link_resolver) + "</em>")
        elif item.kind == "code":
            parts.append("<code>" + html.escape(item.text) + "</code>")
        elif item.kind == "link":
            href = link_resolver(item.target)
            cls = ' class="external"' if href.startswith("http") else ""
            parts.append(f'<a href="{html.escape(href, quote=True)}"{cls}>' +
                         html.escape(item.text) + "</a>")
        elif item.kind == "image":
            src = resolve_image(item.target)
            parts.append(f'<img src="{html.escape(src, quote=True)}" alt="' +
                         html.escape(item.text, quote=True) + '">')
    return "".join(parts)


def make_link_resolver(locale: str, slug_maps: Dict[str, Dict[str, Dict[str, str]]],
                       current_article_id: str):
    """Resolve a markdown link target to a package-relative or public URL.

    In-package guide links become relative article HTML links, same-article
    fragments map through the current article's heading slugs, and every
    other local Markdown target becomes a public repository URL. Image
    targets are handled separately by `resolve_image`.
    """
    stem_to_article = {stem: article_id for article_id, stem in GUIDE_SOURCES.items()}
    current_slugs = slug_maps.get(current_article_id, {}).get(locale, {})

    def resolve(target: str) -> str:
        if re.match(r"^[a-z]+://", target):
            return target
        path, _, fragment = target.partition("#")
        fragment = fragment.strip()
        if not path:
            if not fragment:
                return target
            anchor = current_slugs.get(fragment)
            if not anchor:
                raise BuildError(f"unresolved same-article anchor {target} in {current_article_id}")
            return f"#{anchor}"
        basename = os.path.basename(path)
        stem = basename[:-3] if basename.endswith(".md") else basename
        logical = stem[:-6] if stem.endswith(".zh-CN") else stem
        if logical in stem_to_article:
            article_id = stem_to_article[logical]
            anchor = ""
            if fragment:
                anchor = slug_maps.get(article_id, {}).get(locale, {}).get(fragment, "")
                if not anchor:
                    raise BuildError(f"unresolved in-package anchor {target}")
            return f"{article_id}.html" + (f"#{anchor}" if anchor else "")
        # Guides live in docs/; resolve the target relative to that directory
        # so ../ paths reach the repository root instead of gaining docs/.
        repo_rel = posixpath.normpath(posixpath.join("docs", path))
        url = f"{PUBLIC_BLOB_BASE}/{repo_rel}"
        if fragment:
            url += f"#{fragment}"
        return url
    return resolve


def resolve_image(target: str) -> str:
    """Map a source image target to its bounded in-package WebP path."""
    match = re.fullmatch(r"assets/guide/([A-Za-z0-9_-]+)\.png", target)
    if not match:
        raise BuildError(f"unexpected image target: {target}")
    if match.group(1) not in IMAGE_FILES:
        raise BuildError(f"image is not part of the help package: {target}")
    return f"../../assets/guide/{match.group(1)}.webp"


def render_article_html(article: Article, locale: str, link_resolver,
                        source_revision: str) -> str:
    lang_attr = "zh-Hans" if locale == "zh-Hans" else "en"
    out = [
        "<!doctype html>",
        f'<html lang="{lang_attr}">',
        "<head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        f"<title>{html.escape(article.title)}</title>",
        '<link rel="stylesheet" href="../../styles/help.css">',
        "</head>",
        "<body>",
        "<main>",
        f'<h1>{html.escape(article.title)}</h1>',
    ]
    if article.sections:
        toc_label = "目录" if locale == "zh-Hans" else "Contents"
        out.append(f'<nav class="toc" aria-label="{toc_label}"><h2>{toc_label}</h2><ul>')
        for section in article.sections:
            if section.level > 2:
                continue
            out.append(f'<li class="lv{section.level}"><a href="#{section.id}">' +
                       html.escape(section.title) + "</a></li>")
        out.append("</ul></nav>")
    for section in article.sections:
        tag = "h2" if section.level == 2 else "h3"
        out.append(f'<{tag} id="{section.id}">{html.escape(section.title)}</{tag}>')
        for block in section.blocks:
            out.append(render_block(block, locale, link_resolver))
    out.append("</main>")
    footer_note = "Floe 指南" if locale == "zh-Hans" else "Floe guides"
    out.append(f"<footer><p>{footer_note}</p></footer>")
    out.append("</body>")
    out.append("</html>")
    return "\n".join(out) + "\n"


def render_block(block: Block, locale: str, link_resolver) -> str:
    if block.kind == "p":
        return "<p>" + html_for_inlines(block.inlines, locale, link_resolver) + "</p>"
    if block.kind == "quote":
        return "<blockquote>" + html_for_inlines(block.inlines, locale, link_resolver) + "</blockquote>"
    if block.kind == "ul":
        items = "".join("<li>" + html_for_inlines(item, locale, link_resolver) + "</li>"
                        for item in block.items)
        return "<ul>" + items + "</ul>"
    if block.kind == "ol":
        items = "".join("<li>" + html_for_inlines(item, locale, link_resolver) + "</li>"
                        for item in block.items)
        return "<ol>" + items + "</ol>"
    if block.kind == "table":
        rows = []
        for index, row in enumerate(block.rows):
            tag = "th" if index == 0 else "td"
            cells = "".join(
                f"<{tag}>" + html_for_inlines(cell, locale, link_resolver) + f"</{tag}>"
                for cell in row)
            rows.append("<tr>" + cells + "</tr>")
        return '<div class="table-wrap"><table>' + "".join(rows) + "</table></div>"
    return ""


HELP_CSS = """/* Floe help articles: controlled static styling, no scripts. */
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
  margin: 0 auto;
  padding: 1.25rem 1.25rem 4rem;
  max-width: 46rem;
  font: -apple-system-body;
  font-family: -apple-system, "SF Pro Text", "PingFang SC", sans-serif;
  line-height: 1.6;
  color: #1c1c1e;
  background: #ffffff;
}
h1 { font-size: 1.7rem; line-height: 1.25; margin: 0 0 1rem; }
h2 { font-size: 1.3rem; margin: 2rem 0 0.6rem; }
h3 { font-size: 1.1rem; margin: 1.4rem 0 0.4rem; }
p, li { margin: 0.5rem 0; }
a { color: #0a64c2; word-break: break-word; }
a.external::after { content: " \\2197"; font-size: 0.8em; }
code {
  font-family: ui-monospace, "SF Mono", Menlo, monospace;
  font-size: 0.92em;
  background: rgba(127,127,127,0.14);
  padding: 0.1em 0.3em;
  border-radius: 4px;
  word-break: break-word;
}
blockquote {
  margin: 0.8rem 0;
  padding: 0.6rem 0.9rem;
  border-left: 3px solid #0a64c2;
  background: rgba(127,127,127,0.08);
  border-radius: 0 8px 8px 0;
}
img { display: block; max-width: 100%; height: auto; margin: 1rem 0; border-radius: 10px; }
ul, ol { padding-left: 1.4rem; }
.table-wrap { overflow-x: auto; margin: 0.8rem 0; }
table { border-collapse: collapse; width: 100%; font-size: 0.95rem; }
th, td { border: 1px solid rgba(127,127,127,0.35); padding: 0.35rem 0.6rem; text-align: left; vertical-align: top; }
th { background: rgba(127,127,127,0.12); }
.toc { margin: 1.2rem 0; padding: 0.8rem 1rem; border: 1px solid rgba(127,127,127,0.25); border-radius: 10px; }
.toc h2 { font-size: 1rem; margin: 0 0 0.4rem; }
.toc ul { list-style: none; margin: 0; padding: 0; }
.toc li { margin: 0.25rem 0; }
.toc li.lv3 { padding-left: 1.2rem; }
footer { margin-top: 3rem; font-size: 0.8rem; color: #6c6c70; }
@media (prefers-color-scheme: dark) {
  body { color: #e5e5ea; background: #1c1c1e; }
  a { color: #5aa9ff; }
  th { background: rgba(127,127,127,0.18); }
}
@media (min-width: 48rem) {
  body { font-size: 1.06rem; }
}
"""


# ---------------------------------------------------------------------------
# Package assembly
# ---------------------------------------------------------------------------

def article_to_json(article: Article, locale: str, html_path: str) -> dict:
    return {
        "id": article.id,
        "audience": GUIDE_AUDIENCES.get(article.id, "ios"),
        "title": article.title,
        "summary": article.summary,
        "htmlPath": html_path,
        "sections": [
            {
                "id": section.id,
                "parentID": section.parent,
                "title": section.title,
                "level": section.level,
                "text": section.text,
                "aliases": section.aliases,
            }
            for section in article.sections
        ],
        "keywords": article.keywords,
        "settingIDs": article.setting_ids,
    }


def index_document(articles: Dict[str, Article], locale: str) -> dict:
    by_id = articles
    categories = []
    for category_id, titles in CATEGORY_DEFS:
        entries = []
        for article_id, section_id in CATEGORY_ENTRIES[category_id]:
            article = by_id[article_id]
            if section_id:
                section = next(s for s in article.sections if s.id == section_id)
                summary = section.text.split("\n")[0][:180]
                entries.append({
                    "articleID": article_id,
                    "sectionID": section_id,
                    "title": section.title,
                    "summary": summary,
                })
            else:
                entries.append({
                    "articleID": article_id,
                    "sectionID": None,
                    "title": article.title,
                    "summary": article.summary,
                })
        categories.append({"id": category_id, "title": titles[locale], "entries": entries})
    order = ["quickstart", "shared-basics", "user-manual", "workspaces"] + list(HOWTO_ARTICLE_ORDER)
    article_docs = []
    for article_id in order:
        article = by_id[article_id]
        html_path = f"help/articles/{locale}/{article_id}.html"
        article_docs.append(article_to_json(article, locale, html_path))
    return {"schemaVersion": 1, "locale": locale, "platform": PLATFORM,
            "categories": categories, "articles": article_docs}


def legacy_document(articles: Dict[str, Article], locale: str, source_revision: str) -> str:
    titles = {
        "en": f"Floe Help ({PACKAGE_ID} {PACKAGE_VERSION})",
        "zh-Hans": f"Floe 帮助（{PACKAGE_ID} {PACKAGE_VERSION}）",
    }
    lines = [f"# {titles[locale]}", ""]
    if locale == "zh-Hans":
        lines += ["这是 Floe App 内置帮助中心的离线文档包。请在 App 的“设置 > 帮助”中阅读，支持目录、搜索与图文。",
                  ""]
    else:
        lines += ["This is the offline document package for the built-in Floe help center. Read it in the App under Settings > Help with contents, search and images.",
                  ""]
    order = ["quickstart", "shared-basics", "user-manual", "workspaces"] + list(HOWTO_ARTICLE_ORDER)
    for article_id in order:
        article = articles[article_id]
        lines.append(f"## {article.title}")
        lines.append("")
        lines.append(article.summary)
        lines.append("")
        for section in article.sections:
            if section.level > 2:
                continue
            indent = "  " * (section.level - 2)
            lines.append(f"{indent}- {section.title}")
        lines.append("")
    lines.append("---")
    note = ("External links open the public floe-agent repository and need a network connection."
            if locale == "en" else
            "外部链接打开 floe-agent 公开仓库，需要联网。")
    lines.append(note)
    if source_revision:
        lines.append(f"Source revision: {source_revision}")
    lines.append("")
    return "\n".join(lines)


def content_json(source_revision: str) -> dict:
    return {
        "schemaVersion": 1,
        "id": PACKAGE_ID,
        "version": PACKAGE_VERSION,
        "kind": "help",
        "minimumAppVersion": "1.7.0",
        "sourceRevision": source_revision,
        "containsScripts": False,
        "requiredCapabilities": [],
        "dependencies": [],
        "releaseNotes": {
            "en": "Separate iOS/iPadOS help from Android, and reuse one shared guide for models, tasks and files. Keeps bilingual offline search, images and settings how-tos.",
            "zh-Hans": "分离 iOS/iPadOS 与 Android 教程，共用模型、任务与文件指南；保留双语离线搜索、图片和设置说明。",
        },
        "title": {"en": "Floe Help", "zh-Hans": "Floe 帮助中心"},
        "documents": {"en": "index.md", "zh-Hans": "index.zh-Hans.md"},
        "helpManifest": MANIFEST_PATH,
    }


def manifest_json(source_revision: str, resources: List[dict]) -> dict:
    return {
        "schemaVersion": 1,
        "platform": PLATFORM,
        "sourceAudiences": GUIDE_AUDIENCES,
        "id": PACKAGE_ID,
        "version": PACKAGE_VERSION,
        "sourceRevision": source_revision,
        "title": {"en": "Floe Help", "zh-Hans": "Floe 帮助中心"},
        "indexPaths": {"en": "help/index/en.json", "zh-Hans": "help/index/zh-Hans.json"},
        "resources": resources,
    }


def json_bytes(document, *, compact: bool) -> bytes:
    if compact:
        text = json.dumps(document, ensure_ascii=False, separators=(",", ":"))
    else:
        text = json.dumps(document, ensure_ascii=False, indent=2)
    return (text + "\n").encode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def mime_for(path: str) -> str:
    ext = path.rsplit(".", 1)[-1].lower()
    return {
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "md": "text/markdown; charset=utf-8",
        "webp": IMAGE_MIME,
        "png": "image/png",
    }.get(ext, "application/octet-stream")


def convert_images() -> Dict[str, bytes]:
    """Losslessly re-encode guide PNGs to bounded WebP (deterministic flags)."""
    converted: Dict[str, bytes] = {}
    for name in IMAGE_FILES:
        source = os.path.join(GUIDE_IMAGES_DIR, f"{name}.png")
        if not os.path.exists(source):
            raise BuildError(f"missing guide image: {source}")
        output = os.path.join(temp_scratch(), f"{name}.webp")
        proc = subprocess.run(
            [CWEBP, "-lossless", "-z", "9", "-mt", source, "-o", output],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            raise BuildError(f"cwebp failed for {source}: {proc.stderr.strip()}")
        with open(output, "rb") as handle:
            data = handle.read()
        if len(data) > MAX_FILE_BYTES:
            raise BuildError(f"converted image exceeds {MAX_FILE_BYTES} bytes: {name}.webp")
        converted[f"help/assets/guide/{name}.webp"] = data
    return converted


_SCRATCH: Optional[str] = None


def temp_scratch() -> str:
    global _SCRATCH
    if _SCRATCH is None:
        import tempfile
        _SCRATCH = tempfile.mkdtemp(prefix="floe-help-build-")
    return _SCRATCH


def build_package(source_revision: str, *, with_images: bool = True) -> Dict[str, bytes]:
    """Build the complete package as a {relative path: bytes} mapping."""
    validate_source_revision(source_revision)
    configure_guide_sources()
    files: Dict[str, bytes] = {}

    # Parse guides once per locale; verify anchor parity across locales.
    articles: Dict[str, Dict[str, Article]] = {}
    slug_maps: Dict[str, Dict[str, str]] = {}
    for article_id, stem in GUIDE_SOURCES.items():
        per_locale: Dict[str, Article] = {}
        chapter_shapes: Dict[str, List[str]] = {}
        for locale in LOCALES:
            article = build_guide_article(article_id, locale, source_revision)
            per_locale[locale] = article
            # Major (level-2) chapter anchors must be language-independent;
            # deeper subsection sets may legitimately differ per locale.
            chapter_shapes[locale] = [s.id for s in article.sections if s.level == 2]
        if chapter_shapes["en"] != chapter_shapes["zh-Hans"]:
            raise BuildError(f"chapter anchor parity mismatch for {article_id}: "
                             f"{chapter_shapes['en']} vs {chapter_shapes['zh-Hans']}")
        # Per-locale fragment maps (heading slug and raw heading text ->
        # anchor): links inside each language reference that language's own
        # heading anchors (e.g. zh same-article fragments).
        slug_maps[article_id] = {}
        for locale in LOCALES:
            locale_blocks = parse_markdown(
                os.path.join(DOCS_DIR, f"{stem}{SOURCE_LOCALE_SUFFIX[locale]}.md"))
            _, fragment_map = assign_anchors(locale_blocks)
            slug_maps[article_id][locale] = fragment_map
        articles[article_id] = per_locale

    for article_id in HOWTO_ARTICLE_ORDER:
        articles[article_id] = {
            locale: build_howto_article(article_id, locale, source_revision)
            for locale in LOCALES
        }

    # Render per-locale HTML.
    for locale in LOCALES:
        for article_id, per_locale in articles.items():
            article = per_locale[locale]
            resolver = make_link_resolver(locale, slug_maps, article_id)
            body = render_article_html(article, locale, resolver, source_revision)
            files[f"help/articles/{locale}/{article_id}.html"] = body.encode("utf-8")

    files["help/styles/help.css"] = HELP_CSS.encode("utf-8")

    # Indexes.
    for locale in LOCALES:
        per_locale = {aid: articles[aid][locale] for aid in articles}
        files[f"help/index/{locale}.json"] = json_bytes(index_document(per_locale, locale),
                                                        compact=True)

    # Legacy projection.
    for locale in LOCALES:
        per_locale = {aid: articles[aid][locale] for aid in articles}
        name = "index.md" if locale == "en" else "index.zh-Hans.md"
        files[name] = legacy_document(per_locale, locale, source_revision).encode("utf-8")

    # Images.
    if with_images:
        files.update(convert_images())
    else:
        for name in IMAGE_FILES:
            files[f"help/assets/guide/{name}.webp"] = b""

    # Envelope + manifest.
    files["content.json"] = json_bytes(content_json(source_revision), compact=False)
    resources = []
    for path in sorted(files):
        if path in ("content.json", MANIFEST_PATH):
            continue
        data = files[path]
        resources.append({
            "path": path,
            "mimeType": mime_for(path),
            "byteCount": len(data),
            "sha256": sha256_hex(data),
        })
    files[MANIFEST_PATH] = json_bytes(manifest_json(source_revision, resources), compact=False)

    validate_package_constraints(files)
    validate_html_graph(files)
    return files


def validate_html_graph(files: Dict[str, bytes]) -> None:
    """Every in-package href/src/fragment must resolve to a real resource.

    This is a permanent build gate (also exercised by --check): no broken
    local link, missing anchor, or unmapped image may reach the App bundle.
    """
    manifest = json.loads(files[MANIFEST_PATH].decode("utf-8"))
    html_ids: Dict[str, set] = {}
    for path, data in files.items():
        if path.endswith(".html"):
            text = data.decode("utf-8")
            html_ids[path] = set(re.findall(r'id="([^"]+)"', text))
    for locale in LOCALES:
        index = json.loads(files[manifest["indexPaths"][locale]].decode("utf-8"))
        for article in index["articles"]:
            html_path = article["htmlPath"]
            if html_path not in files:
                raise BuildError(f"article html missing: {html_path}")
            ids = html_ids.get(html_path, set())
            for section in article["sections"]:
                if section["id"] not in ids:
                    raise BuildError(f"section {section['id']} missing in {html_path}")
    for path, data in files.items():
        if not path.endswith(".html"):
            continue
        directory = posixpath.dirname(path)
        text = data.decode("utf-8")
        for attribute, target in re.findall(r'(href|src)="([^"]+)"', text):
            if target.startswith(("http://", "https://", "mailto:")):
                if target.startswith("http://"):
                    raise BuildError(f"non-TLS link in {path}: {target}")
                continue
            if target.startswith("#"):
                anchor = target[1:]
                if not anchor:
                    raise BuildError(f"empty fragment in {path}")
                if anchor not in html_ids[path]:
                    raise BuildError(f"unresolved fragment {target} in {path}")
                continue
            file_part, _, anchor = target.partition("#")
            normalized = posixpath.normpath(posixpath.join(directory, file_part))
            if normalized not in files:
                raise BuildError(f"unresolved {attribute} target {target} in {path}")
            if anchor and anchor not in html_ids.get(normalized, set()):
                raise BuildError(f"unresolved fragment {target} in {path}")


def validate_package_constraints(files: Dict[str, bytes]) -> None:
    for path, data in files.items():
        if path in ("content.json", MANIFEST_PATH):
            if len(data) > MAX_MANIFEST_BYTES:
                raise BuildError(f"{path} exceeds {MAX_MANIFEST_BYTES} bytes")
        elif len(data) > MAX_FILE_BYTES:
            raise BuildError(f"{path} exceeds {MAX_FILE_BYTES} bytes")
    content = json.loads(files["content.json"].decode("utf-8"))
    if content.get("helpManifest") != MANIFEST_PATH:
        raise BuildError("content.json helpManifest mismatch")
    manifest = json.loads(files[MANIFEST_PATH].decode("utf-8"))
    if manifest["id"] != PACKAGE_ID or manifest["version"] != PACKAGE_VERSION:
        raise BuildError("manifest identity mismatch")
    if manifest.get("platform") != PLATFORM or set(manifest.get("sourceAudiences", {}).values()) - {"shared", PLATFORM}:
        raise BuildError("wrong platform in iOS help package")
    if manifest["sourceRevision"] != content["sourceRevision"]:
        raise BuildError("manifest/content.json sourceRevision mismatch")
    if set(manifest["indexPaths"]) != set(LOCALES):
        raise BuildError("manifest indexPaths must cover both locales")
    listed = {r["path"] for r in manifest["resources"]}
    expected = set(files) - {"content.json", MANIFEST_PATH}
    if listed != expected:
        missing = expected - listed
        extra = listed - expected
        raise BuildError(f"resource listing mismatch: missing={sorted(missing)} extra={sorted(extra)}")
    for resource in manifest["resources"]:
        data = files[resource["path"]]
        if len(data) != resource["byteCount"] or sha256_hex(data) != resource["sha256"]:
            raise BuildError(f"resource digest mismatch: {resource['path']}")
        if not SAFE_RELATIVE_PATH_OK(resource["path"]):
            raise BuildError(f"resource path invalid: {resource['path']}")
    for locale in LOCALES:
        index = json.loads(files[manifest["indexPaths"][locale]].decode("utf-8"))
        if index["locale"] != locale:
            raise BuildError(f"index locale mismatch: {locale}")
        if index.get("platform") != PLATFORM:
            raise BuildError(f"index platform mismatch: {locale}")
        seen = set()
        for article in index["articles"]:
            if article.get("audience") not in ("shared", PLATFORM):
                raise BuildError(f"wrong article audience: {article.get('id')}")
            for key in ("id",):
                value = article[key]
                if not IDENTIFIER_OK(value):
                    raise BuildError(f"article id invalid: {value}")
                if value in seen:
                    raise BuildError(f"duplicate article id: {value}")
                seen.add(value)
                for setting in article["settingIDs"]:
                    if setting not in KNOWN_SETTING_IDS:
                        raise BuildError(f"unknown setting id: {setting}")
                section_seen = set()
                for section in article["sections"]:
                    if not IDENTIFIER_OK(section["id"]):
                        raise BuildError(f"section id invalid: {section['id']}")
                    if section["id"] in section_seen:
                        raise BuildError(f"duplicate section id: {section['id']}")
                    section_seen.add(section["id"])


IDENTIFIER_OK = lambda value: bool(IDENTIFIER_RE.match(value)) and len(value.encode("utf-8")) <= 128

SAFE_PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")


def SAFE_RELATIVE_PATH_OK(value: str) -> bool:
    return (1 <= len(value.encode("utf-8")) <= 512 and bool(SAFE_PATH_RE.match(value))
            and not value.startswith("/") and not value.startswith("\\")
            and ".." not in value and not value.endswith("/"))


def validate_source_revision(value: str) -> None:
    if value == "":
        return
    if len(value) == 40 and re.fullmatch(r"[0-9a-f]{40}", value):
        return
    raise BuildError(f"sourceRevision must be empty or 40 lowercase hex characters: {value!r}")


# ---------------------------------------------------------------------------
# Output drivers
# ---------------------------------------------------------------------------

def write_outputs(files: Dict[str, bytes]) -> List[str]:
    written = []
    for root in (BUILTIN_OUT, AUTHORING_OUT):
        for path, data in files.items():
            target = os.path.join(root, path)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as handle:
                handle.write(data)
            written.append(target)
    return written


def check_outputs(files: Dict[str, bytes]) -> List[str]:
    """Compare freshly built bytes with on-disk outputs. Purely read-only."""
    problems = []
    for root in (BUILTIN_OUT, AUTHORING_OUT):
        for path, expected in files.items():
            target = os.path.join(root, path)
            if not os.path.exists(target):
                problems.append(f"missing on disk: {target}")
                continue
            with open(target, "rb") as handle:
                actual = handle.read()
            if actual != expected:
                problems.append(f"content differs: {target}")
        for existing in existing_output_files(root):
            if existing not in files:
                problems.append(f"unexpected extra file on disk: {os.path.join(root, existing)}")
    return problems


def existing_output_files(root: str) -> List[str]:
    found = []
    if not os.path.isdir(root):
        return found
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            full = os.path.join(dirpath, name)
            found.append(os.path.relpath(full, root))
    return found


def resolve_source_revision(explicit: Optional[str]) -> str:
    """Resolve the baked document revision.

    The default is the explicitly allowed empty value so that build → commit →
    check stays reproducible regardless of unrelated repository movement. A
    release owner can pin a document input revision with --source-revision or
    FLOE_HELP_SOURCE_REVISION.
    """
    if explicit is not None:
        return explicit
    env = os.environ.get("FLOE_HELP_SOURCE_REVISION")
    if env is not None:
        return env
    return ""


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", default="build", choices=("build", "check"))
    parser.add_argument("--check", dest="check_flag", action="store_true",
                        help="verify on-disk outputs against a fresh in-memory build")
    parser.add_argument("--source-revision", default=None,
                        help="40 lowercase hex characters, or empty (default: empty)")
    parser.add_argument("--docs-dir", default=None,
                        help="override the guide sources directory (fixture tests only)")
    parser.add_argument("--skip-images", action="store_true",
                        help="build without image conversion (tests only)")
    parser.add_argument("--builtin-out", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--authoring-out", default=None, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    global DOCS_DIR, GUIDE_IMAGES_DIR, BUILTIN_OUT, AUTHORING_OUT
    if args.docs_dir:
        DOCS_DIR = os.path.abspath(args.docs_dir)
        GUIDE_IMAGES_DIR = os.path.join(DOCS_DIR, "assets", "guide")
    if args.builtin_out:
        BUILTIN_OUT = os.path.abspath(args.builtin_out)
    if args.authoring_out:
        AUTHORING_OUT = os.path.abspath(args.authoring_out)

    try:
        revision = resolve_source_revision(args.source_revision)
        files = build_package(revision, with_images=not args.skip_images)
        command = "check" if args.check_flag else args.command
        if command == "build":
            write_outputs(files)
            print(f"built {PACKAGE_ID} {PACKAGE_VERSION} ({len(files)} files) "
                  f"at revision {revision or 'unpinned'}")
            for root in (BUILTIN_OUT, AUTHORING_OUT):
                print(f"  -> {root}")
        else:
            problems = check_outputs(files)
            if problems:
                for problem in problems:
                    print(f"CHECK FAIL: {problem}", file=sys.stderr)
                return 1
            print(f"check OK: {len(files)} files reproducible at revision {revision or 'unpinned'}")
        return 0
    except BuildError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
