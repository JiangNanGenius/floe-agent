// Floe Mac M00 — reproducible mode, role, Bridge and Catalyst checks.
//
// SPDX-License-Identifier: MPL-2.0

import AppKit
import CryptoKit
import Darwin
import Foundation
import FloeMacBridgeProtocol
import SwiftUI

enum HostProbe {
    static func emit(_ payload: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("{\"error\":\"json encoding failed\"}")
        }
    }

    static func printMode(store: ModePreferenceStore, modeOverride: AppMode?) -> Int32 {
        let resolved = store.resolve(commandLineMode: modeOverride)
        let exists = FileManager.default.fileExists(atPath: resolved.preferenceURL.path)
        emit([
            "schema": "floe-mac-mode-v1",
            "mode": resolved.mode.rawValue,
            "modeDisplayName": resolved.mode.displayName,
            "source": resolved.source.rawValue,
            "isFirstRun": resolved.isFirstRun,
            "preferencePath": resolved.preferenceURL.path,
            "preferenceExists": exists,
            "roleTitle": resolved.mode.displayName
        ])
        return 0
    }

    static func setMode(store: ModePreferenceStore, mode: AppMode) -> Int32 {
        do {
            try store.save(mode)
        } catch {
            emit([
                "schema": "floe-mac-mode-v1",
                "saved": false,
                "error": error.localizedDescription,
                "preferencePath": store.preferenceURL.path
            ])
            return 2
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: store.preferenceURL.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let resolved = store.resolve(commandLineMode: nil)
        emit([
            "schema": "floe-mac-mode-v1",
            "saved": true,
            "mode": resolved.mode.rawValue,
            "source": resolved.source.rawValue,
            "isFirstRun": resolved.isFirstRun,
            "preferencePath": resolved.preferenceURL.path,
            "preferenceExists": true,
            "preferencePermissionsOctal": String(permissions, radix: 8)
        ])
        return 0
    }

    @MainActor
    static func printAutoApproval() async -> Int32 {
        let provider = ReservedAutoApprovalProvider()
        let status = await provider.status()
        let statusText: String
        switch status {
        case .reserved: statusText = "reserved"
        case .connected: statusText = "connected"
        case .unavailable: statusText = "unavailable"
        }
        emit([
            "schema": "floe-mac-auto-approval-v1",
            "owner": "Floe",
            "agentCore": AppMode.confirmedAgentCore,
            "integrated": false,
            "provider": "ReservedAutoApprovalProvider",
            "status": statusText,
            "source": "Floe task scope + existing permission settings",
            "bridgeUsesPolicy": false,
            "configuredInM00": false,
            "scopeOptions": TaskApprovalScope.allCases.map(\.rawValue),
            "riskClasses": TaskRiskClass.allCases.map(\.rawValue),
            "note": "M00 reserves the integration point; Floe's runtime and approval policy are not yet connected."
        ])
        return 0
    }

    @MainActor
    static func selfTest(
        store: ModePreferenceStore,
        modeOverride: AppMode?
    ) -> Int32 {
        let resolved = store.resolve(commandLineMode: modeOverride)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: Text("Floe Mac M00 role self-test")
                .font(.title2)
                .padding(40)
        )
        window.center()
        let snapshot = RolePresentation.apply(resolved.mode, window: window)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let visible = window.isVisible
        let title = window.title
        let subtitle = window.subtitle
        window.orderOut(nil)
        window.close()

        let payload: [String: Any] = [
            "schema": "floe-mac-role-selftest-v1",
            "mode": resolved.mode.rawValue,
            "modeSource": resolved.source.rawValue,
            "isFirstRun": resolved.isFirstRun,
            "windowCreated": true,
            "windowVisible": visible,
            "windowTitle": title,
            "windowSubtitle": subtitle,
            "expectedTitle": resolved.mode.displayName,
            "iconResource": snapshot.iconResource,
            "iconLoaded": snapshot.iconLoaded,
            "iconPixelSize": snapshot.iconPixelSize ?? "unknown",
            "applicationIconSet": snapshot.applicationIconSet,
            "bundlePath": Bundle.main.bundleURL.path,
            "preferencePath": store.preferenceURL.path,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]
        emit(payload)
        let passed = visible && title == resolved.mode.displayName && snapshot.iconLoaded && snapshot.applicationIconSet
        return passed ? 0 : 1
    }

    @MainActor
    static func probeBridge(store: ModePreferenceStore, arguments: HostArguments) async -> Int32 {
        let probeRoot = arguments.dataRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-mac-m00-bridge-\(UUID().uuidString)", isDirectory: true)
        let fixture = probeRoot.appendingPathComponent("Fixture", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let before = UserBridgeGuard.capture()
        do {
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        } catch {
            emit(["schema": "floe-mac-bridge-probe-v2", "passed": false,
                  "error": "Could not create probe root: \(error.localizedDescription)"])
            return 1
        }
        if LoopbackProbe.isListening(port: BridgeWire.port) {
            let endpoint = BridgeEndpointInspector.inspect()
            emit([
                "schema": "floe-mac-bridge-probe-v2",
                "passed": false,
                "blockedByExistingListener": true,
                "port": Int(BridgeWire.port),
                "endpoint": endpointDictionary(endpoint),
                "note": "An existing loopback listener was found. It was not started, stopped or modified."
            ])
            return 3
        }

        let controller = BridgeComponentController(
            dataRoot: fixture.appendingPathComponent("Control", isDirectory: true),
            helperOverride: arguments.bridgeServicePath,
            testFixture: fixture
        )
        let helper = controller.locateHelper()
        let helperInsideBundle = helper?.path.hasPrefix(Bundle.main.bundleURL.path) ?? false
        controller.start(origin: .agent)
        guard let ready = await waitForReady(controller: controller, timeout: 20) else {
            emit([
                "schema": "floe-mac-bridge-probe-v2",
                "passed": false,
                "state": stateText(controller.state),
                "helperPath": helper?.path ?? "missing",
                "helperInsideHostBundle": helperInsideBundle,
                "logTail": controller.readLogTail(),
                "endpoint": endpointDictionary(BridgeEndpointInspector.inspect())
            ])
            controller.detachForTermination()
            return 1
        }
        let servicePID = ready.pid
        let helperParentMatches = ready.parentPID == getpid()
        let storageRoot = ready.storageRoot
        let workerHome = ready.workerHome
        let identitySource = ready.identitySource
        let identityFingerprint = ready.identityFingerprintSHA256 ?? "none"

        await controller.performPing()
        let pingText = controller.lastPing ?? ""
        let pingOK = pingText.contains("Signed RPC ping OK") && pingText.contains("pinned identity")

        controller.start(origin: .bridge)
        let pidAfterBridgeEntry = controller.state.status?.pid
        let originAfterBridgeEntry = controller.launchOrigin?.rawValue ?? "none"
        controller.start(origin: .agent)
        let pidAfterAgentEntry = controller.state.status?.pid
        let originAfterAgentEntry = controller.launchOrigin?.rawValue ?? "none"
        let sameService = servicePID == pidAfterBridgeEntry
            && servicePID == pidAfterAgentEntry
            && helperProcessCount(path: helper?.path) == 1

        let httpStatus = LoopbackProbe.httpStatusLine(
            port: BridgeWire.port,
            request: "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(BridgeWire.port)\r\n\r\n"
        )

        let jobID = UUID().uuidString
        let workspaceID = "m00workspace"
        var taskActiveDuringRun = false
        var stopBlockedDuringRun = false
        var helperAliveDuringRun = false
        var taskOutput = ""
        var taskCompleted = false
        var taskError: String?
        do {
            let command = "printf 'HOME=%s\\n' \"$HOME\"; printf 'SERVICE=%s\\n' \"$FLOE_M00_SERVICE_ROOT\"; printf 'fixture-file' > m00-probe.txt; wc -c < m00-probe.txt; sleep 2; printf 'DONE\\n'"
            _ = try await signedRPC(
                controller: controller,
                pinnedKey: try pinnedKey(from: controller),
                method: "start",
                payload: [
                    "workspaceID": .string(workspaceID),
                    "jobID": .string(jobID),
                    "command": .string(command),
                    "environment": .object(["FLOE_M00_SERVICE_ROOT": .string(storageRoot)]),
                    "columns": .integer(100),
                    "rows": .integer(30)
                ]
            )
            try? await Task.sleep(for: .milliseconds(250))
            await controller.refreshStatus()
            if let live = controller.state.status {
                taskActiveDuringRun = live.activeTaskIDs.contains(jobID)
            }
            await controller.requestStop()
            stopBlockedDuringRun = controller.stopBlockMessage != nil && controller.state.isRunning
            helperAliveDuringRun = helper.map { helperProcessCount(path: $0.path) > 0 } ?? false

            var offset: Int64 = 0
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                let polled = try await signedRPC(
                    controller: controller,
                    pinnedKey: try pinnedKey(from: controller),
                    method: "poll",
                    payload: [
                        "jobID": .string(jobID),
                        "offset": .integer(offset),
                        "limit": .integer(64 * 1024)
                    ]
                )
                if let encoded = polled["data"]?.string, let data = Data(base64Encoded: encoded) {
                    taskOutput += String(decoding: data, as: UTF8.self)
                }
                offset = polled["offset"]?.integer ?? offset
                if polled["alive"]?.bool == false {
                    taskCompleted = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            taskError = error.localizedDescription
        }

        var fileReadOK = false
        var fileReadDetail = ""
        do {
            let fileResult = try await signedRPC(
                controller: controller,
                pinnedKey: try pinnedKey(from: controller),
                method: "file.read",
                payload: [
                    "workspaceID": .string(workspaceID),
                    "path": .string("m00-probe.txt"),
                    "offset": .integer(0),
                    "limit": .integer(1024)
                ]
            )
            if let encoded = fileResult["data"]?.string, let data = Data(base64Encoded: encoded) {
                fileReadDetail = String(decoding: data, as: UTF8.self)
                fileReadOK = fileReadDetail == "fixture-file"
            }
        } catch {
            fileReadDetail = "error: \(error.localizedDescription)"
        }

        await controller.refreshStatus()
        let activeAfterTask = controller.state.status?.activeTaskIDs ?? []
        let unknownAfterTask = controller.state.status?.unknownTaskIDs ?? []

        var consentPassed = false
        var consentDetail: [String: Any] = [:]
        do {
            consentDetail = try await exerciseConsentFlow(
                controller: controller,
                pinnedKey: try pinnedKey(from: controller)
            )
            consentPassed = consentDetail["passed"] as? Bool ?? false
        } catch {
            consentDetail = ["passed": false, "error": error.localizedDescription]
        }

        await controller.stopAndWait(reason: "probe complete")
        let portClosed = !LoopbackProbe.isListening(port: BridgeWire.port)
        let processCountAfterStop = helperProcessCount(path: helper?.path)
        let pidStillAlive = kill(servicePID, 0) == 0

        var rapidCycles = 0
        var rapidFailure: String?
        for _ in 0..<2 {
            controller.start(origin: .bridge)
            if await waitForReady(controller: controller, timeout: 20) == nil {
                rapidFailure = "restart did not become ready: \(stateText(controller.state))"
                break
            }
            await controller.stopAndWait(reason: "rapid cycle")
            if !matchesIdle(controller.state) {
                rapidFailure = "restart #\(rapidCycles + 1) did not return to idle: \(stateText(controller.state))"
                break
            }
            rapidCycles += 1
        }
        let rapidFinalIdle = matchesIdle(controller.state) && !LoopbackProbe.isListening(port: BridgeWire.port)
        let userBridgeAfter = UserBridgeGuard.capture()
        let isolated = storageRoot.hasPrefix(fixture.appendingPathComponent("service-home").path + "/")
            && storageRoot != UserBridgeGuard.userBridgeRoot.path
            && !storageRoot.hasPrefix(UserBridgeGuard.userBridgeRoot.path + "/")
        let expectedWorkerHome = fixture.appendingPathComponent("worker-home").path
        let workerSeparate = URL(fileURLWithPath: workerHome).resolvingSymlinksInPath().path == expectedWorkerHome
        let taskUsesWorkerHome = taskOutput.contains("HOME=\(workerHome)")
        let taskUsesServiceRoot = taskOutput.contains("SERVICE=\(storageRoot)")
        let pass = pingOK
            && httpStatus == "HTTP/1.1 400 Bad Request"
            && sameService
            && taskActiveDuringRun
            && stopBlockedDuringRun
            && helperAliveDuringRun
            && taskCompleted
            && taskOutput.contains("DONE")
            && taskUsesWorkerHome
            && taskUsesServiceRoot
            && fileReadOK
            && activeAfterTask.isEmpty
            && unknownAfterTask.isEmpty
            && portClosed
            && processCountAfterStop == 0
            && !pidStillAlive
            && rapidCycles == 2
            && rapidFinalIdle
            && isolated
            && workerSeparate
            && before == userBridgeAfter
            && helperInsideBundle
            && helperParentMatches
            && identitySource == "test-fixture-persistent"
            && controller.identityPin != nil
            && consentPassed

        let payload: [String: Any] = [
            "schema": "floe-mac-bridge-probe-v2",
            "passed": pass,
            "helperPath": helper?.path ?? "missing",
            "helperInsideHostBundle": helperInsideBundle,
            "enteredFrom": "agent",
            "servicePID": servicePID,
            "helperParentPID": ready.parentPID,
            "hostPID": getpid(),
            "helperParentMatches": helperParentMatches,
            "pidAfterBridgeEntry": pidAfterBridgeEntry ?? 0,
            "pidAfterAgentEntry": pidAfterAgentEntry ?? 0,
            "sameServicePIDAcrossEntries": sameService,
            "originAfterAgentStart": "agent",
            "originAfterBridgeEntry": originAfterBridgeEntry,
            "originAfterAgentEntry": originAfterAgentEntry,
            "signedPingOK": pingOK,
            "signedPing": pingText,
            "httpStatusLine": httpStatus ?? "none",
            "httpRejectedNonRPC": httpStatus == "HTTP/1.1 400 Bad Request",
            "listenerScope": ready.listenerScope,
            "identitySource": identitySource,
            "identityFingerprint": identityFingerprint,
            "pinnedIdentity": controller.identityPin?.fingerprintSHA256 ?? "none",
            "storageRoot": storageRoot,
            "workerHome": workerHome,
            "workerHomeSeparateFromServiceStorage": workerSeparate,
            "taskID": jobID,
            "taskActiveDuringRun": taskActiveDuringRun,
            "stopBlockedDuringRun": stopBlockedDuringRun,
            "helperAliveDuringRun": helperAliveDuringRun,
            "taskCompleted": taskCompleted,
            "taskOutput": taskOutput,
            "taskUsesWorkerHome": taskUsesWorkerHome,
            "taskUsesServiceRoot": taskUsesServiceRoot,
            "fileReadOK": fileReadOK,
            "fileReadDetail": fileReadDetail,
            "taskError": taskError ?? "none",
            "consentFlow": consentDetail,
            "consentPassed": consentPassed,
            "activeTasksAfterTask": activeAfterTask,
            "unknownTasksAfterTask": unknownAfterTask,
            "rapidCycles": rapidCycles,
            "rapidFinalIdle": rapidFinalIdle,
            "rapidFailure": rapidFailure ?? "none",
            "portClosedAfterStop": portClosed,
            "helperProcessesAfterStop": processCountAfterStop,
            "servicePIDAliveAfterStop": pidStillAlive,
            "isolatedFromUserBridge": isolated,
            "userBridgeStateBefore": snapshotObject(before),
            "userBridgeStateAfter": snapshotObject(userBridgeAfter),
            "userBridgeStateUnchanged": before == userBridgeAfter,
            "logTail": controller.readLogTail(),
            "probeRoot": probeRoot.path,
            "preferencePath": store.preferenceURL.path
        ]
        emit(payload)
        controller.detachForTermination()
        return pass ? 0 : 1
    }

    @MainActor
    static func probeRecovery(store: ModePreferenceStore, arguments: HostArguments) async -> Int32 {
        let probeRoot = arguments.dataRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-mac-m00-recovery-\(UUID().uuidString)", isDirectory: true)
        let fixture = probeRoot.appendingPathComponent("Fixture", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let before = UserBridgeGuard.capture()
        do {
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        } catch {
            emit(["schema": "floe-mac-bridge-recovery-v1", "passed": false,
                  "error": error.localizedDescription])
            return 1
        }
        if LoopbackProbe.isListening(port: BridgeWire.port) {
            emit(["schema": "floe-mac-bridge-recovery-v1", "passed": false,
                  "blockedByExistingListener": true])
            return 3
        }
        let first = BridgeComponentController(
            dataRoot: fixture.appendingPathComponent("Control", isDirectory: true),
            helperOverride: arguments.bridgeServicePath,
            testFixture: fixture
        )
        first.start(origin: .probe)
        guard let ready = await waitForReady(controller: first, timeout: 20) else {
            emit(["schema": "floe-mac-bridge-recovery-v1", "passed": false,
                  "state": stateText(first.state), "logTail": first.readLogTail()])
            first.detachForTermination()
            return 1
        }
        let jobID = UUID().uuidString
        var startError: String?
        do {
            _ = try await signedRPC(
                controller: first,
                pinnedKey: try pinnedKey(from: first),
                method: "start",
                payload: [
                    "workspaceID": .string("m00recovery"),
                    "jobID": .string(jobID),
                    "command": .string("printf 'started\\n'; sleep 20; printf 'finished\\n'")
                ]
            )
        } catch {
            startError = error.localizedDescription
        }
        try? await Task.sleep(for: .milliseconds(400))
        await first.refreshStatus()
        let activeBeforeCrash = first.state.status?.activeTaskIDs.contains(jobID) ?? false
        let servicePID = first.state.status?.pid ?? ready.pid
        kill(servicePID, SIGKILL)
        try? await Task.sleep(for: .milliseconds(800))
        first.detachForTermination()

        let second = BridgeComponentController(
            dataRoot: fixture.appendingPathComponent("Control", isDirectory: true),
            helperOverride: arguments.bridgeServicePath,
            testFixture: fixture
        )
        second.start(origin: .probe)
        guard let recovered = await waitForReady(controller: second, timeout: 20) else {
            emit(["schema": "floe-mac-bridge-recovery-v1", "passed": false,
                  "state": stateText(second.state), "logTail": second.readLogTail(),
                  "activeBeforeCrash": activeBeforeCrash,
                  "startError": startError ?? "none"])
            second.detachForTermination()
            return 1
        }
        let unknown = recovered.unknownTaskIDs
        let taskDirectory = fixture
            .appendingPathComponent("service-home/Library/Application Support/Floe Bridge/Tasks", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
        let ownerExists = FileManager.default.fileExists(atPath: taskDirectory.appendingPathComponent("owner.json").path)
        let resultExists = FileManager.default.fileExists(atPath: taskDirectory.appendingPathComponent("result.json").path)
        await second.stopAndWait(reason: "recovery probe complete")
        let taskStillPresent = FileManager.default.fileExists(atPath: taskDirectory.path)
        let portClosed = !LoopbackProbe.isListening(port: BridgeWire.port)
        let userBridgeAfter = UserBridgeGuard.capture()
        let pass = startError == nil
            && activeBeforeCrash
            && unknown.contains(jobID)
            && !resultExists
            && ownerExists
            && taskStillPresent
            && portClosed
            && before == userBridgeAfter
            && recovered.activeTaskIDs.isEmpty
        emit([
            "schema": "floe-mac-bridge-recovery-v1",
            "passed": pass,
            "servicePIDBeforeCrash": servicePID,
            "activeBeforeCrash": activeBeforeCrash,
            "startError": startError ?? "none",
            "recoveredPID": recovered.pid,
            "unknownTaskIDs": unknown,
            "jobID": jobID,
            "ownerRecordPreserved": ownerExists,
            "resultRecordPresent": resultExists,
            "taskDirectoryPreservedAfterStop": taskStillPresent,
            "activeAfterRecovery": recovered.activeTaskIDs,
            "portClosedAfterStop": portClosed,
            "userBridgeStateUnchanged": before == userBridgeAfter,
            "logTail": second.readLogTail(),
            "probeRoot": probeRoot.path,
            "preferencePath": store.preferenceURL.path
        ])
        second.detachForTermination()
        return pass ? 0 : 1
    }

    @MainActor
    static func probeIdentity(arguments: HostArguments) async -> Int32 {
        let controller = BridgeComponentController(
            dataRoot: BridgeComponentController.defaultDataRoot,
            helperOverride: arguments.bridgeServicePath
        )
        guard let helper = controller.locateHelper() else {
            emit(["schema": "floe-mac-bridge-identity-probe-v1", "passed": false,
                  "error": "Embedded helper not found."])
            return 1
        }
        let before = UserBridgeGuard.capture()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--identity-and-permissions-check"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            emit(["schema": "floe-mac-bridge-identity-probe-v1", "passed": false,
                  "helperPath": helper.path, "error": error.localizedDescription])
            return 1
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let after = UserBridgeGuard.capture()
        let status = process.terminationStatus
        let pass = status == 0 && report != nil && before == after
        emit([
            "schema": "floe-mac-bridge-identity-probe-v1",
            "passed": pass,
            "helperPath": helper.path,
            "exitStatus": status,
            "report": report ?? [:],
            "rawOutput": report == nil ? text : "parsed",
            "userBridgeStateUnchanged": before == after,
            "note": "The helper's own signed process checked Keychain readability, its code signature and current system permissions. No identity was created or reset."
        ])
        return pass ? 0 : 1
    }

    @MainActor
    static func probeConflict() async -> Int32 {
        let first = BridgeEndpointInspector.inspect()
        let second = BridgeEndpointInspector.inspect()
        let pass = first.listening && second.listening && first.pid == second.pid
        emit([
            "schema": "floe-mac-bridge-conflict-probe-v1",
            "passed": pass,
            "listening": first.listening,
            "stillListeningAfterInspection": second.listening,
            "endpoint": endpointDictionary(first),
            "note": "Inspection is read-only; no signal, bind, unlink or data write was performed."
        ])
        return pass ? 0 : 1
    }

    @MainActor
    static func probeProduction(arguments: HostArguments) async -> Int32 {
        let inventory = BridgeEndpointInspector.inspect()
        let identity = runIdentityCheck(helperOverride: arguments.bridgeServicePath)
        let identityReport = identity.report
        let accessible = identityReport?["keychainAccessible"] as? Bool ?? false
        if inventory.listening {
            emit([
                "schema": "floe-mac-bridge-production-probe-v1",
                "passed": true,
                "skipped": true,
                "started": false,
                "reason": "A Bridge listener already owns 127.0.0.1:43871; it was left untouched.",
                "endpoint": endpointDictionary(inventory)
            ])
            return 0
        }
        if inventory.data.unconfirmedTaskCount > 0 {
            emit([
                "schema": "floe-mac-bridge-production-probe-v1",
                "passed": true,
                "skipped": true,
                "started": false,
                "reason": "The real Bridge data has \(inventory.data.unconfirmedTaskCount) unconfirmed task(s); production service was not started.",
                "endpoint": endpointDictionary(inventory)
            ])
            return 0
        }
        guard accessible else {
            emit([
                "schema": "floe-mac-bridge-production-probe-v1",
                "passed": true,
                "skipped": true,
                "started": false,
                "reason": "The existing Keychain identity is not readable by this ad-hoc helper. Production start was not attempted; nothing was reset.",
                "identity": identityReport ?? [:],
                "identityExitStatus": identity.exitStatus,
                "endpoint": endpointDictionary(inventory)
            ])
            return 0
        }
        let controller = BridgeComponentController(helperOverride: arguments.bridgeServicePath)
        controller.start(origin: .probe)
        guard let status = await waitForReady(controller: controller, timeout: 20) else {
            emit([
                "schema": "floe-mac-bridge-production-probe-v1",
                "passed": false,
                "skipped": false,
                "started": false,
                "state": stateText(controller.state),
                "identity": identityReport ?? [:],
                "endpoint": endpointDictionary(BridgeEndpointInspector.inspect()),
                "logTail": controller.readLogTail()
            ])
            controller.detachForTermination()
            return 1
        }
        let pairedMatch = status.pairedClients.count == inventory.data.pairedClientCount
        let activeEmpty = status.activeTaskIDs.isEmpty
        let identityIsKeychain = status.identitySource.hasPrefix("keychain:")
        await controller.stopAndWait(reason: "production read-only probe")
        let portClosed = !LoopbackProbe.isListening(port: BridgeWire.port)
        let pass = pairedMatch && activeEmpty && identityIsKeychain && portClosed && matchesIdle(controller.state)
        emit([
            "schema": "floe-mac-bridge-production-probe-v1",
            "passed": pass,
            "skipped": false,
            "started": true,
            "servicePID": status.pid,
            "identitySource": status.identitySource,
            "pairedClients": status.pairedClients.count,
            "expectedPairedClients": inventory.data.pairedClientCount,
            "activeTaskIDs": status.activeTaskIDs,
            "unknownTaskIDs": status.unknownTaskIDs,
            "identity": identityReport ?? [:],
            "portClosedAfterStop": portClosed,
            "stateAfterStop": stateText(controller.state),
            "logTail": controller.readLogTail()
        ])
        controller.detachForTermination()
        return pass ? 0 : 1
    }

    @MainActor
    private static func waitForReady(controller: BridgeComponentController, timeout: TimeInterval) async -> BridgeControlStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = controller.state.status { return status }
            if case .failed = controller.state { return nil }
            if case .conflict = controller.state { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return controller.state.status
    }

    @MainActor
    private static func matchesIdle(_ state: BridgeComponentController.State) -> Bool {
        if case .idle = state { return true }
        return false
    }

    @MainActor
    private static func stateText(_ state: BridgeComponentController.State) -> String {
        switch state {
        case .idle: "idle"
        case .starting: "starting"
        case .ready(let status): "ready:\(status.pid)"
        case .stopping: "stopping"
        case .conflict(let endpoint): "conflict:\(endpoint.pid.map(String.init) ?? "unknown")"
        case .failed(let message): "failed:\(message)"
        }
    }

    @MainActor
    private static func exerciseConsentFlow(
        controller: BridgeComponentController,
        pinnedKey: Data
    ) async throws -> [String: Any] {
        let clientKey = Curve25519.Signing.PrivateKey()
        let clientID = BridgeWire.digest(clientKey.publicKey.rawRepresentation)
        let nonce = UUID().uuidString + UUID().uuidString
        let expectedVerification = BridgeWire.pairingVerification(
            clientKey: clientKey.publicKey.rawRepresentation,
            serverKey: pinnedKey,
            nonce: nonce
        )
        _ = try await signedRPC(
            clientKey: clientKey,
            pinnedKey: pinnedKey,
            method: "pair",
            payload: ["name": .string("M00 consent probe"), "nonce": .string(nonce)]
        )
        var shownVerification: String?
        let consentDeadline = Date().addingTimeInterval(6)
        while Date() < consentDeadline {
            await controller.refreshStatus()
            if let pending = controller.pendingConsent {
                shownVerification = pending.verification
                if pending.clientID == clientID, pending.verification == expectedVerification {
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard shownVerification == expectedVerification else {
            return [
                "passed": false,
                "clientID": clientID,
                "expectedVerification": expectedVerification,
                "shownVerification": shownVerification ?? "none",
                "error": "consent request was not shown with the expected fingerprint"
            ]
        }
        await controller.approveConsent()
        var paired = false
        let pairDeadline = Date().addingTimeInterval(5)
        while Date() < pairDeadline {
            let statusResult = try await signedRPC(
                clientKey: clientKey,
                pinnedKey: pinnedKey,
                method: "pairStatus",
                payload: ["nonce": .string(nonce)]
            )
            paired = statusResult["paired"]?.bool ?? false
            if paired { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let afterApproval = await controller.liveStatus()
        let listedAfterApproval = afterApproval?.pairedClients.contains(where: { $0.clientID == clientID }) ?? false
        await controller.revoke(clientID: clientID)
        var removed = false
        let revokeDeadline = Date().addingTimeInterval(5)
        while Date() < revokeDeadline {
            let live = await controller.liveStatus()
            removed = !(live?.pairedClients.contains(where: { $0.clientID == clientID }) ?? true)
            if removed { break }
            try? await Task.sleep(for: .milliseconds(150))
        }

        let declineKey = Curve25519.Signing.PrivateKey()
        let declineID = BridgeWire.digest(declineKey.publicKey.rawRepresentation)
        let declineNonce = UUID().uuidString + UUID().uuidString
        let declineVerification = BridgeWire.pairingVerification(
            clientKey: declineKey.publicKey.rawRepresentation,
            serverKey: pinnedKey,
            nonce: declineNonce
        )
        _ = try await signedRPC(
            clientKey: declineKey,
            pinnedKey: pinnedKey,
            method: "pair",
            payload: ["name": .string("M00 decline probe"), "nonce": .string(declineNonce)]
        )
        var declinedShown: String?
        let declineConsentDeadline = Date().addingTimeInterval(6)
        while Date() < declineConsentDeadline {
            await controller.refreshStatus()
            if let pending = controller.pendingConsent, pending.clientID == declineID {
                declinedShown = pending.verification
                if pending.verification == declineVerification { break }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard declinedShown == declineVerification else {
            return [
                "passed": false,
                "clientID": clientID,
                "expectedVerification": expectedVerification,
                "shownVerification": shownVerification ?? "none",
                "error": "the decline request was not shown with the expected fingerprint"
            ]
        }
        await controller.declineConsent()
        var declinedAfterReject = false
        let declineDeadline = Date().addingTimeInterval(5)
        while Date() < declineDeadline {
            do {
                let result = try await signedRPC(
                    clientKey: declineKey,
                    pinnedKey: pinnedKey,
                    method: "pairStatus",
                    payload: ["nonce": .string(declineNonce)]
                )
                if result["paired"]?.bool == false {
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
            } catch {
                declinedAfterReject = error.localizedDescription.localizedCaseInsensitiveContains("declined")
                if declinedAfterReject { break }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let afterDecline = await controller.liveStatus()
        let declineNotListed = !(afterDecline?.pairedClients.contains(where: { $0.clientID == declineID }) ?? false)

        return [
            "passed": paired && listedAfterApproval && removed && declinedAfterReject && declineNotListed,
            "clientID": clientID,
            "expectedVerification": expectedVerification,
            "shownVerification": shownVerification ?? "none",
            "pairedAfterApproval": paired,
            "listedAfterApproval": listedAfterApproval,
            "removedAfterRevoke": removed,
            "declineClientID": declineID,
            "declinedAfterReject": declinedAfterReject,
            "declineNotListed": declineNotListed
        ]
    }

    @MainActor
    private static func pinnedKey(from controller: BridgeComponentController) throws -> Data {
        guard let pin = controller.identityPin,
              let data = Data(base64Encoded: pin.publicKeyBase64), data.count == 32 else {
            throw BridgeControlFailure.remote("The helper identity was not pinned before the RPC request.")
        }
        return data
    }

    @MainActor
    private static func signedRPC(
        controller: BridgeComponentController,
        pinnedKey: Data,
        method: String,
        payload: [String: BridgeValue]
    ) async throws -> [String: BridgeValue] {
        try await signedRPC(
            clientKey: controller.probeClientKey,
            pinnedKey: pinnedKey,
            method: method,
            payload: payload
        )
    }

    private static func signedRPC(
        clientKey: Curve25519.Signing.PrivateKey,
        pinnedKey: Data,
        method: String,
        payload: [String: BridgeValue]
    ) async throws -> [String: BridgeValue] {
        let body = BridgeRequestBody(
            clientKey: clientKey.publicKey.rawRepresentation,
            method: method,
            payload: payload
        )
        let request = try BridgeRequest(body: body, key: clientKey)
        let requestData = try BridgeWire.encode(request)
        guard let url = URL(string: "http://127.0.0.1:\(BridgeWire.port)/rpc") else {
            throw BridgeControlFailure.remote("Invalid loopback endpoint.")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 8
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("127.0.0.1:\(BridgeWire.port)", forHTTPHeaderField: "Host")
        urlRequest.httpBody = requestData
        let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeControlFailure.remote("Bridge HTTP status \((response as? HTTPURLResponse)?.statusCode ?? -1).")
        }
        let decoded = try BridgeWire.decode(BridgeResponse.self, from: responseData)
        guard decoded.body.serverKey == pinnedKey else {
            throw BridgeControlFailure.remote("The RPC response key did not match the pinned helper identity.")
        }
        return try decoded.verified(for: request.body, pinnedKey: pinnedKey)
    }

    private static func endpointDictionary(_ endpoint: BridgeEndpointInventory) -> [String: Any] {
        var result: [String: Any] = [
            "schema": endpoint.schema,
            "listening": endpoint.listening,
            "classification": endpoint.classification,
            "identityVerification": endpoint.identityVerification,
            "observedServerKeySHA256": endpoint.observedServerKeySHA256 ?? NSNull(),
            "identityVerifiedByStoredPairing": endpoint.identityVerifiedByStoredPairing,
            "note": endpoint.note,
            "dataRoot": endpoint.data.dataRoot,
            "dataRootExists": endpoint.data.dataRootExists,
            "pairedClientCount": endpoint.data.pairedClientCount,
            "taskCount": endpoint.data.taskCount,
            "completedTaskCount": endpoint.data.completedTaskCount,
            "unconfirmedTaskCount": endpoint.data.unconfirmedTaskCount,
            "stateModified": endpoint.data.stateModified ?? "unknown"
        ]
        if let pid = endpoint.pid { result["pid"] = pid }
        if let path = endpoint.executablePath { result["executablePath"] = path }
        if let parent = endpoint.parentPID { result["parentPID"] = parent }
        if let bundle = endpoint.bundleIdentifier { result["bundleIdentifier"] = bundle }
        if let version = endpoint.version { result["version"] = version }
        if let build = endpoint.build { result["build"] = build }
        return result
    }

    @MainActor
    private static func runIdentityCheck(helperOverride: URL?) -> (report: [String: Any]?, exitStatus: Int32) {
        let controller = BridgeComponentController(
            dataRoot: BridgeComponentController.defaultDataRoot,
            helperOverride: helperOverride
        )
        guard let helper = controller.locateHelper() else { return (nil, -1) }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--identity-and-permissions-check"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (nil, -1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (report, process.terminationStatus)
    }

    @MainActor
    static func probeCatalyst(arguments: HostArguments) async -> Int32 {
        let probeRoot = arguments.dataRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-mac-m00-catalyst-\(UUID().uuidString)", isDirectory: true)
        let markerURL = probeRoot.appendingPathComponent("catalyst-smoke.json", isDirectory: false)
        let isolatedHome = probeRoot.appendingPathComponent("catalyst-home", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        } catch {
            emit([
                "schema": "floe-mac-catalyst-probe-v1",
                "passed": false,
                "error": "Could not create probe root: \(error.localizedDescription)"
            ])
            return 1
        }

        let controller = AgentUIComponentController(appOverride: arguments.catalystAppPath)
        let report = await controller.probe(
            markerURL: markerURL,
            environment: [
                "CFFIXED_USER_HOME": isolatedHome.path,
                "HOME": isolatedHome.path
            ],
            timeout: 30
        )
        let insideBundle = report.appPath.hasPrefix(Bundle.main.bundleURL.path)
        let markerPayload = report.marker ?? [:]
        let catalystFlag = markerPayload["catalyst"] as? Bool ?? false
        let themeFlag = markerPayload["floeTheme"] as? Bool ?? false
        let errorViewFlag = markerPayload["errorEventView"] as? Bool ?? false
        let passed = report.launched
            && report.terminated
            && report.activationPolicy != NSApplication.ActivationPolicy.regular.rawValue
            && catalystFlag && themeFlag && errorViewFlag
            && insideBundle

        emit([
            "schema": "floe-mac-catalyst-probe-v1",
            "passed": passed,
            "appPath": report.appPath,
            "appInsideHostBundle": insideBundle,
            "launched": report.launched,
            "pid": report.pid ?? 0,
            "activationPolicy": report.activationPolicy,
            "activationPolicyName": report.activationPolicyName,
            "singleDockEntry": report.activationPolicy != NSApplication.ActivationPolicy.regular.rawValue,
            "marker": markerPayload,
            "markerPath": report.markerPath,
            "terminated": report.terminated,
            "error": report.error ?? "none"
        ])
        try? FileManager.default.removeItem(at: probeRoot)
        return passed ? 0 : 1
    }

    private static func snapshotObject(_ snapshot: UserBridgeSnapshot) -> [String: Any] {
        [
            "exists": snapshot.exists,
            "rootModification": snapshot.rootModification ?? 0,
            "stateModification": snapshot.stateModification ?? 0,
            "stateEntryCount": snapshot.stateEntryCount
        ]
    }

    static func helperProcessCount(path: String?) -> Int {
        guard let path, !path.isEmpty else { return -1 }
        let output = runCommand("/usr/bin/pgrep", ["-f", path])
        return output.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    static func runCommand(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "command failed: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
