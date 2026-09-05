#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeCore
import FloeTools
@preconcurrency import EventKit
@preconcurrency import MapKit
@preconcurrency import CoreLocation
@preconcurrency import HomeKit
@preconcurrency import WatchConnectivity
import UIKit
import FloeModels
import FloePersistence

private enum AppleToolOutput {
    static func make(_ text: String, exitStatus: Int32 = 0) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }

    static func date(_ value: String?) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let regular = ISO8601DateFormatter()
        guard let date = regular.date(from: value) else {
            throw FloeError.validationFailed("Date must use ISO 8601, for example 2026-08-22T09:00:00+10:00")
        }
        return date
    }

    static func iso(_ date: Date?) -> String {
        guard let date else { return "none" }
        return ISO8601DateFormatter().string(from: date)
    }
}

@MainActor
private func openSystemURL(_ url: URL) async -> Bool {
    await UIApplication.shared.open(url, options: [:])
}

@MainActor
private func openMapItem(_ args: AppleMapsOpenTool.Arguments) -> Bool {
    let item = MKMapItem(
        location: CLLocation(latitude: args.latitude, longitude: args.longitude),
        address: nil
    )
    item.name = args.name
    var options: [String: Any] = [:]
    if let mode = args.directionsMode {
        options[MKLaunchOptionsDirectionsModeKey] = switch mode {
        case "walking": MKLaunchOptionsDirectionsModeWalking
        case "transit": MKLaunchOptionsDirectionsModeTransit
        default: MKLaunchOptionsDirectionsModeDriving
        }
    }
    return item.openInMaps(launchOptions: options)
}

struct AppleCalendarListTool: AgentTool {
    struct Arguments: Decodable, Sendable { var start: String?; var end: String?; var query: String? }
    static let name = "apple.calendar.list"
    static let toolDescription = "List Apple Calendar events in an ISO-8601 date range after system permission. Returns stable event identifiers for later edits."
    static let parametersJSON = #"{"type":"object","properties":{"start":{"type":"string"},"end":{"type":"string"},"query":{"type":"string"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false

    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            return AppleToolOutput.make("status=permissionDenied capability=calendar", exitStatus: 77)
        }
        let start = try AppleToolOutput.date(args.start) ?? Date()
        let end = try AppleToolOutput.date(args.end) ?? start.addingTimeInterval(30 * 24 * 3600)
        guard end > start, end.timeIntervalSince(start) <= 366 * 24 * 3600 else {
            throw FloeError.validationFailed("Calendar range must be positive and no longer than 366 days")
        }
        let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { query?.isEmpty != false || $0.title.lowercased().contains(query ?? "") }
            .prefix(200)
        let lines = events.map {
            "id=\($0.eventIdentifier ?? "unknown") start=\(AppleToolOutput.iso($0.startDate)) end=\(AppleToolOutput.iso($0.endDate)) calendar=\($0.calendar.title) title=\($0.title ?? "")"
        }
        return AppleToolOutput.make("status=ok count=\(lines.count)\n" + lines.joined(separator: "\n"))
    }
}

