// Floe Mac M00 — command-line probes and packaged app entry.
//
// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import Foundation

struct HostArguments {
    enum Command: Equatable {
        case gui
        case printMode
        case setMode(AppMode)
        case probeBridge
        case probeRecovery
        case probeIdentity
        case probeConflict
        case probeProduction
        case probeCatalyst
        case selfTest
        case printAutoApproval
        case help
    }

    var command: Command = .gui
    var modeOverride: AppMode?
    var preferenceRoot: URL?
    var dataRoot: URL?
    var bridgeServicePath: URL?
    var catalystAppPath: URL?
    var testBridgeFixture: URL?
    var smoke: SmokeOptions?
    var parseError: String?
    private var fixtureEnvironment = false

    var disablesToolboxForFixture: Bool {
        fixtureEnvironment || smoke != nil || testBridgeFixture != nil || preferenceRoot != nil || dataRoot != nil
            || bridgeServicePath != nil || catalystAppPath != nil
    }

    init(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        fixtureEnvironment = HostFixturePolicy.isIsolatedEnvironment(environment)
        var index = 1
        var commandWasSet = false
        func setCommand(_ new: Command) {
            if commandWasSet, command != new {
                parseError = "Choose only one command."
                return
            }
            command = new
            commandWasSet = true
        }
        var smokeExitAfter: TimeInterval?
        var smokeResult: URL?

        while index < arguments.count {
            let argument = arguments[index]
            let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "--help", "-h":
                setCommand(.help)
                index += 1
            case "--print-mode":
                setCommand(.printMode)
                index += 1
            case "--probe-bridge":
                setCommand(.probeBridge)
                index += 1
            case "--probe-recovery":
                setCommand(.probeRecovery)
                index += 1
            case "--probe-identity":
                setCommand(.probeIdentity)
                index += 1
            case "--probe-conflict":
                setCommand(.probeConflict)
                index += 1
            case "--probe-production":
                setCommand(.probeProduction)
                index += 1
            case "--probe-catalyst":
                setCommand(.probeCatalyst)
                index += 1
            case "--self-test":
                setCommand(.selfTest)
                index += 1
            case "--print-auto-approval":
                setCommand(.printAutoApproval)
                index += 1
            case "--set-mode":
                guard let value, let mode = AppMode(rawValue: value) else {
                    parseError = "--set-mode requires agent or bridge."
                    index += 1
                    continue
                }
                setCommand(.setMode(mode))
                index += 2
            case "--mode":
                guard let value, let mode = AppMode(rawValue: value) else {
                    parseError = "--mode requires agent or bridge."
                    index += 1
                    continue
                }
                modeOverride = mode
                index += 2
            case "--preference-root":
                guard let value else { parseError = "--preference-root requires a path."; index += 1; continue }
                preferenceRoot = URL(fileURLWithPath: value, isDirectory: true)
                index += 2
            case "--data-root":
                guard let value else { parseError = "--data-root requires a path."; index += 1; continue }
                dataRoot = URL(fileURLWithPath: value, isDirectory: true)
                index += 2
            case "--bridge-service":
                guard let value else { parseError = "--bridge-service requires a path."; index += 1; continue }
                bridgeServicePath = URL(fileURLWithPath: value, isDirectory: false)
                index += 2
            case "--catalyst-app":
                guard let value else { parseError = "--catalyst-app requires a path."; index += 1; continue }
                catalystAppPath = URL(fileURLWithPath: value, isDirectory: true)
                index += 2
            case "--test-bridge-fixture":
                guard let value else { parseError = "--test-bridge-fixture requires a path."; index += 1; continue }
                testBridgeFixture = URL(fileURLWithPath: value, isDirectory: true)
                index += 2
            case "--smoke-exit-after":
                guard let value, let seconds = TimeInterval(value), seconds >= 0 else {
                    parseError = "--smoke-exit-after requires a non-negative number."
                    index += 1
                    continue
                }
                smokeExitAfter = seconds
                index += 2
            case "--smoke-result":
                guard let value else { parseError = "--smoke-result requires a path."; index += 1; continue }
                smokeResult = URL(fileURLWithPath: value, isDirectory: false)
                index += 2
            default:
                if argument.hasPrefix("-psn_") {
                    // LaunchServices may append a process serial number.
                    index += 1
                } else {
                    parseError = "Unknown argument: \(argument)"
                    index += 1
                }
            }
        }
        if smokeExitAfter != nil || smokeResult != nil {
            smoke = SmokeOptions(exitAfter: smokeExitAfter ?? 3, resultURL: smokeResult)
        }
    }

    static var usage: String {
        """
        Floe Mac M00 host

        Usage:
          Floe [--mode agent|bridge] [--preference-root <path>]
               [--smoke-exit-after <seconds>] [--smoke-result <path>]
          Floe --print-mode [--preference-root <path>]
          Floe --set-mode agent|bridge [--preference-root <path>]
          Floe --self-test --mode agent|bridge [--preference-root <path>]
          Floe --probe-bridge [--data-root <path>] [--bridge-service <path>]
          Floe --probe-recovery [--data-root <path>] [--bridge-service <path>]
          Floe --probe-identity [--bridge-service <path>]
          Floe --probe-conflict
          Floe --probe-production
          Floe --probe-catalyst [--data-root <path>] [--catalyst-app <path>]
          Floe --print-auto-approval
        """
    }
}

