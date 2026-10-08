// FloeApp — shared command bridge into the pinned Collabora engine.
//
// The UI and the agent tools dispatch the SAME validated `OfficeEngineCommand`
// plans. This file owns the JavaScript adapter that turns a plan step into the
// engine's own sendUnoCommand/socket/setPart calls, plus the token-correlated
// read of the engine's `commandstatechanged` stream for commands the engine
// reports. It never treats a dispatch acknowledgement as proof that a document
// edit landed: the caller flushes the working copy and verifies the saved
// package (`OfficeOutputValidator`).
//
// No arbitrary UNO name or JavaScript crosses this boundary: the request only
// carries the steps of plans built by `OfficeEngineCommandCatalog`.

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import FloeDocuments

enum OfficeCommandBridgeError: LocalizedError {
    case bridgeUnavailable
    case notReady
    case dialogOpen
    case readOnly
    case dispatchFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .bridgeUnavailable:
            OfficeInkText.t("Office 命令桥接不可用。", "The Office command bridge is unavailable.")
        case .notReady:
            OfficeInkText.t("文档尚未进入可编辑状态。", "The document is not editable yet.")
        case .dialogOpen:
            OfficeInkText.t("文档中有一个对话框处于打开状态，请先关闭后再试。",
                            "A dialog is open in the document; close it before retrying.")
        case .readOnly:
            OfficeInkText.t("文档当前为只读，无法应用编辑。", "The document is read-only; the edit cannot be applied.")
        case .dispatchFailed(let reason):
            OfficeInkText.t("文档引擎未能执行命令（\(reason)）。",
                            "The document engine could not execute the command (\(reason)).")
        case .invalidResponse:
            OfficeInkText.t("Office 命令桥接返回了无效响应。", "The Office command bridge returned an invalid response.")
        }
    }
}

@MainActor
enum OfficeCommandBridge {    struct DispatchOutcome {
        var token: Int
        var commandIDs: [String]
    }

    static func dispatch(_ commands: [OfficeEngineCommand],
                         controller: UIViewController) async throws -> DispatchOutcome {
        controller.loadViewIfNeeded()
        guard let webView = OfficeExplicitSaveBridge.findWebView(in: controller.view) else {
            throw OfficeCommandBridgeError.bridgeUnavailable
        }
        guard !commands.isEmpty else {
            throw OfficeCommandBridgeError.dispatchFailed("empty-command-list")
        }
        let request = try requestJSON(commands)
        let result: Any?
        do {
            result = try await webView.evaluateJavaScript(
                "window.__floeOfficeCommandDispatch ? window.__floeOfficeCommandDispatch(\(request)) : null")
        } catch {
            throw OfficeCommandBridgeError.dispatchFailed("bridge-unreachable")
        }
        guard let object = result as? [String: Any] else {
            throw OfficeCommandBridgeError.invalidResponse
        }
        guard (object["ok"] as? Bool) == true else {
            switch object["reason"] as? String {
            case "bridge-unavailable": throw OfficeCommandBridgeError.bridgeUnavailable
            case "not-ready": throw OfficeCommandBridgeError.notReady
            case "dialog-open": throw OfficeCommandBridgeError.dialogOpen
            case "read-only": throw OfficeCommandBridgeError.readOnly
            case .some(let reason): throw OfficeCommandBridgeError.dispatchFailed(reason)
            case .none: throw OfficeCommandBridgeError.dispatchFailed("unknown")
            }
        }
        guard let token = (object["token"] as? NSNumber)?.intValue, token > 0 else {
            throw OfficeCommandBridgeError.invalidResponse
        }
        return DispatchOutcome(token: token, commandIDs: commands.map(\.id))
    }