struct AppleCalendarUpdateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var action: String; var id: String?; var title: String?; var start: String?; var end: String?
        var notes: String?; var location: String?; var isAllDay: Bool?
    }
    static let name = "apple.calendar.update"
    static let toolDescription = "Create, update, or delete an Apple Calendar event. Use an id returned by apple.calendar.list for update/delete."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"id":{"type":"string"},"title":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"},"notes":{"type":"string"},"location":{"type":"string"},"isAllDay":{"type":"boolean"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        guard ["create", "update", "delete"].contains(args.action) else { throw FloeError.validationFailed("Unsupported calendar action") }
        if args.action != "create", args.id?.isEmpty != false { throw FloeError.validationFailed("id is required") }
        if args.action == "create", args.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { throw FloeError.validationFailed("title is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { return AppleToolOutput.make("status=permissionDenied capability=calendar", exitStatus: 77) }
        if args.action == "delete" {
            guard let event = store.event(withIdentifier: args.id!) else { throw FloeError.notFound("calendar event") }
            try store.remove(event, span: .thisEvent, commit: true)
            return AppleToolOutput.make("status=ok action=delete id=\(args.id!)")
        }
        let event: EKEvent
        if args.action == "update" {
            guard let current = store.event(withIdentifier: args.id!) else { throw FloeError.notFound("calendar event") }
            event = current
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = store.defaultCalendarForNewEvents
        }
        if let title = args.title { event.title = title }
        if let start = try AppleToolOutput.date(args.start) { event.startDate = start }
        if let end = try AppleToolOutput.date(args.end) { event.endDate = end }
        if args.action == "create", event.startDate == nil { throw FloeError.validationFailed("start is required") }
        if args.action == "create", event.endDate == nil { event.endDate = event.startDate.addingTimeInterval(3600) }
        if event.endDate < event.startDate { throw FloeError.validationFailed("end must not precede start") }
        if let notes = args.notes { event.notes = notes }
        if let location = args.location { event.location = location }
        if let isAllDay = args.isAllDay { event.isAllDay = isAllDay }
        try store.save(event, span: .thisEvent, commit: true)
        return AppleToolOutput.make("status=ok action=\(args.action) id=\(event.eventIdentifier ?? "unknown")")
    }
}

struct AppleReminderListTool: AgentTool {
    struct Arguments: Decodable, Sendable { var includeCompleted: Bool?; var query: String? }
    static let name = "apple.reminders.list"
    static let toolDescription = "List Apple Reminders after system permission. Returns stable identifiers for completion or edits."
    static let parametersJSON = #"{"type":"object","properties":{"includeCompleted":{"type":"boolean"},"query":{"type":"string"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { return AppleToolOutput.make("status=permissionDenied capability=reminders", exitStatus: 77) }
        let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let includeCompleted = args.includeCompleted ?? false
        let predicate = store.predicateForReminders(in: nil)
        let lines: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let values = (reminders ?? []).filter {
                    (includeCompleted || !$0.isCompleted)
                        && (query?.isEmpty != false || $0.title.lowercased().contains(query ?? ""))
                }.prefix(200).map {
                    let due = $0.dueDateComponents.flatMap(Calendar.current.date(from:))
                    return "id=\($0.calendarItemIdentifier) completed=\($0.isCompleted) due=\(AppleToolOutput.iso(due)) list=\($0.calendar.title) title=\($0.title ?? "")"
                }
                continuation.resume(returning: values)
            }
        }
        return AppleToolOutput.make("status=ok count=\(lines.count)\n" + lines.joined(separator: "\n"))
    }
}

