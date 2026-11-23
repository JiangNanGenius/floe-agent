// SPDX-License-Identifier: MPL-2.0
import Darwin
import AppKit
import Foundation
import ImageIO
import Security
import FloeTools

enum MacKimiError: LocalizedError {
    case unavailable, transport, invalidTarget, permission, message(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Install Kimi CU and enable local agent access in its settings."
        case .transport: "Kimi CU did not return a complete response. Inspect the window before repeating an action."
        case .invalidTarget: "Choose a target app, then inspect its window again before acting."
        case .permission: "This action requires approval to access another application."
        case .message(let text): text
        }
    }
}

/// A run owns one stdio session so a snapshot remains bound to the same Kimi CU connection.
final class MacKimiComputerUse: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.floeagent.mac.kimicu")
    private var process: Process?
    private var requests: FileHandle?
    private var responses: FileHandle?
    private var buffered = Data()
    private var sequence = 0
    private var snapshot: (id: String, pid: Int32, window: Int)?
    /// The companion screenshot observation paired with the current AX snapshot.
    /// Drag coordinates are only accepted in this screenshot's pixel space.
    private var screenshot: (id: String, snapshotID: String, width: Double, height: Double)?
    private var serverTools: Set<String> = []
    private var companionVersion: String?

    static func isInstalled() -> Bool {
        installedURL() != nil
    }

    static func installedURL() -> URL? {
        #if FLOE_MAC_HOST_SMOKE
        if CommandLine.arguments.contains("--background-input-gestures"),
           let path = ProcessInfo.processInfo.environment["FLOE_MAC_SMOKE_KIMI_BUNDLE"],
           path.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if hasExpectedSignature(candidate) { return candidate }
        }
        #endif
        let standard = URL(fileURLWithPath: "/Applications/KimiCU.app", isDirectory: true)
        if hasExpectedSignature(standard) { return standard }
        guard let located = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.kimi.cu"),
              located.standardizedFileURL != standard, hasExpectedSignature(located) else { return nil }
        return located
    }

    private static func hasExpectedSignature(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expected = #"anchor apple generic and identifier "ai.kimi.cu" and certificate leaf[subject.OU] = "2J9472RW75""#
        let executable = bundle.appendingPathComponent("Contents/MacOS/kimi-cu")
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expected as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
    }

    deinit { stop() }

    private func stop() {
        try? requests?.close()
        try? responses?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        requests = nil
        responses = nil
        buffered.removeAll()
        serverTools.removeAll()
        companionVersion = nil
        snapshot = nil
        screenshot = nil
    }

    struct Reply: Sendable {
        var text: String
        var image: Data?
        var mime: String?
    }

    func perform(_ action: MacDesktopControl.Arguments, pid: Int32, context: ToolContext) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if process?.isRunning != true { try connect(context) }
                    continuation.resume(returning: try invoke(action, pid: pid, context: context))
                } catch {
                    if case MacKimiError.transport = error { stop() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func connect(_ context: ToolContext) throws {
        stop()
        guard let bundle = Self.installedURL() else { throw MacKimiError.unavailable }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = bundle.appendingPathComponent("Contents/MacOS/kimi-cu")
        child.arguments = ["mcp", "-s", "user"]
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                             "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        requests = input.fileHandleForWriting
        responses = output.fileHandleForReading
        let inputFD = input.fileHandleForWriting.fileDescriptor
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0,
              fcntl(inputFD, F_SETFL, O_NONBLOCK) == 0 else { stop(); throw MacKimiError.transport }
        do {
            let info = try request("initialize", ["protocolVersion": "2024-11-05", "capabilities": [:],
                                                   "clientInfo": ["name": "Floe Agent", "version": "1"]], context)
            guard let server = info["serverInfo"] as? [String: Any],
                  server["name"] as? String == "kimi-cu" else { throw MacKimiError.unavailable }
            companionVersion = server["version"] as? String
            try send(["jsonrpc": "2.0", "method": "notifications/initialized"], context)
            let catalog = try request("tools/list", [:], context)
            let tools = catalog["tools"] as? [[String: Any]] ?? []
            // Older versions may default to a foreground click; require an explicit opt-out.
            // press_key must expose the background-default activate flag for the same reason.
            for tool in tools {
                guard let name = tool["name"] as? String,
                      let schema = tool["inputSchema"] as? [String: Any],
                      let props = schema["properties"] as? [String: Any] else { continue }
                if name == "click" && props["allow_foreground_fallback"] == nil { continue }
                if name == "press_key" && props["activate"] == nil { continue }
                serverTools.insert(name)
            }
        } catch { stop(); throw error }
    }

    private func invoke(_ action: MacDesktopControl.Arguments, pid: Int32, context: ToolContext) throws -> Reply {
        var args: [String: Any] = ["pid": pid]
        if let window = action.windowID { args["window_id"] = window }
        let name: String
        switch action.action {
        case .windows:
            name = "list_windows"
        case .inspect:
            name = "get_app_state"
            args["mode"] = "ax"
            args["limit"] = 100
            args["disable_diff"] = true
            snapshot = nil
            screenshot = nil
        case .screenshot:
            name = "get_window_state"
            // Keep the coordinate text: drag points are picked from this observation.
            args["include_text"] = true
            args["include_screenshot"] = true
            snapshot = nil
            screenshot = nil
        case .click, .setValue, .keys, .drag:
            guard let snapshot, snapshot.id == action.snapshotID, snapshot.pid == pid,
                  snapshot.window == action.windowID else { throw MacKimiError.invalidTarget }
            // One delivered input consumes the observation; the next action needs a
            // fresh inspect or screenshot of the same window. Capture the paired
            // screenshot before clearing it: drag anchors to it in this call.
            let anchoredScreenshot = screenshot
            self.snapshot = nil
            self.screenshot = nil
            switch action.action {
            case .click:
                guard let index = action.index else { throw MacKimiError.invalidTarget }
                name = "click"
                args["snapshot_id"] = snapshot.id
                args["index"] = index
                args["allow_foreground_fallback"] = false
            case .setValue:
                guard let index = action.index, let value = action.value else { throw MacKimiError.invalidTarget }
                name = "set_value"
                args["snapshot_id"] = snapshot.id
                args["index"] = index
                args["value"] = value
                args["autosubmit"] = false
            case .keys:
                // Pure background delivery: activate stays false even though the
                // companion already defaults it to false; press_key accepts no
                // snapshot/screenshot id, so the client-side AX snapshot binding is
                // the freshness contract.
                guard let keys = action.keys else { throw MacKimiError.invalidTarget }
                name = "press_key"
                args["keys"] = keys
                args["activate"] = false
            case .drag:
                // Coordinates must come from the screenshot observation paired with the
                // accepted AX snapshot; the companion rejects a stale screenshot id.
                guard let anchoredScreenshot, anchoredScreenshot.snapshotID == snapshot.id,
                      let fromX = action.fromX, let fromY = action.fromY,
                      let toX = action.toX, let toY = action.toY,
                      [fromX, toX].allSatisfy({ $0 >= 0 && $0 < anchoredScreenshot.width }),
                      [fromY, toY].allSatisfy({ $0 >= 0 && $0 < anchoredScreenshot.height }) else {
                    throw MacKimiError.invalidTarget
                }
                name = "drag"
                // 0.6.8 misinterprets this argument for native windows.
                // The serialized session still owns the immediately preceding
                // capture, with the target window and pixel bounds checked above.
                if companionVersion != "0.6.8" && companionVersion != "v0.6.8" {
                    args["screenshot_id"] = anchoredScreenshot.id
                }
                args["from_x"] = fromX
                args["from_y"] = fromY
                args["to_x"] = toX
                args["to_y"] = toY
                if let steps = action.steps { args["steps"] = steps }
                if let stepMs = action.stepMs { args["step_ms"] = stepMs }
                if let holdMs = action.holdMs { args["hold_ms"] = holdMs }
            case .windows, .inspect, .screenshot:
                throw MacKimiError.invalidTarget
            }
        }
        guard serverTools.contains(name) else { throw MacKimiError.unavailable }
        let result = try request("tools/call", ["name": name, "arguments": args], context)
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard result["isError"] as? Bool != true else { throw MacKimiError.message(String(text.prefix(1600))) }
        if let data = text.data(using: .utf8),
           let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           receipt["ok"] as? Bool == false {
            throw MacKimiError.message(String(text.prefix(1600)))
        }
        var reply = Reply(text: String(text.prefix(24_000)))
        if action.action == .inspect || action.action == .screenshot, let window = action.windowID {
            recordSnapshot(text, pid: pid, window: window)
        }
        if (action.action == .click || action.action == .setValue || action.action == .keys || action.action == .drag),
           let window = action.windowID {
            // Never repeat input to verify it. Observe the same window after the single delivery.
            do {
                let observation = try request("tools/call", ["name": "get_app_state", "arguments": [
                    "pid": pid, "window_id": window, "mode": "ax", "disable_diff": true, "limit": 70
                ]], context)
                guard observation["isError"] as? Bool != true,
                      let content = observation["content"] as? [[String: Any]] else { throw MacKimiError.invalidTarget }
                let state = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                recordSnapshot(state, pid: pid, window: window)
                reply.text += "\nWindow after action:\n" + String(state.prefix(16_000))
            } catch {
                reply.text += "\nThe window could not be inspected after delivery. Check its state before sending more input."
            }
        }
        if action.action == .screenshot {
            guard let item = content.first(where: { $0["type"] as? String == "image" }),
                  let mime = item["mimeType"] as? String, ["image/png", "image/jpeg"].contains(mime),
                  let base64 = item["data"] as? String, let data = Data(base64Encoded: base64), !data.isEmpty else {
                throw MacKimiError.message("Kimi CU returned no window image. Check Screen Recording permission in Kimi CU.")
            }
            reply.image = data
            reply.mime = mime
            if let snapshot,
               let shot = text.range(of: #"(?<=screenshot_id=)[A-Fa-f0-9-]{36}"#, options: .regularExpression),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
               let width = metadata[kCGImagePropertyPixelWidth as String] as? NSNumber,
               let height = metadata[kCGImagePropertyPixelHeight as String] as? NSNumber,
               width.doubleValue > 0, height.doubleValue > 0 {
                screenshot = (String(text[shot]), snapshot.id, width.doubleValue, height.doubleValue)
            }
        }
        return reply
    }

    private func recordSnapshot(_ text: String, pid: Int32, window: Int) {
        guard let range = text.range(of: #"(?<=snapshot_id=)[A-Fa-f0-9-]{36}"#, options: .regularExpression) else { return }
        snapshot = (String(text[range]), pid, window)
    }

    private func send(_ message: [String: Any], _ context: ToolContext) throws {
        guard let requests else { throw MacKimiError.transport }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        let deadline = ContinuousClock.now + .seconds(8)
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { throw MacKimiError.transport }
                var offset = 0
                while offset < raw.count {
                    try context.cancellation.throwIfCancelled()
                    guard ContinuousClock.now < deadline else { throw MacKimiError.transport }
                    var item = pollfd(fd: requests.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                    let ready = Darwin.poll(&item, 1, 100)
                    if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                    guard ready > 0 else { throw MacKimiError.transport }
                    let n = Darwin.write(requests.fileDescriptor, base.advanced(by: offset), raw.count - offset)
                    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    guard n > 0 else { throw MacKimiError.transport }
                    offset += n
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    private func request(_ method: String, _ params: [String: Any], _ context: ToolContext) throws -> [String: Any] {
        guard let responses, !context.cancellation.isCancelled else { throw CancellationError() }
        sequence += 1
        try send(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params], context)
        let deadline = ContinuousClock.now + .seconds(20)
        var chunk = [UInt8](repeating: 0, count: 32_768)
        var scanFrom = buffered.startIndex
        while ContinuousClock.now < deadline {
            if context.cancellation.isCancelled { stop(); throw CancellationError() }
            if let end = buffered[scanFrom...].firstIndex(of: 10) {
                let line = Data(buffered[..<end])
                buffered.removeSubrange(...end)
                scanFrom = buffered.startIndex
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw MacKimiError.transport }
                guard message["id"] as? Int == sequence else { continue }
                guard let result = message["result"] as? [String: Any] else { throw MacKimiError.transport }
                return result
            }
            var descriptor = pollfd(fd: responses.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw MacKimiError.transport }
            let count = Darwin.read(responses.fileDescriptor, &chunk, chunk.count)
            guard count > 0, buffered.count + count <= 16 * 1024 * 1024 else { throw MacKimiError.transport }
            scanFrom = buffered.endIndex
            buffered.append(contentsOf: chunk.prefix(count))
        }
        throw MacKimiError.transport
    }
}