@main
@MainActor
struct FloeMacHostMain {
    static func main() async {
        let arguments = HostArguments(CommandLine.arguments)
        if let parseError = arguments.parseError {
            FileHandle.standardError.write(Data((parseError + "\n\n" + HostArguments.usage + "\n").utf8))
            exit(2)
        }
        if arguments.command == .help {
            print(HostArguments.usage)
            exit(0)
        }

        let rootURL = ModePreferenceStore.rootURL(commandLineRoot: arguments.preferenceRoot)
        let store = ModePreferenceStore(rootURL: rootURL)

        switch arguments.command {
        case .help:
            print(HostArguments.usage)
            exit(0)
        case .printMode:
            exit(HostProbe.printMode(store: store, modeOverride: arguments.modeOverride))
        case .setMode(let mode):
            exit(HostProbe.setMode(store: store, mode: mode))
        case .probeBridge:
            exit(await HostProbe.probeBridge(store: store, arguments: arguments))
        case .probeRecovery:
            exit(await HostProbe.probeRecovery(store: store, arguments: arguments))
        case .probeIdentity:
            exit(await HostProbe.probeIdentity(arguments: arguments))
        case .probeConflict:
            exit(await HostProbe.probeConflict())
        case .probeProduction:
            exit(await HostProbe.probeProduction(arguments: arguments))
        case .probeCatalyst:
            exit(await HostProbe.probeCatalyst(arguments: arguments))
        case .selfTest:
            exit(HostProbe.selfTest(store: store, modeOverride: arguments.modeOverride))
        case .printAutoApproval:
            exit(await HostProbe.printAutoApproval())
        case .gui:
            if let mode = arguments.modeOverride, store.load() == nil {
                // An explicit command-line choice is a deliberate selection;
                // persist it in the (possibly isolated) preference root.
                try? store.save(mode)
            }
            let namespace = Bundle.main.bundleIdentifier ?? "org.floeagent.mac"
            // Apple keeps the preference domain for the same App ID.
            // Bridge 1.1.6 wrote this when its setup window first appeared.
            let priorBridgeSetup = namespace == "org.floeagent.macbridge" && !arguments.disablesToolboxForFixture
                && UserDefaults.standard.bool(forKey: "bridge.setupWindowShown")
            let resolved = store.resolve(commandLineMode: arguments.modeOverride, inheritedBridgeSetup: priorBridgeSetup)
            let smokeSupport: URL? = if arguments.smoke != nil && resolved.mode == .agent {
                Self.makeAgentSmokeSupport()
            } else {
                nil
            }
            let agentWorkspace: HostAgentWorkspace?
            if let smokeSupport {
                agentWorkspace = HostAgentWorkspace(supportDirectory: smokeSupport, namespace: namespace,
                                                    useKeychain: false)
            } else if !arguments.disablesToolboxForFixture,
                      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                agentWorkspace = HostAgentWorkspace(supportDirectory: support, namespace: namespace)
            } else {
                agentWorkspace = nil
            }
            let model = HostModel(
                store: store,
                resolved: resolved,
                bridgeDataRoot: arguments.dataRoot ?? BridgeComponentController.defaultDataRoot,
                bridgeFixture: arguments.testBridgeFixture,
                agentWorkspace: agentWorkspace
            )
            let delegate = HostAppDelegate(model: model, smoke: arguments.smoke,
                                           toolboxEnabled: !arguments.disablesToolboxForFixture)
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            app.run()
            if let smokeSupport { try? FileManager.default.removeItem(at: smokeSupport) }
            exit(0)
        }
    }

    private static func makeAgentSmokeSupport() -> URL? {
        guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else { return nil }
        defer { Darwin.free(canonical) }
        let temporaryDirectory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        let template = temporaryDirectory.appendingPathComponent("floe-agent-smoke.XXXXXX").path
        var bytes = Array(template.utf8CString)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            guard let name = mkdtemp(buffer.baseAddress) else { return nil }
            return URL(fileURLWithPath: String(cString: name), isDirectory: true)
        }
    }
}