struct AppleReminderUpdateTool: AgentTool {
    struct Arguments: Decodable, Sendable { var action: String; var id: String?; var title: String?; var due: String?; var notes: String?; var completed: Bool? }
    static let name = "apple.reminders.update"
    static let toolDescription = "Create, update, complete, or delete an Apple Reminder. Use an id returned by apple.reminders.list."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"id":{"type":"string"},"title":{"type":"string"},"due":{"type":"string"},"notes":{"type":"string"},"completed":{"type":"boolean"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        guard ["create", "update", "delete"].contains(args.action) else { throw FloeError.validationFailed("Unsupported reminder action") }
        if args.action != "create", args.id?.isEmpty != false { throw FloeError.validationFailed("id is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { return AppleToolOutput.make("status=permissionDenied capability=reminders", exitStatus: 77) }
        if args.action == "delete" {
            guard let item = store.calendarItem(withIdentifier: args.id!) as? EKReminder else { throw FloeError.notFound("reminder") }
            try store.remove(item, commit: true)
            return AppleToolOutput.make("status=ok action=delete id=\(args.id!)")
        }
        let reminder: EKReminder
        if args.action == "update" {
            guard let item = store.calendarItem(withIdentifier: args.id!) as? EKReminder else { throw FloeError.notFound("reminder") }
            reminder = item
        } else {
            reminder = EKReminder(eventStore: store)
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        if let title = args.title { reminder.title = title }
        if args.action == "create", reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FloeError.validationFailed("title is required") }
        if let due = try AppleToolOutput.date(args.due) { reminder.dueDateComponents = Calendar.current.dateComponents(in: .current, from: due) }
        if let notes = args.notes { reminder.notes = notes }
        if let completed = args.completed { reminder.isCompleted = completed; reminder.completionDate = completed ? Date() : nil }
        try store.save(reminder, commit: true)
        return AppleToolOutput.make("status=ok action=\(args.action) id=\(reminder.calendarItemIdentifier)")
    }
}

struct AppleMapsSearchTool: AgentTool {
    struct Arguments: Decodable, Sendable { var query: String; var latitude: Double?; var longitude: Double? }
    static let name = "apple.maps.search"
    static let toolDescription = "Search places with Apple MapKit and return structured names, addresses, and coordinates."
    static let parametersJSON = #"{"type":"object","properties":{"query":{"type":"string"},"latitude":{"type":"number"},"longitude":{"type":"number"}},"required":["query"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws { if args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FloeError.validationFailed("query is required") } }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = args.query
        if let lat = args.latitude, let lon = args.longitude {
            request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        let lines = response.mapItems.prefix(20).map { item in
            let coordinate = item.location.coordinate
            return "name=\(item.name ?? "") address=\(item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? "") latitude=\(coordinate.latitude) longitude=\(coordinate.longitude)"
        }
        return AppleToolOutput.make("status=ok count=\(lines.count)\n" + lines.joined(separator: "\n"))
    }
}

struct AppleMapsOpenTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var name: String?
        var latitude: Double
        var longitude: Double
        var directionsMode: String?
    }
    static let name = "apple.maps.open"
    static let toolDescription = "Open a place or route in Apple Maps. This only presents system UI; the user remains in control."
    static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string"},"latitude":{"type":"number"},"longitude":{"type":"number"},"directionsMode":{"type":"string","enum":["driving","walking","transit"]}},"required":["latitude","longitude"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        guard (-90...90).contains(args.latitude), (-180...180).contains(args.longitude) else {
            throw FloeError.validationFailed("Invalid map coordinates")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let opened = await openMapItem(args)
        return AppleToolOutput.make("status=\(opened ? "presented" : "unavailable") userConfirmationRequired=true")
    }
}

struct AppleMailComposeTool: AgentTool {
    struct Arguments: Decodable, Sendable { var to: [String]?; var cc: [String]?; var subject: String?; var body: String? }
    static let name = "apple.mail.compose"
    static let toolDescription = "Open Apple's mail compose UI with a draft. This tool does not send mail; the user must review and tap Send. For configured generic SMTP accounts, use mail.send after approval."
    static let parametersJSON = #"{"type":"object","properties":{"to":{"type":"array","items":{"type":"string"}},"cc":{"type":"array","items":{"type":"string"}},"subject":{"type":"string"},"body":{"type":"string"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        let all = (args.to ?? []) + (args.cc ?? [])
        guard all.allSatisfy({ $0.count <= 320 && !$0.contains("\n") && !$0.contains("\r") }) else {
            throw FloeError.validationFailed("Invalid mail recipient")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = (args.to ?? []).joined(separator: ",")
        var items: [URLQueryItem] = []
        if let cc = args.cc, !cc.isEmpty { items.append(URLQueryItem(name: "cc", value: cc.joined(separator: ","))) }
        if let subject = args.subject { items.append(URLQueryItem(name: "subject", value: String(subject.prefix(998)))) }
        if let body = args.body { items.append(URLQueryItem(name: "body", value: String(body.prefix(20_000)))) }
        components.queryItems = items
        guard let url = components.url else { throw FloeError.validationFailed("Unable to create mail draft URL") }
        let opened = await openSystemURL(url)
        return AppleToolOutput.make("status=\(opened ? "presented" : "unavailable") sent=false userConfirmationRequired=true")
    }
}

@MainActor
private final class HomeAccessBroker: NSObject {
    static let shared = HomeAccessBroker()
    private let manager = HMHomeManager()
    override init() { super.init(); manager.delegate = self }

