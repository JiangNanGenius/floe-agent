// SPDX-License-Identifier: MPL-2.0
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FloeTools
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One instance per task run. AX requests execute on a private queue because
/// even reading an unresponsive application's AX tree can block.
actor MacFloeComputerUse: MacDesktopClient {
    private let queue = DispatchSerialQueue(label: "org.floeagent.mac.computer-use")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private struct Window {
        let id: CGWindowID
        let owner: pid_t
        let frame: CGRect
        let title: String?

        func matches(_ frame: CGRect) -> Bool {
            abs(self.frame.minX - frame.minX) <= 2 && abs(self.frame.minY - frame.minY) <= 2
                && abs(self.frame.width - frame.width) <= 2 && abs(self.frame.height - frame.height) <= 2
        }
    }

    private struct Observation {
        let id = UUID()
        let window: Window
        let element: AXUIElement
        let nodes: [AXUIElement]
        let text: String
        let pixels: CGSize?

        var summary: String { "snapshot_id=\(id.uuidString) window_id=\(window.id)\n" + text }
    }

    private struct CaptureTarget {
        let window: Window
        let element: AXUIElement
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let expiresAt: ContinuousClock.Instant
    }

    private enum InputCompletion { case sent, confirmed }

    private enum Failure: LocalizedError {
        case accessibility, capturePermission, eventPermission, ambiguousWindow, unsupportedControl, capture, busy, key

        var errorDescription: String? {
            switch self {
            case .accessibility: "Allow Accessibility for Floe Agent in Settings > Permissions."
            case .capturePermission: "Allow Screen Recording for Floe Agent in Settings > Permissions."
            case .eventPermission: "Allow Accessibility for Floe Agent to send keyboard and mouse input."
            case .ambiguousWindow: "Floe could not match the target to a unique accessible window. List its windows again or use Kimi CU."
            case .unsupportedControl: "This control does not accept the requested background action."
            case .capture: "Floe could not capture this window. It may be minimized or protected."
            case .busy: "A window action is already in progress."
            case .key: "Use one supported key or shortcut, such as cmd+a, return, escape or tab."
            }
        }
    }

    static let toolDescription = "Use Floe Native to control a running Mac app by bundle ID. Inspect a specific window before acting. Click an accessible control or set an editable value. When offered, use keys for a focused control in the selected window, and drag within that window's current screenshot. Input is sent directly to the selected app and window. Verify the returned state before repeating input."

    static var availableActions: [MacDesktopControl.Action] {
        guard AXIsProcessTrusted() else { return [] }
        let recording = CGPreflightScreenCaptureAccess()
        let posting = CGPreflightPostEventAccess()
        return MacDesktopControl.Action.allCases.filter { action in
            switch action {
            case .screenshot: recording
            case .keys: posting
            case .drag: recording && posting
            default: true
            }
        }
    }

    static var status: String {
        let actions = availableActions
        guard !actions.isEmpty else { return "Floe Native is selected. " + Failure.accessibility.localizedDescription }
        let enabled = "Floe Native is selected. Available actions: " + actions.map(\.rawValue).joined(separator: ", ") + "."
        return actions.contains(.screenshot) ? enabled : enabled + " " + Failure.capturePermission.localizedDescription
    }

    private var observation: Observation?
    private var captureTarget: CaptureTarget?
    private var busy = false

    func perform(_ action: MacDesktopControl.Arguments, pid: Int32, context: ToolContext) async throws -> MacDesktopReply {
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        try checkCancellation(context)
        guard AXIsProcessTrusted() else { throw Failure.accessibility }
        // The agent must not operate its own approval cards.
        guard pid != getpid() else { throw MacDesktopError.invalidTarget }
        if action.action == .windows {
            let windows = Self.windows(for: pid)
            let lines = windows.prefix(100).map { "window_id=\($0.id) title=\(Self.oneLine($0.title ?? "(untitled)"))" }
            return .init(text: lines.isEmpty ? "No windows found." : lines.joined(separator: "\n"))
        }

        guard let rawID = action.windowID, let id = CGWindowID(exactly: rawID),
              let window = Self.windows(for: pid, id: id).first else { throw MacDesktopError.invalidTarget }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        let element = try Self.accessibilityWindow(for: window, in: application)

        switch action.action {
        case .inspect:
            observation = nil
            let next = try inspect(window, element: element, context: context)
            observation = next
            return .init(text: next.summary)
        case .screenshot:
            observation = nil
            let image = try await capture(window, element: element, context: context)
            try checkCancellation(context)
            // The image and positions used for mouse input must describe the
            // same window at the same size and location.
            guard let current = Self.windows(for: pid, id: id).first, window.matches(current.frame),
                  CFEqual(try Self.accessibilityWindow(for: current, in: application), element) else {
                captureTarget = nil
                throw MacDesktopError.invalidTarget
            }
            let pixels = CGSize(width: image.width, height: image.height)
            let next = try inspect(window, element: element, pixels: pixels, context: context)
            let data = try Self.png(image)
            observation = next
            return .init(text: next.summary, image: data, mime: "image/png")
        case .click, .setValue, .keys, .drag:
            guard let prior = observation, prior.id.uuidString == action.snapshotID,
                  prior.window.id == id, prior.window.owner == pid,
                  CFEqual(prior.element, element) else { throw MacDesktopError.invalidTarget }
            observation = nil
            try checkCancellation(context)
            let completion: InputCompletion
            switch action.action {
            case .click, .setValue:
                guard let index = action.index, prior.nodes.indices.contains(index) else { throw MacDesktopError.invalidTarget }
                let target = prior.nodes[index]
                guard Self.belongs(target, to: element), !Self.isSecure(target) else { throw Failure.unsupportedControl }
                completion = try Self.act(action, on: target)
            case .keys:
                guard let keys = action.keys,
                      let focused = Self.attribute(application, kAXFocusedUIElementAttribute).flatMap(Self.axElement),
                      Self.belongs(focused, to: element), !Self.isSecure(focused) else { throw Failure.unsupportedControl }
                completion = try Self.sendKey(keys, to: focused, pid: pid)
            case .drag:
                guard prior.window.matches(window.frame), let pixels = prior.pixels else { throw MacDesktopError.invalidTarget }
                try await drag(action, in: window, pixels: pixels, context: context)
                completion = .sent
            case .windows, .inspect, .screenshot:
                throw MacDesktopError.invalidTarget
            }
            // Skip the settle delay when reading back the target confirms
            // the action. Posted events and unconfirmed changes may take time.
            do {
                if completion == .sent { try await Task.sleep(for: .milliseconds(90)) }
                let next = try inspect(window, element: element, context: context)
                observation = next
                return .init(text: "Action sent.\nWindow after action:\n" + next.summary)
            } catch {
                return .init(text: "Action sent. Check the window before sending more input.")
            }
        case .windows:
            throw MacDesktopError.invalidTarget
        }
    }

    private static func windows(for pid: pid_t, id: CGWindowID? = nil) -> [Window] {
        let options: CGWindowListOption = id == nil ? .optionAll : .optionIncludingWindow
        let entries = CGWindowListCopyWindowInfo(options, id ?? kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID, id == nil || windowID == id,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), !frame.isEmpty,
                  frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return nil }
            return Window(id: windowID, owner: owner, frame: frame, title: entry[kCGWindowName as String] as? String)
        }
    }

    private static func accessibilityWindow(for window: Window, in application: AXUIElement) throws -> AXUIElement {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(application, kAXWindowsAttribute as CFString, &count) == .success,
              (1...128).contains(count) else { throw Failure.ambiguousWindow }
        let deadline = ContinuousClock.now + .seconds(2)
        var candidates: [AXUIElement] = []
        for element in elements(application, kAXWindowsAttribute, max: count) {
            guard ContinuousClock.now < deadline else { throw Failure.ambiguousWindow }
            AXUIElementSetMessagingTimeout(element, 0.3)
            if Self.frame(element).map(window.matches) == true { candidates.append(element) }
        }
        if candidates.count == 1, let match = candidates.first { return match }
        if let title = window.title, !title.isEmpty {
            let named = candidates.filter { attribute($0, kAXTitleAttribute) as? String == title }
            if named.count == 1, let match = named.first { return match }
        }
        throw Failure.ambiguousWindow
    }

    private func inspect(_ window: Window, element: AXUIElement, pixels: CGSize? = nil, context: ToolContext) throws -> Observation {
        let deadline = ContinuousClock.now + .seconds(2)
        var stack = [(element, 0)]
        var nodes: [AXUIElement] = []
        var visited = Set<AXUIElement>()
        var lines: [String] = []
        while let (node, depth) = stack.popLast() {
            try checkCancellation(context)
            if nodes.count == 100 || ContinuousClock.now >= deadline {
                lines.append("Window tree shortened.")
                break
            }
            if visited.contains(node) { continue }
            AXUIElementSetMessagingTimeout(node, 0.2)
            let fields = Self.fields(node, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                            kAXDescriptionAttribute, kAXFocusedAttribute])
            guard fields.count == 5, let role = fields[0] as? String else { continue }
            let secure = fields[1] as? String == kAXSecureTextFieldSubrole
            let title = fields[2] as? String ?? fields[3] as? String ?? ""
            let focused = (fields[4] as? Bool == true) ? " (focused)" : ""
            let value = secure ? "" : (Self.attribute(node, kAXValueAttribute) as? String ?? "")
            let prefix = String(repeating: "  ", count: depth)
            var line = "\(prefix)[\(nodes.count)] \(Self.oneLine(role)) \(Self.oneLine(title))\(focused)"
            if !value.isEmpty { line += " value=\(Self.oneLine(value))" }
            lines.append(line)
            nodes.append(node)
            visited.insert(node)
            if depth < 12 && !secure {
                stack.append(contentsOf: Self.elements(node, kAXChildrenAttribute, max: 100).reversed().map { ($0, depth + 1) })
            }
        }
        guard !nodes.isEmpty else { throw Failure.ambiguousWindow }
        if let pixels { lines.insert("screenshot_pixels=\(Int(pixels.width))x\(Int(pixels.height))", at: 0) }
        return Observation(window: window, element: element, nodes: nodes, text: lines.joined(separator: "\n"), pixels: pixels)
    }

    private func capture(_ window: Window, element: AXUIElement, context: ToolContext) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            captureTarget = nil
            throw Failure.capturePermission
        }
        // Reuse the window filter briefly within this task run. Capture a new
        // image each time and retain the owner and geometry checks around it.
        if let target = captureTarget, target.expiresAt > .now,
           target.window.owner == window.owner, target.window.id == window.id,
           target.window.frame == window.frame, CFEqual(target.element, element) {
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: target.filter,
                                                                   configuration: target.configuration)
            } catch {
                captureTarget = nil
                try checkCancellation(context)
            }
        }
        captureTarget = nil
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        try checkCancellation(context)
        guard let target = content.windows.first(where: {
            $0.windowID == window.id && $0.owningApplication?.processID == window.owner
        }), window.matches(target.frame) else { throw Failure.capture }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let size = target.frame.size
        let scale = min(CGFloat(max(1, filter.pointPixelScale)), 2560 / max(size.width, size.height))
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        captureTarget = .init(window: window, element: element, filter: filter,
                              configuration: configuration, expiresAt: .now + .seconds(5))
        return image
    }

    private static func png(_ image: CGImage) throws -> Data {
        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw Failure.capture }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer), bytes.length > 0 else { throw Failure.capture }
        return bytes as Data
    }

    private static func act(_ action: MacDesktopControl.Arguments, on node: AXUIElement) throws -> InputCompletion {
        guard attribute(node, kAXEnabledAttribute) as? Bool != false else { throw Failure.unsupportedControl }
        switch action.action {
        case .click:
            var actions: CFArray?
            if AXUIElementCopyActionNames(node, &actions) == .success,
               let options = actions as? [String], options.contains(kAXPressAction) {
                guard AXUIElementPerformAction(node, kAXPressAction as CFString) == .success else { throw Failure.unsupportedControl }
                return .sent
            }
            let role = attribute(node, kAXRoleAttribute) as? String
            guard role == kAXTextFieldRole || role == kAXTextAreaRole else { throw Failure.unsupportedControl }
            try set(node, kAXFocusedAttribute, kCFBooleanTrue)
            return attribute(node, kAXFocusedAttribute) as? Bool == true ? .confirmed : .sent
        case .setValue:
            guard let value = action.value else { throw MacDesktopError.invalidTarget }
            try set(node, kAXValueAttribute, value as CFString)
            return attribute(node, kAXValueAttribute) as? String == value ? .confirmed : .sent
        default:
            throw MacDesktopError.invalidTarget
        }
    }

    private static func set(_ node: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(node, name as CFString, &settable) == .success, settable.boolValue,
              AXUIElementSetAttributeValue(node, name as CFString, value) == .success else { throw Failure.unsupportedControl }
    }

    private static func belongs(_ node: AXUIElement, to window: AXUIElement) -> Bool {
        if CFEqual(node, window) { return true }
        if let owner = attribute(node, kAXWindowAttribute).flatMap(axElement) { return CFEqual(owner, window) }
        var node = node
        for _ in 0..<16 {
            guard let parent = attribute(node, kAXParentAttribute).flatMap(axElement), !CFEqual(node, parent) else { return false }
            if CFEqual(parent, window) { return true }
            node = parent
        }
        return false
    }

    private static func isSecure(_ node: AXUIElement) -> Bool {
        attribute(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }

    private static func fields(_ node: AXUIElement, _ names: [String]) -> [Any] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, names as CFArray, [], &values) == .success else { return [] }
        return values as? [Any] ?? []
    }

    private static func elements(_ node: AXUIElement, _ name: String, max: Int) -> [AXUIElement] {
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(node, name as CFString, 0, max, &values) == .success,
              let entries = values as? [CFTypeRef] else { return [] }
        return entries.compactMap(axElement)
    }

    private static func axElement(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        let geometry = fields(element, [kAXPositionAttribute, kAXSizeAttribute])
        if geometry.count == 2, let result = frame(position: geometry[0] as CFTypeRef, size: geometry[1] as CFTypeRef) {
            return result
        }
        return frame(position: attribute(element, kAXPositionAttribute), size: attribute(element, kAXSizeAttribute))
    }

    private static func frame(position: CFTypeRef?, size rawSize: CFTypeRef?) -> CGRect? {
        guard let position, CFGetTypeID(position) == AXValueGetTypeID(),
              let rawSize, CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func oneLine(_ text: String) -> String {
        String(text.prefix(180)).components(separatedBy: .controlCharacters).joined(separator: " ")
    }

    private func checkCancellation(_ context: ToolContext) throws {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
    }

    private static func sendKey(_ chord: String, to focused: AXUIElement, pid: pid_t) throws -> InputCompletion {
        guard CGPreflightPostEventAccess() else { throw Failure.eventPermission }
        let parts = chord.lowercased().split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count <= 5, let name = parts.last, let key = keyCodes[String(name)] else { throw Failure.key }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: throw Failure.key
            }
        }
        // AppKit can ignore a background menu shortcut even when it accepts
        // a keystroke. Select text directly when the focused field exposes it.
        if key == kVK_ANSI_A, flags == .maskCommand,
           let text = attribute(focused, kAXValueAttribute) as? String {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(focused, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
               settable.boolValue {
                var range = CFRange(location: 0, length: text.utf16.count)
                guard let value = AXValueCreate(.cfRange, &range),
                      AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, value) == .success
                else { throw Failure.unsupportedControl }
                var selection = CFRange()
                guard let selectedRange = attribute(focused, kAXSelectedTextRangeAttribute),
                      CFGetTypeID(selectedRange) == AXValueGetTypeID(),
                      AXValueGetValue(selectedRange as! AXValue, .cfRange, &selection),
                      selection.location == range.location, selection.length == range.length else { return .sent }
                return .confirmed
            }
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false) else { throw Failure.key }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return .sent
    }

    private func drag(_ action: MacDesktopControl.Arguments, in window: Window,
                      pixels: CGSize, context: ToolContext) async throws {
        guard CGPreflightPostEventAccess() else { throw Failure.eventPermission }
        func point(_ x: Double?, _ y: Double?) -> CGPoint? {
            guard let x, let y, (0..<pixels.width).contains(x), (0..<pixels.height).contains(y) else { return nil }
            return CGPoint(x: x * window.frame.width / pixels.width, y: y * window.frame.height / pixels.height)
        }
        guard let start = point(action.fromX, action.fromY), let end = point(action.toX, action.toY) else {
            throw MacDesktopError.invalidTarget
        }
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        func send(_ type: NSEvent.EventType, at point: CGPoint) throws {
            // The AppKit event carries the window number through to Quartz.
            // Its factory flips Y about the primary display, so the resulting
            // CGEvent has the window-local, top-left coordinates we observed.
            let location = CGPoint(x: point.x, y: displayHeight - point.y)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(window.id), context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)?.cgEvent,
                abs(event.location.x - point.x) < 1, abs(event.location.y - point.y) < 1 else {
                throw Failure.unsupportedControl
            }
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.postToPid(window.owner)
        }
        try checkCancellation(context)
        try send(.leftMouseDown, at: start)
        var last = start
        defer {
            if Self.windows(for: window.owner, id: window.id).first != nil {
                try? send(.leftMouseUp, at: last)
            }
        }
        if let hold = action.holdMs, hold > 0 { try await Task.sleep(for: .milliseconds(hold)) }
        let count = action.steps ?? 24
        for step in 1...count {
            try await Task.sleep(for: .milliseconds(action.stepMs ?? 12))
            try checkCancellation(context)
            guard let current = Self.windows(for: window.owner, id: window.id).first,
                  window.matches(current.frame) else { throw MacDesktopError.invalidTarget }
            let fraction = CGFloat(step) / CGFloat(count)
            let next = CGPoint(x: start.x + fraction * (end.x - start.x), y: start.y + fraction * (end.y - start.y))
            try send(.leftMouseDragged, at: next)
            last = next
        }
    }

    private static let keyCodes = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "return": kVK_Return, "enter": kVK_Return, "escape": kVK_Escape, "esc": kVK_Escape,
        "tab": kVK_Tab, "space": kVK_Space, "backspace": kVK_Delete, "delete": kVK_ForwardDelete,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
    ]
}
