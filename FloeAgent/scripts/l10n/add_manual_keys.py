#!/usr/bin/env python3
"""Add semantic keys used only by hand-maintained surfaces (App Intents,
ink tools, Summary formats) that the generic catalog migration doesn't emit.
Idempotent."""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, "FloeApp/Resources/Localizable.xcstrings")

KEYS = {
    "shortcuts.cadence.type_name": ("Repeat", "重复"),
    "shortcuts.cadence.once": ("Once", "一次"),
    "shortcuts.cadence.daily": ("Daily", "每天"),
    "shortcuts.cadence.weekly": ("Weekly", "每周"),
    "shortcuts.intent.send_to_floe.title": ("Send to Floe for processing", "把文字发给 Floe Agent 处理"),
    "shortcuts.intent.send_to_floe.description": (
        "Send text to Floe Agent for processing (summaries, analysis, etc.).",
        "把文字发给 Floe Agent 处理（总结、分析等）"),
    "shortcuts.intent.send_to_floe.param_text": ("Text", "文字内容"),
    "shortcuts.intent.send_to_floe.param_prompt": ("Instruction", "指令"),
    "shortcuts.intent.send_to_floe.prompt_default": ("Summarize this text", "总结这段文字"),
    "shortcuts.intent.send_to_floe.summary": (
        "Send %@ to Floe with the instruction: %@", "把 %@ 发给 Floe，指令：%@"),
    "shortcuts.intent.send_to_floe.result_placed": (
        "Placed in Floe; open it to review and send.", "已放入 Floe，打开后可检查并发送。"),
    "shortcuts.intent.create_task.title": ("New Floe task", "新建 Floe 任务"),
    "shortcuts.intent.create_task.description": (
        "Create a new task in Floe Agent.", "在 Floe Agent 中新建一个任务"),
    "shortcuts.intent.create_task.param_description": ("Task description", "任务描述"),
    "shortcuts.intent.create_task.summary": ("New task: %@", "新建任务：%@"),
    "shortcuts.intent.run_task.title": ("Run Floe task now", "立即运行 Floe 任务"),
    "shortcuts.intent.run_task.description": (
        "Create and start a Floe task in the background, suited to Shortcuts automation.",
        "在后台创建并开始一个 Floe 任务，适合快捷指令自动化。"),
    "shortcuts.intent.run_task.param_task": ("Task", "任务"),
    "shortcuts.intent.run_task.param_title": ("Title", "标题"),
    "shortcuts.intent.run_task.summary": ("Run Floe task: %@", "运行 Floe 任务：%@"),
    "shortcuts.intent.run_task.result_started": (
        "Floe task has started (%@).", "Floe 任务已开始（%@）。"),
    "shortcuts.intent.schedule_task.title": ("Schedule Floe task", "安排 Floe 自动任务"),
    "shortcuts.intent.schedule_task.description": (
        "Add the task to Floe's background scheduling; iOS decides when the system wakes it.",
        "把任务加入 Floe 的后台调度；系统唤醒时间由 iOS 决定。"),
    "shortcuts.intent.schedule_task.param_task": ("Task", "任务"),
    "shortcuts.intent.schedule_task.param_title": ("Title", "标题"),
    "shortcuts.intent.schedule_task.param_time": ("Time", "时间"),
    "shortcuts.intent.schedule_task.param_repeat": ("Repeat", "重复"),
    "shortcuts.intent.schedule_task.summary": (
        "Schedule %@ in %@, %@", "在 %2$@ 安排 %1$@，%3$@"),
    "shortcuts.intent.schedule_task.result_saved": (
        "Floe saved the automation (%@).", "Floe 已保存该自动任务（%@）。"),
    "shortcuts.app_shortcut.send_to_floe": ("Send to Floe", "发给 Floe"),
    "shortcuts.app_shortcut.run_task_now": ("Run task now", "立即运行任务"),
    "shortcuts.app_shortcut.schedule_automation": ("Schedule automation", "安排自动任务"),
    "notes.ink.tool.pen": ("Pen", "笔"),
    "notes.ink.tool.marker": ("Highlighter", "荧光笔"),
    "notes.ink.tool.eraser": ("Eraser", "橡皮"),
    "notes.ink.tool.lasso": ("Lasso", "套索"),
    "notes.ink.tool.ai_selection": ("AI selection", "AI 选区"),
    "notes.ink.tool.preview_tap_to_choose": ("Preview; tap to choose", "预览，轻触选择"),
    "workspace.engineering_file_preview.cannot_persist_conversation_binding": (
        "Could not persist the drawing assistant conversation binding.",
        "无法持久化图纸助手会话绑定。"),
    "workspace.engineering_file_preview.cannot_persist_records": (
        "Could not persist the drawing assistant record.", "无法持久化图纸助手记录。"),
    "workspace.engineering_file_preview.cannot_persist_receipts": (
        "Could not persist the drawing apply receipt.", "无法持久化图纸应用回执。"),
    "notes.notes_document_editor.no_extractable_text_use_attachment": (
        "This selection has no directly extractable text; use the attached image.",
        "此选区没有可直接提取的文字，请使用附图。"),
    "chat.thread_composer_view.specify_in_next_request": (
        "Specify $%@ in the next request", "在下一条请求中指定 $%@"),
    "app.floe_agent_app.linux_environments_count": ("%@ Linux environments", "%@ 个 Linux 环境"),
    "app.floe_agent_app.local_services_count": ("%@ local services", "%@ 个本地服务"),
    "app.floe_agent_app.list_separator": (", ", "、"),
    "app.floe_agent_app.local_models_and_linux_environments_cannot": (
        "This device is running %@. Local models and Linux environments cannot run at the same time: continuing stops these environments first (disk and data are preserved), or cancel this local model request.",
        "本机正在运行 %@。本地模型与 Linux 环境不能同时运行：继续将先停止这些环境（磁盘与数据会保留），或取消本次本地模型请求。"),
    "settings.general.language.restart_note": (
        "Save your work, then quit and reopen Floe to apply the language to every screen.",
        "请先保存当前工作，再退出并重新打开 Floe，使所有界面完整切换语言。"),
    "persistence.run_store.legacy_usage_label": ("Earlier tasks (not recorded)", "历史任务（未记录）"),
    "core.managed_python_package_spec_parser.supported_commands": (
        "Supports pip install, uninstall, list, show, freeze, check and --version; native packages need compatible builds.",
        "支持 pip install、uninstall、list、show、freeze、check 与 --version；原生包需要兼容构建"),
    "canvas.artifact.action.generate": ("Generate", "生成"),
    "chat.step_group_view.tool_calls.one": ("%@ tool call", "%@ 个工具调用"),
    "chat.step_group_view.thinking_segments.one": ("%@ thinking segment", "%@ 段思考"),
    "platform.background_run_coordinator.tool_calls.one": ("\n%@ tool call%@", "\n工具调用 %@ 次%@"),
    "settings.usage_statistics_view.tasks.one": ("%@ · %@ task", "%@ · %@ 个任务"),
    "memory.memory_view.involves_memories.one": ("Involves %@ memory", "涉及 %@ 条记忆"),
    "runtime.task_checklist_store.items_canceled.one": ("· %@ item canceled", "· 已取消 %@ 项"),
    "packages.environment_management_service.verified_and_refreshed_packages.one": (
        "Verified and refreshed %@ package", "已验证并刷新 %@ 个软件包"),
    "workspace.file_tree_view.delete_items.one": ("Delete %@ item", "删除 %@ 项"),
    "workspace.workspace_canvas_view.referenced_by_canvas_nodes.one": (
        "Referenced by %@ canvas node", "被 %@ 个画布节点引用"),
    "canvas.artifact.import.photos_partial.format.one": (
        "Imported %@ artifact; %@ Photos items could not be read.",
        "已导入 %@ 个产物，另有 %@ 个相册项目读取失败。"),
    "canvas.builtin.markdown_default": (
        "# Markdown\n\nDouble-tap to edit the content.",
        "# Markdown\n\n双击编辑内容。"),
    "notes.notes_knowledge_picker.pages.one": ("%@ page", "%@ 页"),
    "notes.notes_root_view.topics.one": ("%@ topic", "%@ 个主题"),
    "workspace.workspace_canvas_view.tasks.one": ("%@ task", "%@ 个任务"),
    "workspace.workspace_canvas_view.prompts.one": ("%@ prompt", "%@ 条提示词"),
    "chat.step_group_view.items_running.one": ("%@ item running", "%@ 项运行中"),
    "chat.step_group_view.items_need_review.one": ("%@ item needs review", "%@ 项需要查看"),
    "skills.skills_view.tools_available.one": ("%@ tool available", "可用工具 %@ 个"),
    "memory.memory_view.memories_deleted.one": ("%@ memory deleted.", "已删除 %@ 条记忆。"),
    "notes.notes_root_view.documents_are_not_fully_indexed_yet.one": (
        "%@ document is not fully indexed yet; search results may be incomplete.",
        "%@ 份文档尚未完整索引，搜索结果可能不完整。"),
    "workspace.i_d_e_language_run_view.files_will_be_uploaded_excluded.one": (
        "%@ file (%@) will be uploaded; %@ excluded.", "将上传 %@ 个文件（%@）；排除 %@ 个。"),
    "settings.data_management_view.items.one": ("%@ item · %@", "%@ 项 · %@"),
    "localmodels.tokens_per_second.one": ("%@ token/s", "%@ tokens/s"),
    "settings.usage_statistics_view.fragments_sec.one": ("%@ token/s", "%@ tokens/秒"),
    "workspace.i_d_e_native_text_workspace.buffers_are_open_and_all_have.one": (
        "%@ buffer is open with unsaved changes, so “%@” cannot be opened. Save it or close the buffer first; current drafts were kept.",
        "已打开 %@ 个缓冲区且全部有未保存的修改，无法打开「%@」。请先保存全部或关闭一个缓冲区；当前草稿均已保留。"),
    "localmodels.local_provider_adapter.local_models_run_in_the_foreground_only": (
        "Local models run in the foreground only: this generation paused safely when the app went to the background (stage: %@, waited %@ sec). When you return to Floe it will try to resume from the saved checkpoint; if retries are exhausted you can tap “Continue”. Completed tools are not replayed.",
        "本地模型只能在前台运行：应用离开前台时本次生成已安全暂停（阶段：%@，已等待 %@ 秒）。返回 Floe 后将尝试从保存的检查点恢复；若重试次数已用完，可点击“继续”。已完成的工具不会重放。"),
}