    func snapshot() async -> String {
        if manager.homes.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        var lines: [String] = []
        for home in manager.homes {
            for accessory in home.accessories {
                for service in accessory.services {
                    for characteristic in service.characteristics where characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                        lines.append("home=\(home.name) room=\(accessory.room?.name ?? "") accessory=\(accessory.name) accessoryID=\(accessory.uniqueIdentifier.uuidString) service=\(service.name) characteristic=\(characteristic.localizedDescription) characteristicID=\(characteristic.uniqueIdentifier.uuidString) value=\(String(describing: characteristic.value)) writable=\(characteristic.properties.contains(HMCharacteristicPropertyWritable))")
                        if lines.count >= 400 { break }
                    }
                    if lines.count >= 400 { break }
                }
                if lines.count >= 400 { break }
            }
            if lines.count >= 400 { break }
        }
        let status = manager.homes.isEmpty ? "emptyOrUnauthorized" : "ok"
        return "status=\(status) homes=\(manager.homes.count)\n" + lines.joined(separator: "\n")
    }

    func write(accessoryID: String, characteristicID: String, rawValue: String) async throws {
        if manager.homes.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        let characteristic = manager.homes.lazy.flatMap(\.accessories)
            .first(where: { $0.uniqueIdentifier.uuidString == accessoryID })?
            .services.lazy.flatMap(\.characteristics)
            .first(where: { $0.uniqueIdentifier.uuidString == characteristicID })
        guard let characteristic, characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            throw FloeError.notFound("writable HomeKit characteristic")
        }
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Any = if ["true", "on", "yes", "1"].contains(raw.lowercased()) { true }
        else if ["false", "off", "no", "0"].contains(raw.lowercased()) { false }
        else if let number = Double(raw) { number }
        else { raw }
        try await characteristic.writeValue(value)
    }

}

extension HomeAccessBroker: @preconcurrency HMHomeManagerDelegate {
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        // HMHomeManager owns the latest snapshot. Tools read it on demand.
    }
}

struct AppleHomeListTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "apple.home.list"
    static let toolDescription = "List HomeKit homes, rooms, accessories, services, and readable characteristics after system authorization."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return AppleToolOutput.make(await HomeAccessBroker.shared.snapshot())
    }
}

struct AppleHomeControlTool: AgentTool {
    struct Arguments: Decodable, Sendable { var accessoryID: String; var characteristicID: String; var value: String }
    static let name = "apple.home.control"
    static let toolDescription = "Write one explicitly identified writable HomeKit characteristic. List Home first; never guess identifiers."
    static let parametersJSON = #"{"type":"object","properties":{"accessoryID":{"type":"string"},"characteristicID":{"type":"string"},"value":{"type":"string"}},"required":["accessoryID","characteristicID","value"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI, .persistsPersonalData]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.accessoryID) != nil, UUID(uuidString: args.characteristicID) != nil else {
            throw FloeError.validationFailed("Home identifiers must come from apple.home.list")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try await HomeAccessBroker.shared.write(
            accessoryID: args.accessoryID,
            characteristicID: args.characteristicID,
            rawValue: args.value
        )
        return AppleToolOutput.make("status=ok characteristicID=\(args.characteristicID)")
    }
}

@MainActor
private final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    override init() { super.init(); session?.delegate = self; session?.activate() }
    func status() -> String {
        guard let session else { return "supported=false" }
        return "supported=true paired=\(session.isPaired) appInstalled=\(session.isWatchAppInstalled) reachable=\(session.isReachable) state=\(session.activationState.rawValue)"
    }
    func send(title: String, status: String) async throws {
        guard let session, session.isPaired, session.isWatchAppInstalled else { throw FloeError.validationFailed("Floe Watch app is not installed") }
        let payload = ["title": String(title.prefix(200)), "status": String(status.prefix(1_000)), "sentAt": Date().timeIntervalSince1970] as [String: Any]
        if session.isReachable {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.sendMessage(payload, replyHandler: { _ in continuation.resume() }, errorHandler: { continuation.resume(throwing: $0) })
            }
        } else {
            try session.updateApplicationContext(payload)
        }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

struct AppleWatchStatusTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "apple.watch.status"
    static let toolDescription = "Report whether a paired Apple Watch and the Floe Watch companion are available."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        AppleToolOutput.make("status=ok " + (await WatchBridge.shared.status()))
    }
}

