// SPDX-License-Identifier: MPL-2.0
//
// ANDROID-PORT-PATCH 1 (G06 foundation lane, 2026-10-29)
//
// Upstream FloeNotes uses `String(localized:defaultValue:)`, which depends on
// the Apple bundle/localization runtime. The Android Foundation overlay does
// not guarantee that initializer, and this module is compiled into
// libFloeAndroidCore.so. This shim resolves the same catalog key through the
// product's single FloeL10n authority and otherwise keeps the exact English
// fallback that upstream passed to `defaultValue:`.
//
// Behaviour on Apple platforms is intentionally irrelevant here: the frozen
// mirror/shared Android package is the only consumer of this patched copy; the
// iOS FloeNotes target keeps the original source unchanged.
import Foundation
import FloeCore

enum NoteLocalization {
    /// Exact EN/zh-Hans templates for the native Notes keys used by this
    /// module. Source of truth: the public catalog at aa1fbe7, as extracted
    /// by Main into main-integration/NOTES_L10N_CATALOG_SUBSET.json (74
    /// still-direct FloeL10n.l call sites), merged with the 20 proposal/
    /// summary templates already migrated here. Catalog lookup wins; this
    /// dictionary is only the Notes-local fallback when the Android bundle
    /// has no FloeCore Localizable table. It is not a parallel translation
    /// source and no FloeCore resource is refreshed.
    private static let catalog: [String: (en: String, zh: String)] = [
        "notes.note_edit.invalid_page_position": (en: "Invalid page position.", zh: "页面位置无效。"),
        "notes.note_edit.the_central_topic_cannot_be_deleted": (en: "The central topic cannot be deleted; rename it or clear its branches.", zh: "不能删除中心主题；可以重命名或清空其分支。"),
        "notes.note_edit.the_target_is_not_a_mind": (en: "The target is not a mind map.", zh: "目标不是思维导图。"),
        "notes.note_export_selection.at_most_pages_can_be_exported": (en: "At most %@ pages can be exported at a time; export in batches.", zh: "一次最多导出 %@ 页，请分批导出。"),
        "notes.note_export_selection.only_note_documents_can_be_exported": (en: "This action only supports notebook pages.", zh: "此操作仅支持手记页面。"),
        "notes.note_export_selection.the_export_page_list_contains_duplicate": (en: "The export page list contains duplicate pages.", zh: "导出页面列表包含重复页面。"),
        "notes.note_models.a_mind_map_can_keep_at": (en: "A mind map can keep at most 2,000 attachments.", zh: "一张导图最多保留 2000 个附件。"),
        "notes.note_models.a_mind_map_can_use_at": (en: "A mind map can use at most 64 distinct images; split the map.", zh: "一张导图最多使用 64 张不同的图片，请拆分导图。"),
        "notes.note_models.a_mind_map_cannot_form_a": (en: "A mind map cannot form a cycle.", zh: "导图不能形成循环。"),
        "notes.note_models.a_mind_map_requires_a_single": (en: "A mind map requires a single central topic.", zh: "导图需要唯一中心主题。"),
        "notes.note_models.a_note_needs_at_least_one": (en: "A note needs at least one page and cannot contain mind map nodes.", zh: "笔记至少需要一页，且不能包含导图节点。"),
        "notes.note_models.a_regular_note_cannot_contain_a": (en: "A regular note cannot contain a mind map layout.", zh: "普通手记不能包含导图布局。"),
        "notes.note_models.each_topic_keeps_at_most_32": (en: "Each topic keeps at most 32 attachments and identifiers cannot repeat.", zh: "每个主题最多保留 32 个附件，且标识不能重复。"),
        "notes.note_models.invalid_mind_map_connection_node": (en: "Invalid mind map connection node.", zh: "导图关联节点无效。"),
        "notes.note_models.invalid_mind_map_connection_position": (en: "Invalid mind map connection position.", zh: "导图关联线位置无效。"),
        "notes.note_models.invalid_mind_map_direction": (en: "Invalid mind map direction.", zh: "导图方向无效。"),
        "notes.note_models.invalid_mind_map_style": (en: "Invalid mind map style.", zh: "导图样式无效。"),
        "notes.note_models.invalid_mind_map_summary_scope": (en: "Invalid mind map summary scope.", zh: "导图概要范围无效。"),
        "notes.note_models.invalid_mind_map_topic_position": (en: "Invalid mind map topic position.", zh: "导图主题位置无效。"),
        "notes.note_models.invalid_page_content_size": (en: "Invalid page content size.", zh: "页面内容尺寸无效。"),
        "notes.note_models.invalid_page_size_or_content_identifier": (en: "Invalid page size or content identifier.", zh: "页面尺寸或内容标识无效。"),
        "notes.note_models.linked_mind_maps_are_duplicated_too": (en: "Linked mind maps are duplicated, too numerous, or have invalid page anchors.", zh: "关联导图重复、数量过多或页面锚点无效。"),
        "notes.note_models.mind_map_links_support_only_web": (en: "Mind map links support only web addresses.", zh: "导图链接只支持网页地址。"),
        "notes.note_models.the_content_was_modified_reload_and": (en: "The content was modified; reload and try again.", zh: "内容已被修改，请重新载入后再试。"),
        "notes.note_models.the_document_contains_duplicate_identifiers": (en: "The document contains duplicate identifiers.", zh: "文档包含重复标识。"),
        "notes.note_models.the_document_version_or_title_is": (en: "The document version or title is invalid.", zh: "文档版本或标题无效。"),
        "notes.note_models.the_engineering_drawing_document_is_missing": (en: "The engineering drawing document is missing a valid file reference, or its format is not supported.", zh: "工程图文档缺少有效的文件引用，或格式不受支持。"),
        "notes.note_models.the_image_is_missing_a_resource": (en: "The image is missing a resource reference.", zh: "图片缺少资源引用。"),
        "notes.note_models.the_material_has_not_been_downloaded": (en: "The material has not been downloaded or is no longer available.", zh: "资料尚未下载或已经不可用。"),
        "notes.note_models.the_mind_map_parent_node_does": (en: "The mind map parent node does not exist.", zh: "导图父节点不存在。"),
        "notes.note_models.the_note_content_does_not_exist": (en: "The note content does not exist.", zh: "手记内容不存在。"),
        "notes.note_models.the_office_document_is_missing_a": (en: "The Office document is missing a valid file reference.", zh: "Office 文档缺少有效的文件引用。"),
        "notes.note_models.the_pdf_page_reference_is_invalid": (en: "The PDF page reference is invalid.", zh: "PDF 页面引用无效。"),
        "notes.note_models.the_topic_attachment_file_name_or": (en: "The topic attachment file name or description is invalid.", zh: "主题附件的文件名或说明无效。"),
        "notes.note_proposals.accepted_proposals_must_be_persisted_through": (en: "Accepted proposals must be persisted through apply.", zh: "接受的提案必须通过 apply 持久化。"),
        "notes.note_proposals.add_to_favorites": (en: "Add to favorites", zh: "加入收藏"),
        "notes.note_proposals.connections_added_changed_deleted": (en: "Connections: %@ added, %@ changed, %@ deleted", zh: "关联线：新增 %@，修改 %@，删除 %@"),
        "notes.note_proposals.mind_map_direction_changed": (en: "Mind map direction changed", zh: "导图方向已修改"),
        "notes.note_proposals.move_to_another_notebook": (en: "Move to another notebook", zh: "移动到其他笔记本"),
        "notes.note_proposals.no_visible_change": (en: "No visible change", zh: "没有可见变化"),
        "notes.note_proposals.page_properties_paper_background_extracted_text": (en: "Page properties (paper/background/extracted text): %@ pages modified", zh: "页面属性（纸张/背景/提取文本）：修改 %@ 页"),
        "notes.note_proposals.pages_added_deleted": (en: "Pages: %@ added, %@ deleted", zh: "页面：新增 %@，删除 %@"),
        "notes.note_proposals.replace_engineering_drawing_resource": (en: "Replace engineering drawing resource", zh: "替换工程图资源"),
        "notes.note_proposals.replace_office_body_resource": (en: "Replace Office body resource", zh: "替换 Office 正文资源"),
        "notes.note_proposals.summary_added_changed_deleted": (en: "Summary: %@ added, %@ changed, %@ deleted", zh: "概要：新增 %@，修改 %@，删除 %@"),
        "notes.note_proposals.tags": (en: "Tags: %@ → %@", zh: "标签：%@ → %@"),
        "notes.note_proposals.text_elements_added_changed_deleted": (en: "Text/elements: %@ added, %@ changed, %@ deleted", zh: "文字/元素：新增 %@，修改 %@，删除 %@"),
        "notes.note_proposals.the_linked_mind_map_was_modified": (en: "The linked mind map was modified", zh: "关联导图已修改"),
        "notes.note_proposals.the_proposal_confirmation_is_no_longer": (en: "The proposal confirmation is no longer valid; confirm again in the editor.", zh: "提案确认已失效，请在编辑器中重新确认。"),
        "notes.note_proposals.the_proposal_contains_no_edits": (en: "The proposal contains no edits.", zh: "提案不包含任何编辑。"),
        "notes.note_proposals.the_proposal_was_rejected_or_expired": (en: "The proposal was rejected or expired and was not applied.", zh: "提案已被拒绝或失效，未应用。"),
        "notes.note_proposals.title": (en: "Title: “%@” → “%@”", zh: "标题：“%@” → “%@”"),
        "notes.note_proposals.topics_added_changed_deleted": (en: "Topics: %@ added, %@ changed, %@ deleted", zh: "主题：新增 %@，修改 %@，删除 %@"),
        "notes.notes_agent_tools.the_target_is_not_an_office": (en: "The target is not an Office document.", zh: "目标不是 Office 文档。"),
        "notes.notes_archive.a_note_resource_exceeds_512_mb": (en: "A note resource exceeds 512 MB.", zh: "单个手记资源超过 512 MB。"),
        "notes.notes_archive.the_archive_contains_duplicate_or_unsupported": (en: "The archive contains duplicate or unsupported entries.", zh: "归档包含重复或不支持的条目。"),
        "notes.notes_archive.the_archive_exceeds_2_gb_when": (en: "The archive exceeds 2 GB when expanded.", zh: "归档展开后超过 2 GB。"),
        "notes.notes_archive.the_archive_manifest_is_missing_or": (en: "The archive manifest is missing or too large.", zh: "归档清单缺失或过大。"),
        "notes.notes_archive.the_archive_manifest_is_too_large": (en: "The archive manifest is too large.", zh: "归档清单过大。"),
        "notes.notes_archive.the_archive_resource_declaration_is_invalid": (en: "The archive resource declaration is invalid.", zh: "归档资源声明无效。"),
        "notes.notes_archive.the_archive_resource_exceeds_its_declared": (en: "The archive resource exceeds its declared length.", zh: "归档资源超过声明长度。"),
        "notes.notes_archive.the_archive_resource_failed_verification": (en: "The archive resource failed verification.", zh: "归档资源校验失败。"),
        "notes.notes_archive.the_export_destination_already_exists": (en: "The export destination already exists.", zh: "导出目标已经存在。"),
        "notes.notes_archive.the_note_archive_exceeds_2_gb": (en: "The note archive exceeds 2 GB; split the export.", zh: "手记归档超过 2 GB，请拆分导出。"),
        "notes.notes_archive.the_note_structure_is_too_large": (en: "The note structure is too large; split the export.", zh: "手记结构过大，请拆分导出。"),
        "notes.notes_archive.the_note_version_or_resource_manifest": (en: "The note version or resource manifest is invalid.", zh: "手记版本或资源清单无效。"),
        "notes.notes_archive.this_archive_contains_linked_mind_maps": (en: "This archive contains linked mind maps; import them from the note material list.", zh: "此归档包含关联导图，请从手记资料列表导入。"),
        "notes.notes_export.no_pages_to_export": (en: "No pages to export.", zh: "没有可导出的页面。"),
        "notes.notes_root_view.remove_from_favorites": (en: "Remove from favorites", zh: "取消收藏"),
        "notes.notes_store.a_single_note_resource_cannot_exceed": (en: "A single note resource cannot exceed 512 MB.", zh: "单个手记资源不能超过 512 MB。"),
        "notes.notes_store.add_the_mind_map_to_link": (en: "Add the mind map to link to this conversation's material scope first.", zh: "请先把要关联的导图加入此对话的资料范围。"),
        "notes.notes_store.enter_a_notebook_name": (en: "Enter a notebook name.", zh: "请输入笔记本名称。"),
        "notes.notes_store.invalid_open_time": (en: "Invalid open time.", zh: "打开时间无效。"),
        "notes.notes_store.invalid_recent_list_count": (en: "Invalid recent-list count.", zh: "最近列表数量无效。"),
        "notes.notes_store.link_new_mind_map": (en: "Link new mind map", zh: "关联新导图"),
        "notes.notes_store.move_the_content_to_trash_first": (en: "Move the content to Trash first.", zh: "请先将内容移到回收站。"),
        "notes.notes_store.no_edits_to_redo": (en: "No edits to redo.", zh: "没有可重做的编辑。"),
        "notes.notes_store.no_edits_to_undo": (en: "No edits to undo.", zh: "没有可撤销的编辑。"),
        "notes.notes_store.only_regular_files_can_be_imported": (en: "Only regular files can be imported.", zh: "只能导入普通文件。"),
        "notes.notes_store.restore_the_content_first": (en: "Restore the content first.", zh: "请先恢复内容。"),
        "notes.notes_store.restore_the_content_from_trash_first": (en: "Restore the content from Trash first.", zh: "请先从回收站恢复内容。"),
        "notes.notes_store.restore_the_material_first": (en: "Restore the material first.", zh: "请先恢复资料。"),
        "notes.notes_store.select_this_document_in_notes_and": (en: "Select this document in Notes and open the assistant first.", zh: "请先在手记中选择此文档并打开助手。"),
        "notes.notes_store.the_edit_batch_is_empty_or": (en: "The edit batch is empty or too large.", zh: "编辑批次为空或过大。"),
        "notes.notes_store.the_import_document_count_or_identifier": (en: "The import document count or identifier is invalid.", zh: "导入文档数量或标识无效。"),
        "notes.notes_store.the_link_target_is_not_a": (en: "The link target is not a usable mind map.", zh: "关联目标不是可用的思维导图。"),
        "notes.notes_store.the_link_target_is_not_a_2": (en: "The link target is not a mind map.", zh: "关联目标不是思维导图。"),
        "notes.notes_store.the_linked_mind_map_was_moved": (en: "The linked mind map was moved to Trash; restore it or unlink it before exporting.", zh: "关联导图已移入回收站；请恢复或解除关联后再导出。"),
        "notes.notes_store.the_notebook_name_is_empty_or": (en: "The notebook name is empty or too long.", zh: "笔记本名称为空或过长。"),
        "notes.notes_store.the_recovery_copy_already_has_newer": (en: "The recovery copy already has newer changes; keep both versions and continue in the copy.", zh: "恢复副本已有新的修改；请保留两个版本，在副本中继续。"),
        "notes.notes_store.the_resource_exceeds_the_import_limit": (en: "The resource exceeds the import limit.", zh: "资源超过导入上限。"),
        "notes.notes_store.the_target_notebook_does_not_exist": (en: "The target notebook does not exist.", zh: "目标笔记本不存在。"),
        "notes.notes_store.this_conversation_is_no_longer_authorized": (en: "This conversation is no longer authorized to modify that material.", zh: "此对话已没有修改该资料的授权。"),
        "notes.notes_store.this_task_has_no_selected_note": (en: "This task has no selected note material.", zh: "此任务没有已选择的手记资料。"),
        "notes.cover.error.invalidBaseline": (en: "The cover baseline is invalid", zh: "封面基线无效"),
        "notes.cover.error.invalidAsset": (en: "This image can't be used as a cover", zh: "此图片无法用作封面"),
        "notes.text.unavailable": (en: "The formatted text could not be read", zh: "无法读取这段排版内容"),
        "notes.text.still_in_use": (en: "This text is still in use", zh: "这段内容仍在使用"),
        "notes.note_models.invalid_cover_version": (en: "The document cover version is invalid", zh: "文档封面版本无效"),
    ]

