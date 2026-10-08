#!/usr/bin/env python3
"""Apply hand-maintained localization for surfaces the generic AST migration
cannot model: enum display keys, ink-tool labels, App Intents and the widget.
Idempotent on a freshly-migrated tree.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


def write(rel, s):
    with open(os.path.join(ROOT, rel), "w", encoding="utf-8") as fh:
        fh.write(s)


def main():
    # --- NotesRootView: filter + creation enums (raw value is identity) ---
    p = "FloeApp/Notes/NotesRootView.swift"
    s = read(p)
    s = s.replace(
        '    private enum SectionFilter: String, CaseIterable {\n'
        '        case recent = "最近", all = "全部内容", maps = "思维导图", favorites = "收藏", trash = "回收站"\n'
        '    }',
        '    private enum SectionFilter: String, CaseIterable {\n'
        '        case recent, all, maps, favorites, trash\n'
        '        var titleKey: LocalizedStringKey {\n'
        '            switch self {\n'
        '            case .recent: "home.recent"\n'
        '            case .all: "notes.notes_root_view.all_content"\n'
        '            case .maps: "notes.notes_office_view.mind_map"\n'
        '            case .favorites: "notes.notes_root_view.favorites"\n'
        '            case .trash: "notes.notes_root_view.trash"\n'
        '            }\n'
        '        }\n'
        '    }')
    s = s.replace(
        '    private enum Creation: String, Identifiable {\n'
        '        case note = "新建手记", map = "新建思维导图", notebook = "新建笔记本"\n'
        '        case word = "新建 Word 文档", sheet = "新建 Excel 表格", slides = "新建 PowerPoint 演示文稿"\n'
        '        var id: String { rawValue }\n'
        '    }',
        '    private enum Creation: String, Identifiable {\n'
        '        case note, map, notebook, word, sheet, slides\n'
        '        var id: String { rawValue }\n'
        '        var titleKey: LocalizedStringKey {\n'
        '            switch self {\n'
        '            case .note: "notes.notes_root_view.blank_note"\n'
        '            case .map: "notes.notes_office_view.mind_map"\n'
        '            case .notebook: "notes.notes_root_view.notebook"\n'
        '            case .word: "notes.notes_root_view.word_document"\n'
        '            case .sheet: "notes.notes_root_view.excel_spreadsheet"\n'
        '            case .slides: "notes.notes_root_view.powerpoint_presentation"\n'
        '            }\n'
        '        }\n'
        '    }')
    s = s.replace("Text($0.rawValue).tag($0)", "Text($0.titleKey).tag($0)")
    s = s.replace(".navigationTitle(kind.rawValue)", ".navigationTitle(kind.titleKey)")
    write(p, s)

    # --- Ink tool localized labels (raw value remains persisted state) ---
    p = "FloeApp/Notes/NotesPalettePresentation.swift"
    s = read(p)
    s = s.replace(
        'enum NotesInkTool: String, CaseIterable {\n'
        '    case pen = "笔", marker = "荧光笔", eraser = "橡皮", lasso = "套索", region = "AI 选区"\n'
        '    var icon: String {',
        'enum NotesInkTool: String, CaseIterable {\n'
        '    case pen = "笔", marker = "荧光笔", eraser = "橡皮", lasso = "套索", region = "AI 选区"\n'
        '    /// Localized UI label. The raw value is persisted and stays stable.\n'
        '    var localizedTitle: LocalizedStringKey {\n'
        '        switch self {\n'
        '        case .pen: "notes.ink.tool.pen"\n'
        '        case .marker: "notes.ink.tool.marker"\n'
        '        case .eraser: "notes.ink.tool.eraser"\n'
        '        case .lasso: "notes.ink.tool.lasso"\n'
        '        case .region: "notes.ink.tool.ai_selection"\n'
        '        }\n'
        '    }\n'
        '    var localizedAccessibilityTitle: String {\n'
        '        switch self {\n'
        '        case .pen: FloeL10n.l("notes.ink.tool.pen")\n'
        '        case .marker: FloeL10n.l("notes.ink.tool.marker")\n'
        '        case .eraser: FloeL10n.l("notes.ink.tool.eraser")\n'
        '        case .lasso: FloeL10n.l("notes.ink.tool.lasso")\n'
        '        case .region: FloeL10n.l("notes.ink.tool.ai_selection")\n'
        '        }\n'
        '    }\n'
        '    var icon: String {')
    s = s.replace(
        "let title = value == .pen ? inkPreferences.selectedPen.title : value.rawValue",
        "let title = value == .pen ? inkPreferences.selectedPen.title : value.localizedAccessibilityTitle")
    s = s.replace('.accessibilityValue(isPreviewed ? "预览，轻触选择" : "")',
                  '.accessibilityValue(isPreviewed ? FloeL10n.l("notes.ink.tool.preview_tap_to_choose") : "")')
    write(p, s)

    p = "FloeApp/Notes/NotesDocumentEditor.swift"
    s = read(p)
    s = s.replace(
        "Label(value == .pen ? inkPreferences.selectedPen.title : value.rawValue,",
        "Label(value == .pen ? inkPreferences.selectedPen.title : value.localizedTitle,")
    s = s.replace(
        "}.accessibilityLabel(value == .pen ? inkPreferences.selectedPen.title : value.rawValue).accessibilityAddTraits",
        "}.accessibilityLabel(value == .pen ? inkPreferences.selectedPen.title : value.localizedAccessibilityTitle).accessibilityAddTraits")
    write(p, s)

    # --- Widget ---
    p = "FloeWidgets/FloeWidgets.swift"
    s = read(p)
    if "import FloeCore" not in s:
        s = s.replace("import SwiftUI\n", "import SwiftUI\nimport FloeCore\n", 1)
    if "FloeL10n.bootstrap()" not in s:
        s = s.replace(
            "struct FloeWidgetProvider: TimelineProvider {\n    private static let appGroupID = \"group.org.floeagent.ios\"\n",
            "struct FloeWidgetProvider: TimelineProvider {\n    private static let appGroupID = \"group.org.floeagent.ios\"\n\n"
            "    init() {\n"
            "        // Widgets run in their own process; resolve the language\n"
            "        // chosen in the main app (mirrored into the App Group).\n"
            "        FloeL10n.bootstrap()\n"
            "    }\n")
    s = s.replace('Text("暂无进行中任务")', 'Text(FloeL10n.l("widget.empty_active_tasks"))')
    s = s.replace('Label("新建任务", systemImage: "plus.circle.fill")',
                  'Label(FloeL10n.l("widget.new_task"), systemImage: "plus.circle.fill")')
    s = s.replace('.description("查看进行中任务，快速发起新任务")',
                  '.description(FloeL10n.l("widget.description"))')
    write(p, s)

    # --- App Intents (LocalizedStringResource/Summary metadata) ---
    template = os.path.join(ROOT, "scripts/l10n/FloeShortcuts.template.swift")
    if os.path.exists(template):
        write("FloeApp/Shortcuts/FloeShortcuts.swift", read_rel(template))

    # --- Type corrections the generic migration cannot infer ---

    # LocalizedStringKey-typed computed properties must return key literals.
    p = "FloeApp/Chat/ThreadComposerView.swift"
    s = read(p)
    for key in [
        "chat.thread_composer_view.requesting_microphone_permission",
        "chat.thread_composer_view.preparing_speech_recognition",
        "chat.thread_composer_view.listening_to_you",
        "chat.thread_composer_view.finishing_transcription",
        "settings.general_settings_view.voice_input",
    ]:
        s = s.replace(f'FloeL10n.l("{key}")', f'"{key}"')
    write(p, s)

    # Value arguments to FloeL10n must be string-representable; Substring
    # is not accepted by CVarArg-style APIs historically, so wrap explicitly.
    p = "FloeApp/Workbench/TaskInspectorViews.swift"
    s = read(p)
    s = s.replace("child.parentID.uuidString.prefix(8)",
                  "String(child.parentID.uuidString.prefix(8))")
    write(p, s)

    # Label helpers that take LocalizedStringKey receive catalog keys.
    p = "FloeApp/Hosts/HostListView.swift"
    s = read(p)
    s = s.replace('actionLabel(FloeL10n.l("workspace.workspace_canvas_view.edit"), systemImage: "pencil")',
                  'actionLabel("workspace.workspace_canvas_view.edit", systemImage: "pencil")')
    write(p, s)

    # Ink brush label needs both string and key forms.
    p = "FloeApp/Notes/NotesInkPreferences.swift"
    s = read(p)
    if "var keyTitle: LocalizedStringKey" not in s:
        import re
        m = re.search(r"    var title: String \{\n(?:.*?\n)*?    \}\n", s)
        if m:
            keys = {
                "notes.notes_ink_preferences.ballpoint_pen": "pen",
                "notes.notes_ink_preferences.fountain_pen": "fountainPen",
                "notes.notes_ink_preferences.fine_liner": "monoline",
                "notes.notes_ink_preferences.pencil": "pencil",
                "notes.notes_ink_preferences.crayon": "crayon",
                "notes.notes_ink_preferences.watercolor": "watercolor",
                "notes.notes_ink_preferences.calligraphy_pen": "reed",
                "notes.notes_ink_preferences.highlighter": "marker",
            }
            cases = "\n".join(f'        case .{case}: "{key}"'
                              for key, case in keys.items())
            block = ("\n\n    /// Same label as `title` but as a SwiftUI `LocalizedStringKey`.\n"
                     "    var keyTitle: LocalizedStringKey {\n"
                     "        switch self {\n" + cases + "\n        }\n    }\n")
            s = s[:m.end()] + block + s[m.end():]
            write(p, s)

    # Bodies typed `LocalizedStringKey` must contain key literals, not
    # resolved strings; convert every `FloeL10n.l("k")` inside such a body.
    import subprocess
    hits = subprocess.run(
        ["rg", "-l", r":\s*LocalizedStringKey\s*\{|->\s*LocalizedStringKey\s*\{",
         os.path.join(ROOT, "FloeApp"), os.path.join(ROOT, "Sources"),
         "-g", "*.swift"],
        capture_output=True, text=True).stdout.splitlines()
    for path in hits:
        fix_lsk_bodies(os.path.relpath(path, ROOT))

    # The ink toolbar label ternary mixes LocalizedStringKey forms; break it
    # into locals so the type checker converges quickly.
    p = "FloeApp/Notes/NotesDocumentEditor.swift"
    s = read(p)
    old_label = ('                        Label(value == .pen ? inkPreferences.selectedPen.title : value.localizedTitle,\n'
                 '                              systemImage: value == .pen ? inkPreferences.selectedPen.icon : value.icon).labelStyle(.iconOnly)')
    new_label = ('                        let labelTitle: LocalizedStringKey = value == .pen ? inkPreferences.selectedPen.keyTitle : value.localizedTitle\n'
                 '                        let labelIcon = value == .pen ? inkPreferences.selectedPen.icon : value.icon\n'
                 '                        Label(labelTitle, systemImage: labelIcon).labelStyle(.iconOnly)')
    if old_label in s:
        s = s.replace(old_label, new_label)
    write(p, s)

    # Residual user-facing error strings the generic sweep skips.
    p = "FloeApp/Workspace/EngineeringFilePreview.swift"
    s = read(p)
    s = s.replace('"无法持久化图纸助手会话绑定。"',
                  'FloeL10n.l("workspace.engineering_file_preview.cannot_persist_conversation_binding")')
    s = s.replace('"无法持久化图纸助手记录。"',
                  'FloeL10n.l("workspace.engineering_file_preview.cannot_persist_records")')
    s = s.replace('"无法持久化图纸应用回执。"',
                  'FloeL10n.l("workspace.engineering_file_preview.cannot_persist_receipts")')
    write(p, s)
    p = "FloeApp/Notes/NotesDocumentEditor.swift"
    s = read(p)
    s = s.replace('\(text.isEmpty ? "此选区没有可直接提取的文字，请使用附图。" : text)',
                  '\(text.isEmpty ? FloeL10n.l("notes.notes_document_editor.no_extractable_text_use_attachment") : text)')
    write(p, s)
    p = "FloeApp/Chat/ThreadComposerView.swift"
    s = read(p)
    s = s.replace('subtitle: "在下一条请求中指定 $\($0.id)",',
                  'subtitle: FloeL10n.l("chat.thread_composer_view.specify_in_next_request", "$", $0.id),')
    write(p, s)

    # Language picker restart note (full switch applies on next launch).
    p = "FloeApp/Settings/GeneralSettingsView.swift"
    s = read(p)
    marker = "                .frame(minHeight: FloeTheme.minimumTarget)\n"
    note = ('                Text("settings.general.language.restart_note")\n'
            '                    .font(.caption)\n'
            '                    .foregroundStyle(.secondary)\n')
    if 'settings.general.language.restart_note' not in s:
        idx = s.find(marker)  # first occurrence belongs to the language picker
        if idx != -1:
            at = idx + len(marker)
            s = s[:at] + note + s[at:]
            write(p, s)
            print("language restart note added")

    # Statistics dimension picker.
    p = "FloeApp/Settings/UsageStatisticsView.swift"
    s = read(p)
    s = s.replace(
        "        case total = \"总览\"\n"
        "        case model = \"模型\"\n"
        "        case provider = \"供应商\"\n"
        "        var id: String { rawValue }",
        "        case total, model, provider\n"
        "        var id: String { rawValue }\n"
        "        var titleKey: LocalizedStringKey {\n"
        "            switch self {\n"
        "            case .total: \"settings.usage_statistics_view.overview\"\n"
        "            case .model: \"providers.models_section\"\n"
        "            case .provider: \"settings.diagnostics.providers\"\n"
        "            }\n"
        "        }")
    s = s.replace("Text(item.rawValue).tag(item)", "Text(item.titleKey).tag(item)")
    write(p, s)

    # Task inspector labels (String parameter -> LocalizedStringKey).
    p = "FloeApp/Chat/ThreadDetailView.swift"
    s = read(p)
    for zh, key in [
        ("变更", "chat.thread_detail_view.changes"),
        ("文件", "tab.files"),
        ("浏览器", "browser.title"),
        ("终端/主机", "chat.thread_detail_view.terminal_host"),
        ("进度", "chat.thread_detail_view.progress"),
        ("子 Agent", "chat.thread_detail_view.subagents"),
    ]:
        s = s.replace(f'inspectorButton("{zh}"', f'inspectorButton("{key}"')
    s = s.replace(
        "        _ title: String,\n"
        "        icon: String,\n"
        "        content: AppRouter.InspectorContent",
        "        _ title: LocalizedStringKey,\n"
        "        icon: String,\n"
        "        content: AppRouter.InspectorContent")
    write(p, s)

    # Heavy-runtime conflict alert composes user-visible counts.
    p = "FloeApp/App/FloeAgentApp.swift"
    s = read(p)
    old = '''        var parts: [String] = []
        if pending.guestCount > 0 { parts.append("\(pending.guestCount) 个 Linux 环境") }
        if pending.serviceCount > 0 { parts.append("\(pending.serviceCount) 个本地服务") }
        let running = parts.isEmpty ? FloeL10n.l("exec.linux.env_title") : parts.joined(separator: "、")
        return "本机正在运行 \(running)。本地模型与 Linux 环境不能同时运行：继续将先停止这些环境（磁盘与数据会保留），或取消本次本地模型请求。"'''
    new = '''        var parts: [String] = []
        if pending.guestCount > 0 {
            parts.append(FloeL10n.l("app.floe_agent_app.linux_environments_count", pending.guestCount))
        }
        if pending.serviceCount > 0 {
            parts.append(FloeL10n.l("app.floe_agent_app.local_services_count", pending.serviceCount))
        }
        let running = parts.isEmpty
            ? FloeL10n.l("exec.linux.env_title")
            : parts.joined(separator: FloeL10n.l("app.floe_agent_app.list_separator"))
        return FloeL10n.l("app.floe_agent_app.local_models_and_linux_environments_cannot",
                          running)'''
    if old in s:
        s = s.replace(old, new)
        write(p, s)
        print("heavy runtime conflict message localized")

    # Settings navigation titles: resolve to String values so an in-session
    # language switch updates the UIKit navigation bar (keyed titles can be
    # cached by the navigation item).
    import glob as _glob
    for path in _glob.glob(os.path.join(ROOT, "FloeApp/Settings/*.swift")):
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        new_src = re.sub(
            r'\.navigationTitle\("([a-z][A-Za-z0-9_]*\.[A-Za-z0-9_.]+)"\)',
            r'.navigationTitle(FloeL10n.l("\1"))', src)
        if new_src != src:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new_src)
            print("nav titles resolved:", os.path.basename(path))

    # Local model foreground-pause error (provider message shown to users).
    p = "Sources/FloeLocalModels/LocalProviderAdapter.swift"
    with open(os.path.join(ROOT, p), encoding="utf-8") as fh:
        s = fh.read()
    import re
    marker = 'providerMessage: "本地模型只能在前台运行'
    if marker in s:
        replacement = ('providerMessage: FloeL10n.l(\n'
                       '                "localmodels.local_provider_adapter.local_models_run_in_the_foreground_only",\n'
                       '                stage,\n'
                       '                Int(max(0, elapsedSeconds)))')
        s = re.sub(
            r'providerMessage: "本地模型只能在前台运行.*?\n"',
            replacement, s, count=1, flags=re.S)
        with open(os.path.join(ROOT, p), "w", encoding="utf-8") as fh:
            fh.write(s)
        print("local provider message fixed")

    # FloeL10n.l("...") in the shortcuts file's LocalizedStringResource helper
    # is expected; nothing to change here once the template is correct.

    print("special surfaces applied")


def fix_lsk_bodies(rel):
    """Replace FloeL10n.l("k") with "k" inside `LocalizedStringKey`-typed
    function/property bodies."""
    import re
    path = os.path.join(ROOT, rel)
    with open(path, encoding="utf-8") as fh:
        s = fh.read()
    changed = False
    # Find declarations of the form `... LocalizedStringKey {` and balance
    # braces from the opening brace to the matching close.
    for m in list(re.finditer(r"(?:->|:)\s*LocalizedStringKey\s*\{", s)):
        start = m.end() - 1  # position of `{`
        depth = 0
        end = None
        for i in range(start, len(s)):
            if s[i] == "{":
                depth += 1
            elif s[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end is None:
            continue
        body = s[start:end]
        new_body = re.sub(r'FloeL10n\.l\("([^"]+)"\)', r'"\1"', body)
        if new_body != body:
            s = s[:start] + new_body + s[end:]
            changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(s)
        print("lsk bodies fixed:", rel)


def read_rel(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


if __name__ == "__main__":
    main()