struct AppleWatchUpdateTool: AgentTool {
    struct Arguments: Decodable, Sendable { var title: String; var status: String }
    static let name = "apple.watch.update"
    static let toolDescription = "Send a bounded task status update to the paired Floe Watch companion, or queue the latest status when unreachable."
    static let parametersJSON = #"{"type":"object","properties":{"title":{"type":"string"},"status":{"type":"string"}},"required":["title","status"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws { if args.title.isEmpty { throw FloeError.validationFailed("title is required") } }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await WatchBridge.shared.send(title: args.title, status: args.status)
        return AppleToolOutput.make("status=queuedOrDelivered")
    }
}

private struct SendableLocation: Sendable { var latitude: Double; var longitude: Double; var accuracy: Double; var timestamp: Date }

@MainActor
private final class CurrentLocationBroker: NSObject {
    static let shared = CurrentLocationBroker()
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<SendableLocation, Error>?
    private var timeoutTask: Task<Void, Never>?
    override init() { super.init(); manager.delegate = self }

    func current() async throws -> SendableLocation {
        guard continuation == nil else {
            throw FloeError.validationFailed("A location request is already active")
        }
        guard CLLocationManager.locationServicesEnabled() else {
            throw FloeError.validationFailed("Location Services are disabled")
        }
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            throw FloeError.validationFailed("Location permission was denied")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if manager.authorizationStatus == .notDetermined {
                    manager.requestWhenInUseAuthorization()
                }
                manager.requestLocation()
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.finish(throwing: FloeError.syncUnavailable(
                        "Location did not become available within 15 seconds"
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(throwing: FloeError.cancelled)
            }
        }
    }

    private func finish(returning value: SendableLocation) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: value)
    }

    private func finish(throwing error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(throwing: error)
    }
}

extension CurrentLocationBroker: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last else { return }
        finish(returning: SendableLocation(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude, accuracy: value.horizontalAccuracy, timestamp: value.timestamp))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) { finish(throwing: error) }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            finish(throwing: FloeError.validationFailed("Location permission was denied"))
        }
    }
}

struct AppleCurrentLocationTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "apple.location.current"
    static let toolDescription = "Request one current location fix through Core Location. The system owns permission and may deny it."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let value = try await CurrentLocationBroker.shared.current()
        return AppleToolOutput.make("status=ok latitude=\(value.latitude) longitude=\(value.longitude) accuracyMeters=\(value.accuracy) timestamp=\(AppleToolOutput.iso(value.timestamp))")
    }
}

struct AppleAutomationListTool: AgentTool {
    struct Arguments: Decodable, Sendable { var includeDisabled: Bool? }
    static let name = "apple.automation.list"
    static let toolDescription = "List Floe scheduled automations, including the next expected and last actual start times."
    static let parametersJSON = #"{"type":"object","properties":{"includeDisabled":{"type":"boolean"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    let store: SQLiteTaskScheduleStore
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let schedules = try await store.schedules().filter { (args.includeDisabled ?? false) || $0.isEnabled }
        let lines = schedules.prefix(200).map {
            "id=\($0.id.uuidString) enabled=\($0.isEnabled) cadence=\($0.cadence.rawValue) scheduled=\(AppleToolOutput.iso($0.scheduledAt)) next=\(AppleToolOutput.iso($0.nextExpectedAt)) lastStarted=\(AppleToolOutput.iso($0.lastStartedAt)) title=\($0.title)"
        }
        return AppleToolOutput.make("status=ok count=\(lines.count)\n" + lines.joined(separator: "\n"))
    }
}