    static func text(_ key: String, fallback: String) -> String {
        let resolved = FloeL10n.l(key)
        if resolved != key { return resolved }
        if let entry = catalog[key] {
            return FloeL10n.isChinese ? entry.zh : entry.en
        }
        return fallback
    }

    /// Keyed lookup for every remaining native Notes user-facing string. The
    /// catalog wins when present; otherwise the exact merged EN/zh template is
    /// selected by the current product language and the real `%@` arguments are
    /// substituted. An unknown key never becomes user-visible: a generic local
    /// failure sentence is returned instead.
    static func localized(_ key: String, _ arguments: Any...) -> String {
        let resolved = FloeL10n.localized(key: key, arguments: arguments)
        if resolved != key { return resolved }
        if let entry = catalog[key] {
            return substituting(FloeL10n.isChinese ? entry.zh : entry.en, arguments)
        }
        return FloeL10n.isChinese
            ? "手记操作未能完成。"
            : "The Notes action could not be completed."
    }

    /// Localized format with an exact English and Simplified Chinese fallback.
    ///
    /// The Android shared overlay does not bundle the iOS `Localizable`
    /// catalog for FloeNotes, so `FloeL10n.l` legitimately returns the key when
    /// no table is loaded. Human-readable proposal summaries must never expose
    /// that internal key on either platform: catalog values win when present,
    /// otherwise the fallback is selected by the *current* product language and
    /// the same positional `%@` arguments are substituted. This is a Notes-only
    /// fallback; it does not modify the frozen FloeCore tables or ordinary
    /// conversation/localization behavior.
    static func format(_ key: String, english: String, chinese: String,
                       _ arguments: Any...) -> String {
        let resolved = FloeL10n.localized(key: key, arguments: arguments)
        guard resolved == key else { return resolved }
        if let entry = catalog[key] {
            return substituting(FloeL10n.isChinese ? entry.zh : entry.en, arguments)
        }
        let template = FloeL10n.isChinese ? chinese : english
        return substituting(template, arguments)
    }

    /// Replaces `%@` placeholders in order, matching the catalog's format.
    private static func substituting(_ template: String, _ arguments: [Any]) -> String {
        var result = ""
        var iterator = arguments.makeIterator()
        var cursor = template.startIndex
        while let range = template.range(of: "%@", range: cursor..<template.endIndex) {
            result.append(contentsOf: template[cursor..<range.lowerBound])
            if let value = iterator.next() {
                result.append(String(describing: value))
            } else {
                result.append("%@")
            }
            cursor = range.upperBound
        }
        result.append(contentsOf: template[cursor...])
        return result
    }
}
