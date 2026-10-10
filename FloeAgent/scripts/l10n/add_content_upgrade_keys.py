#!/usr/bin/env python3
"""Add the content-upgrade/localization keys for this task's new surfaces.

These keys are hand-maintained (not extracted from SwiftUI literals) because
several resolve through `FloeL10n.l` in non-View code or describe new settings
sections. Idempotent: existing keys are left untouched.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, "FloeApp/Resources/Localizable.xcstrings")

KEYS = {
    # Non-fatal run notice (local output safety cap). Distinct from provider
    # stop reasons (length) and from the error-card noFinalText surface.
    "thread.kind.notice": ("Notice", "提示"),
    "chat.notice.output_truncated.title": (
        "Reply shortened at the local safety limit",
        "回复已达本地安全上限并截断"),
    "chat.notice.output_truncated.message": (
        "The provider sent more text than this model's local output buffer "
        "(received %d bytes, buffer %d bytes). The saved reply keeps the "
        "received prefix. The model's configured limit was not changed and "
        "the request was not retried.",
        "提供方返回的文字超过该模型的本地输出缓冲（已接收 %d 字节，缓冲上限 %d 字节）。"
        "已保存收到的前缀内容；模型的输出上限未被改动，也不会自动重试。"),
    # Reasoning capability note: DeepSeek's medium is a compatibility alias.
    "providers.model_editor.reasoning.deepseek_medium_note": (
        "DeepSeek supports low/high/max natively; its API accepts medium as a "
        "compatibility alias and maps it to high, so there is no native "
        "medium tier.",
        "DeepSeek 原生支持 low/high/max；其 API 接受 medium 作为兼容别名并映射为 high，"
        "没有原生 medium 档。"),
    # Settings → Internal prompts (signed floe.prompts.core review surface).
    "settings.section.internal_prompts": ("Internal prompts", "内部提示词"),
    "settings.internal_prompts.status.header": ("Core prompts", "核心提示词"),
    "settings.internal_prompts.installed_version": ("Installed version", "已安装版本"),
    "settings.internal_prompts.available_version": ("Available version", "可用版本"),
    "settings.internal_prompts.built_in_version": ("Built into this app", "随应用内置"),
    "settings.internal_prompts.digest": ("Content digest", "内容摘要"),
    "settings.internal_prompts.source_revision": ("Source revision", "来源版本"),
    "settings.internal_prompts.source_index": ("Signed feed path", "签名内容源路径"),
    "settings.internal_prompts.auto_update": (
        "Automatically apply prompt updates",
        "自动应用提示词更新"),
    "settings.internal_prompts.auto_update_note": (
        "This is the global declarative-content policy; it never applies "
        "content with scripts and never grants new permissions.",
        "这是全局声明式内容策略；它不会自动应用含脚本的内容，也不会授予任何新权限。"),
    "settings.internal_prompts.sections.header": (
        "Published sections (read-only)",
        "已发布章节（只读）"),
    "settings.internal_prompts.sections.empty": (
        "No installed prompt package yet; the app's built-in prompts stay active.",
        "尚未安装提示词内容包；应用内置提示词保持生效。"),
    "settings.internal_prompts.sections.footer": (
        "These sections are signed data reviewed here for transparency. They "
        "are not injected as system prompts by this screen.",
        "这些章节是经签名验证的数据，仅在此透明展示；本页不会将其注入为系统提示词。"),
    "settings.internal_prompts.fixed_rules.header": (
        "Fixed rules owned by app code",
        "由应用代码固定的规则"),
    "settings.internal_prompts.fixed_rules.note": (
        "The rules below are compiled into the app. They are never editable "
        "here and can never be changed by remote content.",
        "以下规则编译在应用内，无法在此编辑，也不会被远程内容更改。"),
    "settings.internal_prompts.fixed_rules.permission": (
        "Tool calls that need permission always require your explicit approval; "
        "content updates never widen permissions.",
        "需要权限的工具调用始终需要你明确批准；内容更新绝不会扩大权限。"),
    "settings.internal_prompts.fixed_rules.tool_protocol": (
        "The tool request/result protocol is enforced by the runtime; "
        "content cannot redefine it.",
        "工具请求/结果协议由运行时强制执行；内容无法重新定义。"),
    "settings.internal_prompts.fixed_rules.truthfulness": (
        "Verification and honest-failure rules are code-owned and cannot be "
        "overridden by content.",
        "验证与诚实失败规则由代码掌控，内容无法覆盖。"),
    "settings.internal_prompts.fixed_rules.recovery": (
        "Recovery, rollback and data-preservation behavior is code-owned; "
        "installed content is retained and never silently discarded.",
        "恢复、回退与数据保全行为由代码掌控；已安装内容始终保留，不会被静默丢弃。"),
    # Settings → General → Content updates management.
    "settings.content_updates.section": ("Content updates", "内容更新"),
    "settings.content_updates.row": ("Content updates", "内容更新管理"),
    "settings.content_updates.title": ("Content updates", "内容更新管理"),
    "settings.content_updates.footer": (
        "Signed content from the official hub. Updates never grant "
        "permissions; approvals stay with you.",
        "来自官方内容中心的签名内容。更新不会授予权限，授权始终由你确认。"),
    "settings.content_updates.policy.header": ("Update policy", "更新策略"),
    "settings.content_updates.toggle.auto_checks": (
        "Check for updates automatically",
        "自动检查更新"),
    "settings.content_updates.toggle.auto_apply": (
        "Automatically apply declarative updates",
        "自动应用声明式内容更新"),
    "settings.content_updates.toggle.auto_install_scripts": (
        "Automatically install content with scripts",
        "自动安装含脚本的内容"),
    "settings.content_updates.scripts_warning": (
        "Scripted content never gains permissions automatically from this "
        "toggle; every permission still needs your explicit approval.",
        "此开关不会让含脚本的内容自动获得权限；每项权限仍需你明确批准。"),
    "settings.content_updates.toggle.wifi_only": (
        "Automatic downloads on Wi-Fi only",
        "仅在 Wi-Fi 下自动下载"),
    "settings.content_updates.policy.footer": (
        "Every update is verified against the app's fixed signing key before "
        "it can be activated. Blocked or incompatible versions are kept, "
        "never implicitly installed.",
        "所有更新在激活前都会通过应用固定签名密钥验证。被阻止或不兼容的版本会保留，"
        "绝不隐式安装。"),
    "settings.content_updates.kind.prompts": ("Prompts", "提示词"),
    "settings.content_updates.kind.providers": ("Provider catalog", "提供商目录"),
    "settings.content_updates.kind.models": ("Model catalog", "模型目录"),
    "settings.content_updates.kind.help": ("Help documents", "帮助文档"),
    "settings.content_updates.kind.templates": ("Templates", "模板"),
    "settings.content_updates.kind.none": (
        "No installed or available content for this kind.",
        "此类别尚无已安装或可更新的内容。"),
    "settings.content_updates.installed": ("Installed", "已安装"),
    "settings.content_updates.available": ("Available", "可用"),
    "settings.content_updates.not_installed": ("Not installed", "未安装"),
    "settings.content_updates.not_available": ("No signed feed yet", "暂无签名内容源"),
    "settings.content_updates.release_notes": ("Release notes", "更新说明"),
    "settings.content_updates.installing": ("Installing…", "正在安装…"),
    "settings.content_updates.pinned_badge": ("Pinned", "已固定"),
    "settings.content_updates.action.install": ("Install", "安装"),
    "settings.content_updates.action.rollback": ("Roll back", "回退"),
    "settings.content_updates.action.pin": ("Pin", "固定"),
    "settings.content_updates.action.unpin": ("Unpin", "取消固定"),
    "settings.content_updates.check_now": ("Check now", "立即检查"),
    "settings.content_updates.last_check": ("Last checked: %@", "上次检查：%@"),
    "settings.content_updates.decision.up_to_date": ("Up to date", "已是最新"),
    "settings.content_updates.decision.update": ("Update available", "有可用更新"),
    "settings.content_updates.decision.blocked.downgrade": (
        "Blocked: a newer version is installed",
        "已阻止：本机版本更新"),
    "settings.content_updates.decision.blocked.same_version": (
        "Blocked: same version has different content",
        "已阻止：同版本内容不一致"),
    "settings.content_updates.decision.blocked.incompatible_app": (
        "Blocked: requires a newer app",
        "已阻止：需要更新应用"),
    "settings.content_updates.decision.blocked.missing_dependency": (
        "Blocked: a dependency is missing",
        "已阻止：缺少依赖"),
    "settings.content_updates.decision.blocked.pinned": (
        "Blocked: pinned or rolled back",
        "已阻止：已固定或已回退"),
    "settings.content_updates.decision.blocked.invalid": (
        "Blocked: this signed entry cannot be activated safely",
        "已阻止：该签名条目无法安全激活"),
    "settings.content_updates.catalog.header": ("Provider catalog", "提供商目录"),
    "settings.content_updates.catalog.project": ("Source project", "来源项目"),
    "settings.content_updates.catalog.digest": ("Document SHA-256", "文档 SHA-256"),
    "settings.content_updates.catalog.fetched_at": ("Fetched at", "获取时间"),
    "settings.content_updates.catalog.provider_count": (
        "Providers: %d",
        "提供商数量：%d"),
    "settings.content_updates.catalog.unavailable": (
        "No catalog document is bundled or installed.",
        "尚未内置或安装目录文档。"),
    "settings.content_updates.catalog.refresh": ("Refresh catalog", "刷新目录"),
    "settings.content_updates.catalog.refreshing": ("Refreshing…", "正在刷新…"),
    "settings.content_updates.catalog.note": (
        "Unverified providers are still listed with their reason, but they "
        "are not activated and cannot be selected for requests.",
        "未经验证的提供商会连同原因一并列出，但不会激活，也无法被选择用于请求。"),
    "settings.content_updates.error.title": ("Content update failed", "内容更新失败"),
    # ContentUpdateCenter error descriptions surfaced by the views above.
    "content.update.error.signature": (
        "The update signature could not be verified.",
        "无法验证更新签名。"),
    "content.update.error.feed": (
        "The signed content feed is invalid.",
        "签名内容源无效。"),
    "content.update.error.archive": (
        "The content archive is unsafe, oversized or corrupt.",
        "内容归档不安全、过大或已损坏。"),
    "content.update.error.immutable": (
        "A published content version cannot change; publish a new version "
        "instead.",
        "已发布的内容版本不可更改；请发布新版本。"),
    "content.update.error.incompatible": (
        "Update Floe before activating this content version.",
        "请先更新 Floe 再激活此内容版本。"),
    "content.update.error.missing_dependency": (
        "A required content dependency is not available.",
        "缺少所需的内容依赖。"),
    "content.update.error.generic": (
        "Content update failed: %@",
        "内容更新失败：%@"),
    "content.update.error.storage_unavailable": (
        "Content storage is unavailable, so signed content cannot be checked "
        "or installed. Free device storage and reopen Floe.",
        "内容存储不可用，无法检查或安装签名内容。请释放设备存储空间后重新打开 Floe。"),
    "content.update.error.corrupt_state": (
        "Stored content state is unreadable; installed content was left "
        "untouched. Reopen Floe, then check again.",
        "已保存的内容状态无法读取；已安装内容未被改动。请重新打开 Floe 后再次检查。"),
    "content.update.error.conflict": (
        "This content version cannot be applied safely (pinned, downgrade, "
        "incompatible, missing dependency or already installed bytes).",
        "该内容版本无法安全应用（已固定、降级、不兼容、缺少依赖或已存在相同版本）。"),
    "content.update.error.persistence": (
        "The content update could not be saved; the previous version remains "
        "active.",
        "内容更新保存失败；上一版本保持生效。"),
    "skills.import_folder": ("Import folder", "从文件夹导入"),
    "skills.auto_scripted_updates.label": (
        "Auto-update skill scripts when permissions do not expand",
        "权限不变时自动更新 Skill 脚本"),
    "skills.auto_scripted_updates.title": ("Scripted skill updates", "脚本型 Skill 更新"),
    "skills.auto_scripted_updates.footer": (
        "When enabled, signed skill updates that add no new capabilities or "
        "tools are applied automatically; any permission expansion still "
        "waits for your review. This shared switch also controls scripted "
        "content updates in Settings \u2192 Content updates.",
        "开启后，未新增能力或工具的签名 Skill 更新会自动应用；任何权限扩大仍会等待你复核。"
        "此开关与“设置 \u2192 内容更新”中的脚本内容更新共用同一策略。"),
    "runtime.content_update.addendum_header": (
        "Remotely updated guidance (declarative content). Fixed safety, "
        "permission and tool rules always take precedence and cannot be "
        "updated remotely:",
        "可远程更新的指导内容（声明性内容）。固定安全、权限与工具规则始终优先，"
        "且不能远程更新："),
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
    print("content-upgrade keys added:", added, "total:", len(strings))


if __name__ == "__main__":
    main()
