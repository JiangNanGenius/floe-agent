import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxUtilities
@testable import FloeMacToolbox

private enum CalculatorTestFailure: Error { case timeout }

private actor CalculatorWriteGate {
    private var parked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func park() async {
        await withCheckedContinuation { continuation in
            parked = continuation
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilParked() async {
        if parked != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { parked?.resume(); parked = nil }
}

private actor CalculatorFailTwice {
    private var attempts = 0
    func write(_ store: EverydayCalculatorHistoryStore, entry: EverydayCalculatorHistoryEntry) async throws -> [EverydayCalculatorHistoryEntry] {
        attempts += 1
        if attempts <= 2 { throw CalculatorTestFailure.timeout }
        return try await store.add(entry)
    }
}

@MainActor
private func waitForHistory(_ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard clock.now < deadline else { throw CalculatorTestFailure.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Suite("Mac calculator", .serialized)
struct MacCalculatorTests {
    private func root() throws -> URL {
        try MacToolboxTestRoot.unique("calculator")
    }

    private func store(in root: URL) -> EverydayCalculatorHistoryStore {
        EverydayCalculatorHistoryStore(url: root.appendingPathComponent("CalculatorHistory.json"))
    }

    @Test func evaluationPrecedenceFunctionsAndErrorsUseTheExistingCore() {
        #expect(try! EverydayCalculator.evaluate("1+2*3") == 7)
        #expect(try! EverydayCalculator.evaluate("(1+2)*3") == 9)
        #expect(try! EverydayCalculator.evaluate("-2^2") == -4)
        #expect(try! EverydayCalculator.evaluate("2^-2") == 0.25)
        #expect(abs(try! EverydayCalculator.evaluate("sqrt(9)+sin(30)", angleMode: .degrees) - 3.5) < 0.000000001)
        #expect(throws: ToolboxError.self) { try EverydayCalculator.evaluate("1/0") }
        #expect(throws: ToolboxError.self) { try EverydayCalculator.evaluate("sqrt(-1)") }
        #expect(throws: ToolboxError.self) { try EverydayCalculator.evaluate("1+") }
        #expect(throws: ToolboxError.self) { try EverydayCalculator.evaluate("tan(90)", angleMode: .degrees) }
    }

    @Test func modelEvaluatesReusesHistoryAndPersistsAcrossAModelRecreation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let model = MacCalculatorModel(store: store)
        await model.loadHistory()
        model.expression = "12 * (3 + 4)"
        model.evaluate()
        #expect(model.result == 84)
        #expect(model.failure == nil)
        #expect(model.history.count == 1)
        #expect(model.history[0].expression == "12 * (3 + 4)")
        try await waitForHistory { (try? await store.load().count) == 1 }

        model.expression = "1/0"
        model.evaluate()
        #expect(model.result == nil)
        #expect(model.failure == "division by zero")
        #expect(model.history.count == 1)

        let reopened = MacCalculatorModel(store: store)
        await reopened.loadHistory()
        #expect(reopened.history.count == 1)
        #expect(reopened.history[0].result == "84")
        #expect(reopened.historyFailure == nil)

        let reuse = MacCalculatorModel(store: store)
        await reuse.loadHistory()
        reuse.useEntry(reuse.history[0])
        #expect(reuse.result == 84)
        #expect(reuse.history.count == 2)
    }

    @Test func changingAngleModeInvalidatesResultAndHistoryRecalculatesInCurrentMode() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let model = MacCalculatorModel(store: store)
        model.expression = "sin(90)"
        model.evaluate()
        #expect(abs(try #require(model.result) - 1) < 0.000000001)
        let entry = try #require(model.history.first)
        try await waitForHistory { (try? await store.load().count) == 1 }

        model.angleMode = .radians
        #expect(model.result == nil)
        #expect(model.failure == nil)
        model.useEntry(entry)
        #expect(abs(try #require(model.result) - sin(90.0)) < 0.000000001)
        #expect(model.history.count == 2)
        try await waitForHistory { (try? await store.load().count) == 2 }

        model.angleMode = .degrees
        #expect(model.result == nil)
        model.evaluate()
        #expect(abs(try #require(model.result) - 1) < 0.000000001)
        try await waitForHistory { (try? await store.load().count) == 3 }
    }

    @Test func corruptHistoryIsReportedWithoutDisablingCalculation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("{not history".utf8)
        try original.write(to: root.appendingPathComponent("CalculatorHistory.json"))
        let model = MacCalculatorModel(store: store)
        await model.loadHistory()
        #expect(model.historyFailure == "history corrupt")
        model.expression = "2+2"
        model.evaluate()
        #expect(model.result == 4)
        try await waitForHistory { model.historyFailure == "history save" }
        #expect(try Data(contentsOf: root.appendingPathComponent("CalculatorHistory.json")) == original)
    }

    @Test func damagedArchiveCanBePreservedAndPendingCalculationsRecoveredBeforeQuit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("CalculatorHistory.json")
        let original = Data("{damaged history".utf8)
        try original.write(to: file)
        let store = store(in: root)
        let coordinator = MacCalculatorHistoryCoordinator(store: store)
        let model = MacCalculatorModel(historyCoordinator: coordinator)
        await model.loadHistory()
        #expect(model.canRecoverHistory)
        model.expression = "1+1"
        model.evaluate()
        model.expression = "2+2"
        model.evaluate()
        try await waitForHistory { model.historyFailure == "history save" }
        coordinator.closeAdmissions()
        let firstQuit = await coordinator.drain()
        #expect(!firstQuit)
        #expect(try Data(contentsOf: file) == original)
        coordinator.resumeAfterCancelledTermination()
        model.clearHistory() // Clear is unavailable while damaged history needs recovery.
        model.recoverHistory()
        try await waitForHistory { model.historyBackupCreated }
        #expect(!model.canRecoverHistory)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("CalculatorHistory.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
        #expect(try Data(contentsOf: file) == original)
        let saved = try await coordinator.store.load()
        #expect(saved.map(\.expression) == ["2+2", "1+1"])
        let restarted = MacCalculatorHistoryCoordinator(baseURL: file)
        #expect(restarted.ensureOwnership())
        #expect(!restarted.storageUnavailable)
        let reloaded = try await restarted.store.load()
        #expect(reloaded == saved)
        coordinator.closeAdmissions()
        let secondQuit = await coordinator.drain()
        #expect(secondQuit)
    }

    @Test func recoveryRetriesPendingWriteAfterArchiveWasAlreadyBackedUp() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("CalculatorHistory.json")
        let original = Data("{damaged".utf8)
        try original.write(to: file)
        let store = store(in: root)
        let coordinator = MacCalculatorHistoryCoordinator(store: store)
        let failure = CalculatorFailTwice()
        let entry = EverydayCalculatorHistoryEntry(expression: "5+1", result: "6")
        let accepted = coordinator.enqueue({ try await failure.write($0, entry: entry) }, completion: { _ in })
        #expect(accepted)
        var firstFinished = false
        var firstSucceeded = false
        let firstStarted = coordinator.recoverCorruptHistory { result in
            firstFinished = true
            if case .success = result { firstSucceeded = true }
        }
        #expect(firstStarted)
        try await waitForHistory { firstFinished }
        #expect(!firstSucceeded)
        let reopened = MacCalculatorModel(historyCoordinator: coordinator)
        await reopened.loadHistory()
        #expect(reopened.canRecoverHistory)
        #expect(reopened.historyFailure == "history recovery")
        reopened.recoverHistory()
        try await waitForHistory { reopened.historyBackupCreated }
        #expect(!reopened.canRecoverHistory)
        #expect(try Data(contentsOf: file) == original)
        let saved = try await coordinator.store.load()
        #expect(saved == [entry])
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("CalculatorHistory.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
    }

    @Test func reopenedModelRefreshesWhenSharedRecoveryCompletes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("CalculatorHistory.json")
        let original = Data("{damaged before switch".utf8)
        try original.write(to: file)
        let store = store(in: root)
        let gate = CalculatorWriteGate()
        let coordinator = MacCalculatorHistoryCoordinator(store: store, recoveryCreator: { original, base in
            await gate.park()
            return try MacCalculatorHistoryCoordinator.makeRecoveryArchive(original: original, base: base)
        })
        var old: MacCalculatorModel? = MacCalculatorModel(historyCoordinator: coordinator)
        await old?.loadHistory()
        old?.expression = "6+1"
        old?.evaluate()
        try await waitForHistory { old?.historyFailure == "history save" }
        old?.recoverHistory()
        await gate.waitUntilParked()
        let reopened = MacCalculatorModel(historyCoordinator: coordinator)
        await reopened.loadHistory()
        #expect(reopened.canRecoverHistory)
        #expect(reopened.recoveringHistory)
        old = nil
        await gate.release()
        try await waitForHistory {
            !reopened.canRecoverHistory && !reopened.recoveringHistory && reopened.historyFailure == nil
        }
        #expect(reopened.history.map(\.expression) == ["6+1"])
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func secondHostCannotWriteWhileHistoryOwnerIsAlive() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("CalculatorHistory.json")
        var owner: MacCalculatorHistoryCoordinator? = MacCalculatorHistoryCoordinator(baseURL: file)
        let second = MacCalculatorHistoryCoordinator(baseURL: file)
        #expect(owner?.ensureOwnership() == true)
        #expect(!second.ensureOwnership())
        #expect(owner?.storageUnavailable == false)
        #expect(second.storageUnavailable)
        let accepted = second.enqueue({ _ in [] }, completion: { _ in })
        #expect(!accepted)
        let model = MacCalculatorModel(historyCoordinator: second)
        await model.loadHistory()
        #expect(model.historyFailure == "history ownership")
        owner = nil
        await model.retryHistoryOwnership()
        #expect(!second.storageUnavailable)
        #expect(model.historyFailure == nil)
    }

    @Test func lockIsVisibleToAnotherProcess() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("CalculatorHistory.json")
        let owner = MacCalculatorHistoryCoordinator(baseURL: file)
        #expect(owner.ensureOwnership())
        #expect(!owner.storageUnavailable)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys\nf=open(sys.argv[1], 'r+')\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError:\n sys.exit(73)\nsys.exit(0)", file.path + ".lock"]
        try child.run()
        child.waitUntilExit()
        #expect(child.terminationStatus == 73)
        withExtendedLifetime(owner) {}
    }

    @Test func invalidRecoveryPointerFailsClosedWithoutTouchingOriginal() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("CalculatorHistory.json")
        let original = Data("{damaged".utf8)
        try original.write(to: file)
        let marker = root.appendingPathComponent("CalculatorHistory.json.recovered.active")
        try Data("{partial".utf8).write(to: marker)
        let coordinator = MacCalculatorHistoryCoordinator(baseURL: file)
        #expect(!coordinator.ensureOwnership())
        #expect(coordinator.storageUnavailable)
        let accepted = coordinator.enqueue({ _ in [] }, completion: { _ in })
        #expect(!accepted)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func repeatedRecoveryPreservesEveryArchiveAndRestartFollowsChain() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("CalculatorHistory.json")
        let firstDamage = Data("{first damaged archive".utf8)
        let secondDamage = Data("{second damaged archive".utf8)
        try firstDamage.write(to: file)
        var earlierRecovered: URL?
        do {
            let coordinator = MacCalculatorHistoryCoordinator(baseURL: file)
            let model = MacCalculatorModel(historyCoordinator: coordinator)
            await model.loadHistory()
            model.recoverHistory()
            try await waitForHistory { model.historyBackupCreated }
            earlierRecovered = await coordinator.store.url
            try secondDamage.write(to: #require(earlierRecovered))
            await model.loadHistory()
            #expect(model.canRecoverHistory)
            model.expression = "8+1"
            model.evaluate()
            try await waitForHistory { model.historyFailure == "history save" }
            model.recoverHistory()
            try await waitForHistory { !model.canRecoverHistory && !model.recoveringHistory }
            #expect(try Data(contentsOf: file) == firstDamage)
            #expect(try Data(contentsOf: #require(earlierRecovered)) == secondDamage)
        }
        let restarted = MacCalculatorHistoryCoordinator(baseURL: file)
        #expect(restarted.ensureOwnership())
        #expect(!restarted.storageUnavailable)
        let restored = try await restarted.store.load()
        #expect(restored.map(\.expression) == ["8+1"])
    }

    @Test func clearHistoryRemovesTheArchive() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let model = MacCalculatorModel(store: store)
        await model.loadHistory()
        model.expression = "5+5"
        model.evaluate()
        try await waitForHistory { (try? await store.load().count) == 1 }
        model.clearHistory()
        try await waitForHistory { (try? await store.load())?.isEmpty == true }
        #expect(model.history.isEmpty)
    }

    @Test func terminationClosesAdmissionsAndWaitsForOwnedWrite() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let coordinator = MacCalculatorHistoryCoordinator(store: store)
        let gate = CalculatorWriteGate()
        let entry = EverydayCalculatorHistoryEntry(expression: "1+1", result: "2")
        let accepted = coordinator.enqueue({ store in
            await gate.park()
            return try await store.add(entry)
        }, completion: { _ in })
        #expect(accepted)
        await gate.waitUntilParked()
        coordinator.closeAdmissions()
        let acceptedWhileClosing = coordinator.enqueue({ _ in [] }, completion: { _ in })
        #expect(!acceptedWhileClosing)
        var drainFinished = false
        let drain = Task { let result = await coordinator.drain(); drainFinished = true; return result }
        await Task.yield()
        #expect(!drainFinished)
        await gate.release()
        let drained = await drain.value
        #expect(drained)
        let saved = try await store.load()
        #expect(saved == [entry])
    }

    @Test func failedWriteRejectsTerminationUntilCancelledAndRetried() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let coordinator = MacCalculatorHistoryCoordinator(store: store)
        let failTwice = CalculatorFailTwice()
        let entry = EverydayCalculatorHistoryEntry(expression: "3+1", result: "4")
        let accepted = coordinator.enqueue({ try await failTwice.write($0, entry: entry) }, completion: { _ in })
        #expect(accepted)
        coordinator.closeAdmissions()
        let failedDrain = await coordinator.drain()
        #expect(!failedDrain)
        let initiallySaved = try await store.load()
        #expect(initiallySaved.isEmpty)
        coordinator.resumeAfterCancelledTermination()
        coordinator.closeAdmissions()
        let retriedDrain = await coordinator.drain()
        #expect(retriedDrain)
        let saved = try await store.load()
        #expect(saved == [entry])
    }

    @Test func unitConversionMatchesTheExistingCore() throws {
        let length = EverydayUnitConverter.units(for: .length)
        let metres = try #require(length.first { $0.id == "m" })
        let feet = try #require(length.first { $0.id == "ft" })
        let converted = try EverydayUnitConverter.convert(1, from: metres, to: feet)
        #expect(abs(converted - 3.280839895) < 0.000001)

        let temperatures = EverydayUnitConverter.units(for: .temperature)
        let celsius = try #require(temperatures.first { $0.id == "c" })
        let kelvin = try #require(temperatures.first { $0.id == "k" })
        #expect(abs(try EverydayUnitConverter.convert(0, from: celsius, to: kelvin) - 273.15) < 0.000001)
        #expect(throws: ToolboxError.self) {
            try EverydayUnitConverter.convert(-274, from: celsius, to: kelvin)
        }
    }
}
