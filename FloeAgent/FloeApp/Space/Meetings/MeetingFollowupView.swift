// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(EventKit)
import SwiftUI
import FloeMeetings

struct MeetingFollowupView: View {
    let session: MeetingProjectSession
    let todo: TodoItem
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String
    @State private var hasDue = false
    @State private var due = Date().addingTimeInterval(3600)
    @State private var confirmingRetry = false

    init(session: MeetingProjectSession, todo: TodoItem) {
        self.session = session; self.todo = todo
        _title = State(initialValue: todo.text)
        let source = session.sourceDescription(todo.source)
        _notes = State(initialValue: session.meeting.title + (source.map { "\n" + $0 } ?? ""))
    }
    private var center: MeetingFollowupCenter? { session.followups }
    private var phase: MeetingFollowupCenter.Phase? { center?.records[todo.id.rawValue]?.phase }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(t("提醒事项标题", "Reminder title"), text: $title, axis: .vertical)
                    TextField(t("备注与来源", "Notes and source"), text: $notes, axis: .vertical)
                    Toggle(t("设置提醒时间", "Set a reminder time"), isOn: $hasDue)
                    if hasDue { DatePicker(t("时间", "Time"), selection: $due, displayedComponents: [.date, .hourAndMinute]) }
                }.disabled(center?.isCreating == true || phase == .saved || phase == .unconfirmed)
                Section {
                    if center?.isCreating == true {
                        ProgressView(t("正在创建", "Creating"))
                    } else if phase == .saved {
                        Label(t("已加入提醒事项", "Added to Reminders"), systemImage: "checkmark.circle")
                    } else if phase == .unconfirmed {
                        Text(t("上次创建结果未确认，请先在提醒事项中检查。", "The previous creation is unconfirmed. Check Reminders first."))
                        Button(t("已检查，未创建", "Checked: no reminder exists")) { confirmingRetry = true }
                    } else {
                        Button(t("创建提醒事项", "Create reminder"), systemImage: "bell.badge") {
                            center?.create(todo: todo, title: title, notes: notes, due: hasDue ? due : nil)
                        }.disabled(center == nil || center?.isCreating == true || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text(t("确认后写入默认提醒列表。", "Creates the reminder in your default list when you confirm."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let failure = center?.diagnostic ?? (center == nil ? session.diagnostic : nil) {
                        DisclosureGroup(t("操作未完成，查看详情", "Unable to finish. View details")) {
                            Text(failure).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(t("跟进事项", "Follow-up"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("取消", "Cancel")) { Task { await center?.cancelAndWait(); dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("完成", "Done")) { dismiss() }.disabled(center?.isCreating == true)
                }
            }
            .confirmationDialog(t("确认提醒事项中没有这项？", "Confirm that this reminder does not exist?"), isPresented: $confirmingRetry) {
                Button(t("允许重新创建", "Allow another attempt")) { center?.resetUnconfirmed(todo.id.rawValue) }
            }
        }
        .interactiveDismissDisabled(center?.isCreating == true)
        .accessibilityIdentifier("meeting.followup")
    }
    private func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
}
#endif
