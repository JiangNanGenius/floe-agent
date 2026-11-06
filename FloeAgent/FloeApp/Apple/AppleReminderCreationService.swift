// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(EventKit)
import Foundation
@preconcurrency import EventKit

struct AppleReminderCreationRequest: Sendable {
    let title: String
    let notes: String?
    let due: Date?
    var completed = false
    var addAlarm = false
}
struct AppleReminderCreationReceipt: Sendable { let identifier: String }
enum AppleReminderCreationError: LocalizedError, Sendable {
    case capabilityDisabled, permissionDenied, invalidContent, noWritableList, unconfirmed
    var errorDescription: String? {
        switch self {
        case .capabilityDisabled: IDELanguageRunText.t("请先在 Apple 功能设置中打开提醒事项。", "Enable Reminders in Apple capabilities first.")
        case .permissionDenied: IDELanguageRunText.t("未获得提醒事项访问权限。", "Reminders access was not granted.")
        case .invalidContent: IDELanguageRunText.t("请检查提醒事项的标题、文字和时间。", "Check the reminder title, text and time.")
        case .noWritableList: IDELanguageRunText.t("提醒事项中没有可写的默认列表。", "No writable default Reminders list is available.")
        case .unconfirmed: IDELanguageRunText.t("未能确认创建结果，请先检查提醒事项。", "Creation could not be confirmed. Check Reminders first.")
        }
    }
}

/// Shared by the existing authorized Apple tool and the user's explicit
/// meeting confirmation. The caller's tool/intent permission remains its own.
@MainActor enum AppleReminderCreationService {
    static func create(_ request: AppleReminderCreationRequest,
        beforeCommit: (@MainActor @Sendable () throws -> Void)? = nil) async throws -> AppleReminderCreationReceipt {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 8_192, (request.notes?.utf8.count ?? 0) <= 128_000,
              request.due?.timeIntervalSince1970.isFinite != false else { throw AppleReminderCreationError.invalidContent }
        guard AppleCapabilityPreferences.isEnabled(.reminders) else { throw AppleReminderCreationError.capabilityDisabled }
        try Task.checkCancellation()
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw AppleReminderCreationError.permissionDenied }
        try Task.checkCancellation()
        guard AppleCapabilityPreferences.isEnabled(.reminders) else { throw AppleReminderCreationError.capabilityDisabled }
        guard let calendar = store.defaultCalendarForNewReminders(), calendar.allowsContentModifications else {
            throw AppleReminderCreationError.noWritableList
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar; reminder.title = title; reminder.notes = request.notes
        if let due = request.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(in: .current, from: due)
            if request.addAlarm { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        reminder.isCompleted = request.completed
        reminder.completionDate = request.completed ? Date() : nil
        try beforeCommit?()
        try Task.checkCancellation()
        try store.save(reminder, commit: true)
        let identifier = reminder.calendarItemIdentifier
        guard !identifier.isEmpty, let saved = store.calendarItem(withIdentifier: identifier) as? EKReminder,
              saved.title == title, saved.calendar.calendarIdentifier == calendar.calendarIdentifier else {
            throw AppleReminderCreationError.unconfirmed
        }
        return .init(identifier: identifier)
    }
}

#endif