    /// Fresh `commandstatechanged` events correlated with one dispatch token.
    /// Returns the command names that reported a NEW state after the dispatch.
    /// This is supplementary evidence only; an absent event never fails a
    /// saved-package verification and is never reported as applied.
    static func freshStateCommands(token: Int, controller: UIViewController,
                                   timeout: TimeInterval = 1.5) async -> Set<String> {
        guard let webView = OfficeExplicitSaveBridge.findWebView(in: controller.view) else { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return [] }
            try? await Task.sleep(nanoseconds: 100_000_000)
            let value = (try? await webView.evaluateJavaScript(
                "window.__floeOfficeCommandFreshState ? window.__floeOfficeCommandFreshState(\(token)) : null")) as? [String: Any]
            if let fresh = value?["fresh"] as? [String], !fresh.isEmpty {
                return Set(fresh)
            }
        }
        return []
    }

    /// The engine's opaque current selection/cursor identity, or nil when the
    /// page exposes none. Never interpreted beyond equality.
    static func selectionFingerprint(controller: UIViewController) async -> String? {
        guard let webView = OfficeExplicitSaveBridge.findWebView(in: controller.view) else { return nil }
        let value = try? await webView.evaluateJavaScript(
            "window.__floeOfficeSelectionFingerprint ? window.__floeOfficeSelectionFingerprint() : null")
        guard let fingerprint = value as? String, !fingerprint.isEmpty else { return nil }
        return fingerprint
    }


    static func requestJSON(_ commands: [OfficeEngineCommand]) throws -> String {
        var commandObjects: [[String: Any]] = []
        for command in commands {
            var steps: [[String: Any]] = []
            for step in command.plan.steps {
                switch step {
                case .uno(let name, let arguments):
                    var encodedArguments: [String: Any] = [:]
                    for (key, argument) in arguments {
                        encodedArguments[key] = argument.jsonObject
                    }
                    steps.append(["kind": "uno", "name": name, "arguments": encodedArguments])
                case .socket(let payload):
                    steps.append(["kind": "socket", "payload": payload])
                case .selectPart(let index):
                    steps.append(["kind": "selectPart", "index": index])
                }
            }
            commandObjects.append(["id": command.id, "steps": steps])
        }
        let request: [String: Any] = ["commands": commandObjects]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            throw OfficeCommandBridgeError.dispatchFailed("request-encoding")
        }
        return json
    }

    /// Injected into the Office web view at document start (alongside the ink
    /// and explicit-save adapters). Uses the engine's own APIs only.
    static let script = #"""
    (() => {
      if (window.__floeOfficeCommandBridgeInstalled) return;
      window.__floeOfficeCommandBridgeInstalled = true;

      const UNO = '.uno:';
      const withPrefix = (name) => {
        if (typeof name !== 'string' || name.length === 0) return '';
        return name.substring(0, UNO.length) === UNO ? name : UNO + name;
      };

      window.__floeOfficeCommandEventSeq = window.__floeOfficeCommandEventSeq || {};
      window.__floeOfficeCommandEventValue = window.__floeOfficeCommandEventValue || {};
      window.__floeOfficeCommandListenerMap = null;
      window.__floeOfficeCommandListener = null;
      window.__floeOfficeCommandToken = 0;
      window.__floeOfficeCommandLast = null;

      const record = (event) => {
        if (!event || typeof event.commandName !== 'string') return;
        const key = withPrefix(event.commandName);
        if (!key) return;
        window.__floeOfficeCommandEventSeq[key] = (window.__floeOfficeCommandEventSeq[key] || 0) + 1;
        window.__floeOfficeCommandEventValue[key] = event.state;
      };

      const ensureListener = (map) => {
        if (!map || typeof map.on !== 'function') return false;
        if (window.__floeOfficeCommandListenerMap === map) return true;
        try {
          const previous = window.__floeOfficeCommandListenerMap;
          if (previous && typeof previous.off === 'function' && window.__floeOfficeCommandListener)
            previous.off('commandstatechanged', window.__floeOfficeCommandListener);
          const listener = (event) => {
            if (window.__floeOfficeCommandListenerMap === map) record(event);
          };
          map.on('commandstatechanged', listener);
          window.__floeOfficeCommandListener = listener;
        } catch (_) {
          return false;
        }
        window.__floeOfficeCommandListenerMap = map;
        return true;
      };

      window.__floeOfficeCommandReady = () => {
        try {
          const map = window.app && window.app.map;
          return !!(map && typeof map.sendUnoCommand === 'function'
            && typeof map.isEditMode === 'function' && map.isEditMode());
        } catch (_) { return false; }
      };

      // Opaque identity of the current selection/cursor. It is never
      // interpreted beyond equality: a proposal binds this string and the
      // apply refuses when it changed, so a selection-relative edit can never
      // silently land on a different paragraph/cell/object. Returns null when
      // the engine exposes no stable selection; the caller then gates the
      // command instead of applying it against an unknown target.
      window.__floeOfficeSelectionFingerprint = () => {
        try {
          const selection = window.app && window.app.definitions
            && window.app.definitions.graphicSelection;
          if (selection && typeof selection.hasActiveSelection === 'function'
              && selection.hasActiveSelection()) {
            let handles = null;
            if (typeof selection.getSelectionHandles === 'function') {
              handles = selection.getSelectionHandles();
            } else if (Array.isArray(selection.selectionHandles)) {
              handles = selection.selectionHandles;
            }
            return 'graphic:' + JSON.stringify(handles || []);
          }
          const cursor = window.app && window.app.file && window.app.file.textCursor;
          if (cursor && cursor.rectangle) {
            const rectangle = cursor.rectangle;
            return 'cursor:' + [rectangle.x1, rectangle.y1, rectangle.x2, rectangle.y2].join(',');
          }
          const cell = window.app && window.app.calc && window.app.calc.cellCursor;
          if (cell && cell.position) {
            return 'cell:' + JSON.stringify(cell.position);
          }
          return null;
        } catch (_) { return null; }
      };

      window.__floeOfficeCommandDispatch = (request) => {
        let map;
        try {
          map = window.app && window.app.map;
        } catch (_) { return { ok: false, reason: 'bridge-unavailable' }; }
        if (!map || typeof map.sendUnoCommand !== 'function'
            || typeof map.isEditMode !== 'function')
          return { ok: false, reason: 'bridge-unavailable' };
        if (!map.isEditMode()) return { ok: false, reason: 'not-ready' };
        try {
          if (window.app && window.app.file && window.app.file.readOnly === true)
            return { ok: false, reason: 'read-only' };
          if (map.dialog && typeof map.dialog.hasOpenedDialog === 'function'
              && map.dialog.hasOpenedDialog())
            return { ok: false, reason: 'dialog-open' };
        } catch (_) { return { ok: false, reason: 'bridge-unavailable' }; }
        const commands = request && request.commands;
        if (!Array.isArray(commands) || commands.length === 0 || commands.length > 64)
          return { ok: false, reason: 'invalid' };
        const listener = ensureListener(map);
        const before = {};
        const names = [];
        for (const command of commands) {
          if (!command || !Array.isArray(command.steps) || command.steps.length === 0)
            return { ok: false, reason: 'invalid-step' };
          for (const step of command.steps) {
            if (!step || typeof step.kind !== 'string')
              return { ok: false, reason: 'invalid-step' };
            if (step.kind === 'uno') {
              if (typeof step.name !== 'string' || step.name.indexOf(UNO) !== 0)
                return { ok: false, reason: 'invalid-step' };
              // Snapshot the event counter BEFORE the dispatch so a fresh
              // commandstatechanged event can be correlated with this batch.
              before[step.name] = window.__floeOfficeCommandEventSeq[step.name] || 0;
              names.push(step.name);
              try {
                if (step.arguments && Object.keys(step.arguments).length > 0)
                  map.sendUnoCommand(step.name, step.arguments);
                else
                  map.sendUnoCommand(step.name);
              } catch (error) {
                return { ok: false, reason: 'dispatch-failed',
                         message: String((error && error.message) || error) };
              }
            } else if (step.kind === 'socket') {
              if (typeof step.payload !== 'string' || step.payload.indexOf('uno ') !== 0)
                return { ok: false, reason: 'invalid-step' };
              try {
                window.app.socket.sendMessage(step.payload);
              } catch (error) {
                return { ok: false, reason: 'dispatch-failed',
                         message: String((error && error.message) || error) };
              }
            } else if (step.kind === 'selectPart') {
              if (typeof map.setPart !== 'function' || !Number.isInteger(step.index) || step.index < 0)
                return { ok: false, reason: 'select-part-unsupported' };
              try {
                map.setPart(step.index);
              } catch (error) {
                return { ok: false, reason: 'dispatch-failed',
                         message: String((error && error.message) || error) };
              }
            } else {
              return { ok: false, reason: 'invalid-step' };
            }
          }
        }
        window.__floeOfficeCommandToken += 1;
        window.__floeOfficeCommandLast = {
          token: window.__floeOfficeCommandToken,
          before: before,
          names: names,
          listener: listener === true,
        };
        return { ok: true, token: window.__floeOfficeCommandToken };
      };

      window.__floeOfficeCommandFreshState = (token) => {
        const last = window.__floeOfficeCommandLast;
        if (!last || last.token !== token)
          return { known: false, fresh: [] };
        const fresh = [];
        for (const name of last.names) {
          const before = last.before[name] || 0;
          const seq = window.__floeOfficeCommandEventSeq[name] || 0;
          if (seq > before) fresh.push(name);
        }
        return { known: last.listener === true, fresh: fresh };
      };

    })();
    """#
}

/// Weak registry of live Office engine sessions, keyed by canonical workspace
/// root + relative path. The editor surface registers its session so the
/// shared command center can reach exactly that live document (and refuse
/// another task); the reference is weak, so a released session cannot block.
@MainActor
final class OfficeLiveSessionRegistry {
    static let shared = OfficeLiveSessionRegistry()

    private struct Entry { weak var session: OfficeFileSession? }
    private var entries: [String: Entry] = [:]

    static func key(root: URL?, relativePath: String) -> String {
        let path = root?.standardizedFileURL.resolvingSymlinksInPath().path ?? ""
        return "\(path)|\(relativePath)"
    }

    func register(session: OfficeFileSession, root: URL?, relativePath: String) {
        entries[Self.key(root: root, relativePath: relativePath)] = Entry(session: session)
    }

    func unregister(session: OfficeFileSession, root: URL?, relativePath: String) {
        let key = Self.key(root: root, relativePath: relativePath)
        if entries[key]?.session === session { entries[key] = nil }
    }

    func session(root: URL?, relativePath: String) -> OfficeFileSession? {
        entries[Self.key(root: root, relativePath: relativePath)]?.session
    }
}
#endif
