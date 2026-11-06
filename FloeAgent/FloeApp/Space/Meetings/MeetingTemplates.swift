// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeMeetings

enum MeetingMinutesTemplate: String, CaseIterable, Identifiable, Sendable {
    case general, project, lecture, interview
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: IDELanguageRunText.t("通用会议", "General meeting")
        case .project: IDELanguageRunText.t("项目讨论", "Project discussion")
        case .lecture: IDELanguageRunText.t("课堂与讲座", "Class and lecture")
        case .interview: IDELanguageRunText.t("访谈", "Interview")
        }
    }
    var sections: [String] {
        switch self {
        case .general: [t("摘要", "Summary"), t("讨论要点", "Discussion"), t("已确认结论", "Decisions"), t("待确认问题", "Open questions"), t("跟进事项", "Follow-ups")]
        case .project: [t("目标与进展", "Goals and progress"), t("方案与取舍", "Options and tradeoffs"), t("决策", "Decisions"), t("风险与阻碍", "Risks and blockers"), t("负责人和下一步", "Owners and next steps")]
        case .lecture: [t("主题与学习目标", "Topic and learning goals"), t("概念与定义", "Concepts and definitions"), t("例子与论证", "Examples and reasoning"), t("疑问与复习重点", "Questions and revision"), t("作业与阅读", "Assignments and reading")]
        case .interview: [t("访谈主题", "Interview topic"), t("问题与回答", "Questions and answers"), t("核心观点与引语", "Insights and quotations"), t("分歧与待核实内容", "Disagreements and verification"), t("后续问题", "Follow-up questions")]
        }
    }
    var instruction: String {
        let structure: String
        switch self {
        case .general:
            structure = "Use sections: Summary; Discussion; Confirmed decisions; Open questions; Proposed follow-ups. Distinguish discussion from agreement."
        case .project:
            structure = "Use sections: Goals and progress; Options and tradeoffs; Decisions; Risks and blockers; Owners and next steps. Keep rejected options and their stated reasons separate from selected options."
        case .lecture:
            structure = "Use sections: Topic and learning goals; Concepts and definitions; Examples and reasoning; Questions and revision; Assignments and reading. Separate a speaker's claims from established facts. Do not manufacture homework, references or exam requirements."
        case .interview:
            structure = "Use sections: Interview topic; Questions and answers; Insights and quotations; Disagreements and verification; Follow-up questions. Preserve question-answer attribution. Quote only words present in the transcript; label paraphrases."
        }
        return structure + " Cite the supplied source labels and times. State when evidence for a section is absent. Name owners, deadlines and commitments only when explicitly stated. Proposed follow-ups remain proposals and never authorize creating reminders, calendar items or editing personal notes."
    }
    var outline: String { (["# " + title] + sections.map { "\n## " + $0 + "\n" }).joined(separator: "\n") }
    private func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
}

extension MeetingProjectSession {
    var minutesTemplate: MeetingMinutesTemplate { MeetingMinutesTemplate(rawValue: intelligence.template) ?? .general }
    func selectTemplate(_ template: MeetingMinutesTemplate) { updateIntelligence { $0.template = template.rawValue } }
    func insertTemplateOutline() async {
        do { try await appendToNotebook(minutesTemplate.outline) }
        catch { diagnostic = error.localizedDescription }
    }
    func rememberSummarySources(_ summary: SummaryRecord, segments: [TranscriptSegment]) {
        let previous = intelligence.summarySourceIDs
        var sources = previous ?? [:]
        sources[summary.id.rawValue] = segments.map { $0.id.rawValue }
        intelligence.summarySourceIDs = sources
        do { try saveIntelligence() }
        catch { intelligence.summarySourceIDs = previous; diagnostic = error.localizedDescription }
    }
}
#endif