# App Intents Summary literals include the %@ parameter tokens in the key.
SUMMARY_KEYS = {
    "shortcuts.intent.send_to_floe.summary %@ %@": (
        "Send %@ to Floe with the instruction: %@", "把 %@ 发给 Floe，指令：%@"),
    "shortcuts.intent.create_task.summary %@": ("New task: %@", "新建任务：%@"),
    "shortcuts.intent.run_task.summary %@": ("Run Floe task: %@", "运行 Floe 任务：%@"),
    "shortcuts.intent.schedule_task.summary %@ %@ %@": (
        "Schedule %2$@ in %1$@, %3$@", "在 %2$@ 安排 %1$@，%3$@"),
}


def main():
    cat = json.load(open(CATALOG, encoding="utf-8"))
    strings = cat["strings"]
    added = 0
    for key, (en, zh) in {**KEYS, **SUMMARY_KEYS}.items():
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

    # Overrides for pre-existing catalog entries whose zh-Hans value still
    # carried the English half, or whose placeholders disagreed.
    overrides = {
        ("workspace.git_hub_actions_job_center.snapshot_exceeds_bytes", "zh-Hans"):
            "快照总大小超过上限 %@ 字节。",
        ("workspace.git_hub_actions_job_center.snapshot_exceeds_files", "zh-Hans"):
            "快照文件数超过上限 %@。",
        ("workspace.workspace_center.cannot_re_open_the_external_workspace", "zh-Hans"):
            "无法重新访问外部工作区（安全作用域授权失败）：%@",
        ("shortcuts.intent.schedule_task.summary", "en"):
            "Schedule %2$@ in %1$@, %3$@",
        ("shortcuts.intent.schedule_task.summary", "zh-Hans"):
            "在 %2$@ 安排 %1$@，%3$@",
        ("settings.usage_statistics_view.fragments_sec", "en"): "%@ tokens/s",
        ("settings.usage_statistics_view.fragments_sec", "zh-Hans"): "%@ tokens/秒",
    }
    for (key, locale), value in overrides.items():
        entry = strings.get(key)
        if not isinstance(entry, dict):
            continue
        entry.setdefault("localizations", {}).setdefault(
            locale, {"stringUnit": {"state": "translated", "value": value}})
        entry["localizations"][locale]["stringUnit"]["value"] = value

    cat.setdefault("sourceLanguage", "en")
    cat.setdefault("version", "1.0")
    cat["strings"] = dict(sorted(strings.items()))
    json.dump(cat, open(CATALOG, "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    print("manual keys added:", added, "total:", len(strings))


if __name__ == "__main__":
    main()