struct AppleAutomationUpdateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var action: String
        var id: String?
        var title: String?
        var prompt: String?
        var scheduledAt: String?
        var cadence: String?
        var enabled: Bool?
    }
    static let name = "apple.automation.update"
    static let toolDescription = "Create, update, enable/disable, or delete a Floe scheduled automation. iOS scheduling is best effort and does not promise minute-exact execution."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"id":{"type":"string"},"title":{"type":"string"},"prompt":{"type":"string"},"scheduledAt":{"type":"string"},"cadence":{"type":"string","enum":["once","daily","weekly"]},"enabled":{"type":"boolean"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .changesAgentBehavior]
    static let isSideEffecting = true
    let store: SQLiteTaskScheduleStore
    func validate(_ args: Arguments) throws {
        guard ["create", "update", "delete"].contains(args.action) else { throw FloeError.validationFailed("Unsupported automation action") }
        if args.action != "create", args.id.flatMap(UUID.init(uuidString:)) == nil { throw FloeError.validationFailed("A valid id is required") }
        if args.action == "create", args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { throw FloeError.validationFailed("prompt is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        if args.action == "delete" {
            let id = UUID(uuidString: args.id!)!
            try await store.delete(id: id)
            return AppleToolOutput.make("status=ok action=delete id=\(id.uuidString)")
        }
        var record: TaskScheduleRecord
        if args.action == "update" {
            let id = UUID(uuidString: args.id!)!
            guard let current = try await store.schedules().first(where: { $0.id == id }) else { throw FloeError.notFound("automation") }
            record = current
        } else {
            let prompt = args.prompt!.trimmingCharacters(in: .whitespacesAndNewlines)
            let date = try AppleToolOutput.date(args.scheduledAt) ?? Date().addingTimeInterval(300)
            let cadence = args.cadence.flatMap(TaskScheduleCadence.init(rawValue:)) ?? .once
            record = TaskScheduleRecord(
                title: args.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(prompt.prefix(40)),
                prompt: prompt,
                cadence: cadence,
                scheduledAt: date,
                weekday: cadence == .weekly ? Calendar.current.component(.weekday, from: date) : nil,
                isEnabled: args.enabled ?? true
            )
        }
        if let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { record.title = title }
        if let prompt = args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { record.prompt = prompt }
        if let date = try AppleToolOutput.date(args.scheduledAt) { record.scheduledAt = date; record.nextExpectedAt = date }
        if let cadence = args.cadence.flatMap(TaskScheduleCadence.init(rawValue:)) { record.cadence = cadence }
        if let enabled = args.enabled {
            record.isEnabled = enabled
            if enabled {
                record.nextExpectedAt = record.nextExpectedAt ?? record.scheduledAt
            }
        }
        record.weekday = record.cadence == .weekly ? Calendar.current.component(.weekday, from: record.scheduledAt) : nil
        record.updatedAt = Date()
        try await store.save(record)
        if record.isEnabled, let next = record.nextExpectedAt {
            await BackgroundPolicyRegistry.shared.scheduleRefresh(earliest: next)
        }
        return AppleToolOutput.make("status=ok action=\(args.action) id=\(record.id.uuidString) next=\(AppleToolOutput.iso(record.nextExpectedAt)) bestEffort=true")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

func registerAppleSystemTools(database: DatabaseManager, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(AppleCalendarListTool.self); registry.register(AppleCalendarListTool())
    ToolCatalog.register(AppleCalendarUpdateTool.self); registry.register(AppleCalendarUpdateTool())
    ToolCatalog.register(AppleReminderListTool.self); registry.register(AppleReminderListTool())
    ToolCatalog.register(AppleReminderUpdateTool.self); registry.register(AppleReminderUpdateTool())
    ToolCatalog.register(AppleMapsSearchTool.self); registry.register(AppleMapsSearchTool())
    ToolCatalog.register(AppleMapsOpenTool.self); registry.register(AppleMapsOpenTool())
    ToolCatalog.register(AppleMailComposeTool.self); registry.register(AppleMailComposeTool())
    ToolCatalog.register(AppleHomeListTool.self); registry.register(AppleHomeListTool())
    ToolCatalog.register(AppleHomeControlTool.self); registry.register(AppleHomeControlTool())
    ToolCatalog.register(AppleWatchStatusTool.self); registry.register(AppleWatchStatusTool())
    ToolCatalog.register(AppleWatchUpdateTool.self); registry.register(AppleWatchUpdateTool())
    ToolCatalog.register(AppleCurrentLocationTool.self); registry.register(AppleCurrentLocationTool())
    let automationStore = SQLiteTaskScheduleStore(database: database)
    ToolCatalog.register(AppleAutomationListTool.self); registry.register(AppleAutomationListTool(store: automationStore))
    ToolCatalog.register(AppleAutomationUpdateTool.self); registry.register(AppleAutomationUpdateTool(store: automationStore))
}
#endif
