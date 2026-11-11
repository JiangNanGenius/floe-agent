import Foundation
import SwiftUI
import FloeCore
import FloeTools
import FloePersistence

/// UI qualification only: the real schedule tool, ledger and timer card,
/// with an explicitly synthetic native boundary. Creates no system alarm.
struct InlineTimerQualification: View {
    @State private var fixture: InlineTimerFixture?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("合成计时卡样例 · 非系统闹钟 / Synthetic card · No system alarm")
                    .font(.caption).foregroundStyle(.secondary)
                Text("牛排第一面开始计时，响铃后翻面。")
                if let fixture {
                    InlineTimerCard(source: fixture.source)
                        .environment(\.chatInlineContentScope, .init(conversationID: fixture.taskID, isTemporary: false))
                        .environment(\.systemAlarmController, fixture.service)
                    Button("模拟系统界面暂停") { Task { await fixture.native.pauseAll() } }
                        .accessibilityIdentifier("qualification.inlineTimer.externalPause")
                } else if let failure {
                    Text(failure).accessibilityIdentifier("qualification.inlineTimer.error")
                } else { ProgressView() }
                Text("翻面后的计时会继续出现在这段正文里。")
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            guard fixture == nil else { return }
            do { fixture = try await InlineTimerFixture.make() }
            catch { failure = String(describing: error) }
        }
    }
}

private struct InlineTimerFixture {
    let taskID: UUID
    let source: InlineTimerCardSource
    let service: SystemAlarmService
    let native: InlineTimerFixtureNative

    static func make() async throws -> Self {
        let database = try DatabaseManager.inMemory()
        try await database.writer { db in try SystemAlarmSchema.apply(db) }
        let native = InlineTimerFixtureNative()
        let service = SystemAlarmService(native: native, store: SQLiteSystemAlarmStore(database: database), isForeground: { true })
        let taskID = UUID(), runID = UUID()
        let context = ToolContext(runID: runID, toolCallID: "synthetic-inline-timer",
            toolIdempotencyKey: "synthetic-inline-timer", cancellation: CancellationToken(), conversationID: taskID)
        let output = try await AppleAlarmScheduleTool(service: service, isForeground: { true })
            .execute(.init(kind: "timer", timezone: "UTC", durationSeconds: 180,
                           label: "牛排 · 第一面"), context: context)
        guard let artifact = output.artifacts.first else {
            throw FloeError.validationFailed("Synthetic schedule did not return a timer binding")
        }
        return .init(taskID: taskID, source: .init(artifact: artifact, runID: runID,
            tool: "apple.alarm.schedule"), service: service, native: native)
    }
}

private actor InlineTimerFixtureNative: SystemAlarmNativeManaging {
    nonisolated let isAvailable = true
    var authorization: SystemAlarmAuthorization { .authorized }
    private var snapshots: [UUID: SystemAlarmNativeSnapshot] = [:]
    private var observers: [UUID: AsyncStream<[SystemAlarmNativeSnapshot]>.Continuation] = [:]

    func requestAuthorization() async throws -> SystemAlarmAuthorization { .authorized }
    func alarms() async throws -> [SystemAlarmNativeSnapshot] { Array(snapshots.values) }
    var alarmUpdates: AsyncStream<[SystemAlarmNativeSnapshot]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[SystemAlarmNativeSnapshot]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(Array(snapshots.values))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }
    func schedule(id: UUID, kind: SystemAlarmKind, intendedFireDate: Date?, repeatRule: SystemAlarmRepeat,
                  timerDuration: TimeInterval?, label: String, metadataOwnerReference: String) async throws -> SystemAlarmNativeSnapshot {
        let value = SystemAlarmNativeSnapshot(id: id, state: "countdown", title: label,
            totalDuration: timerDuration, previousElapsed: 0, startDate: Date(),
            fireDate: Date().addingTimeInterval(timerDuration ?? 0))
        snapshots[id] = value
        emit()
        return value
    }
    func cancel(id: UUID) async throws { snapshots.removeValue(forKey: id); emit() }
    func pause(id: UUID) async throws {
        guard var value = snapshots[id] else { throw FloeError.notFound("Synthetic timer") }
        let remaining = max(0, value.fireDate?.timeIntervalSinceNow ?? 0)
        value.previousElapsed = max(0, (value.totalDuration ?? 0) - remaining)
        value.fireDate = nil; value.startDate = nil; value.state = "paused"
        snapshots[id] = value
        emit()
    }
    func resume(id: UUID) async throws {
        guard var value = snapshots[id] else { throw FloeError.notFound("Synthetic timer") }
        value.startDate = Date()
        value.fireDate = Date().addingTimeInterval(max(0, (value.totalDuration ?? 0) - (value.previousElapsed ?? 0)))
        value.state = "countdown"; snapshots[id] = value; emit()
    }
    func pauseAll() async { for id in Array(snapshots.keys) { try? await pause(id: id) } }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func emit() { for observer in observers.values { observer.yield(Array(snapshots.values)) } }
}
