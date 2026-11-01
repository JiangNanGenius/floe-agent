import Foundation

public struct BridgeRPCParamDef: Sendable, Equatable, Codable {
    public let name: String
    public let type: String
    public let required: Bool
    public let description: String

    public init(name: String, type: String, required: Bool, description: String) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
    }
}

public enum BridgeRPCMethodClass: String, Sendable, Codable {
    /// Reads the screen, device or app state. May still be slow, but does not
    /// deliberately change app content.
    case read
    /// Ordinary control allowed to a paired client: tap, launch, navigate.
    case control
    /// App input (typing, clearing a focused field). Ordinary input is always
    /// available to a paired client; the executor separately checks the
    /// per-client owner grant only when the resolved target is a third-party
    /// secure field.
    case input
    /// Service-level management. RPC writes that escalate network/permission
    /// state are refused; the owner UI owns those transitions.
    case service
}

public struct BridgeRPCMethodDef: Sendable, Equatable {
    public let name: String
    public let description: String
    public let params: [BridgeRPCParamDef]
    public let returns: String
    public let methodClass: BridgeRPCMethodClass

    public init(name: String,
                description: String,
                params: [BridgeRPCParamDef],
                returns: String,
                methodClass: BridgeRPCMethodClass) {
        self.name = name
        self.description = description
        self.params = params
        self.returns = returns
        self.methodClass = methodClass
    }
}

/// The 33 method definitions retained from the pinned OpenMinis/iCTRL schema.
/// Names and parameter names/types are preserved for existing automation,
/// read, OCR, screenshot, gesture, app and media clients. The implementations
/// arrive with the engine package; until then those methods are reported as
/// not available (never as fake success).
public enum BridgeRPCMethodRegistry {
    public static let methods: [BridgeRPCMethodDef] = [
        BridgeRPCMethodDef(
            name: "config",
            description: "Read the Bridge configuration and authorized client list. Network opening and permission administration are owner-UI only; such writes are refused here.",
            params: [
                BridgeRPCParamDef(name: "allow_remote_access", type: "boolean", required: false, description: "Owner UI only; refused over RPC."),
                BridgeRPCParamDef(name: "listen_port", type: "number", required: false, description: "Owner UI only; refused over RPC."),
                BridgeRPCParamDef(name: "revoke_session_id", type: "string", required: false, description: "Owner UI only; refused over RPC."),
                BridgeRPCParamDef(name: "clear_sessions", type: "boolean", required: false, description: "Owner UI only; refused over RPC."),
                BridgeRPCParamDef(name: "nearby_discovery", type: "boolean", required: false, description: "Owner UI only; refused over RPC. No AWDL/peer-to-peer listener exists."),
                BridgeRPCParamDef(name: "device_name", type: "string", required: false, description: "Owner UI only; refused over RPC."),
                BridgeRPCParamDef(name: "stop_server", type: "boolean", required: false, description: "Stop the Bridge listeners after replying. Client keys persist."),
            ],
            returns: "{port, lan_enabled, lan_available, engine, capabilities, clients:[{client_id, client_name, granted_at, last_active_at, expires_at, last_address, last_via, sensitive_input_granted}], stopping}",
            methodClass: .service
        ),
        BridgeRPCMethodDef(
            name: "stream_ticket",
            description: "Mint a single-use, short-lived ticket for GET /stream or /logs. Those byte channels cannot carry an encrypted envelope, so they present this ticket instead.",
            params: [],
            returns: "{ticket, expires_in, hint}",
            methodClass: .service
        ),
        BridgeRPCMethodDef(
            name: "device_info",
            description: "Device, coordinate space and Bridge identity. Actual device metrics arrive with the engine implementation.",
            params: [],
            returns: "{point_width, point_height, pixel_width, pixel_height, scale, server_version, protocol_version, capabilities, hint}",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "page_source",
            description: "Read the accessibility/view hierarchy as text.",
            params: [
                BridgeRPCParamDef(name: "bundle_id", type: "string", required: false, description: "Inspect this app; omit for the foreground app."),
                BridgeRPCParamDef(name: "filter", type: "object", required: false, description: "Return matching nodes and ancestors."),
                BridgeRPCParamDef(name: "max_depth", type: "number", required: false, description: "Maximum tree depth."),
                BridgeRPCParamDef(name: "max_elements", type: "number", required: false, description: "Maximum nodes to return."),
                BridgeRPCParamDef(name: "max_children", type: "number", required: false, description: "Maximum children walked per node."),
                BridgeRPCParamDef(name: "enhanced", type: "boolean", required: false, description: "Whole tree plus OCR-only text."),
                BridgeRPCParamDef(name: "visible_only", type: "boolean", required: false, description: "Only nodes intersecting the screen."),
            ],
            returns: "{source, truncated, total_returned, coordinate_space, channel, hint}",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "screen_text",
            description: "OCR the screen into text boxes usable for coordinate taps.",
            params: [
                BridgeRPCParamDef(name: "element_id", type: "string", required: false, description: "Only results containing this substring."),
                BridgeRPCParamDef(name: "match", type: "string", required: false, description: "'fast' or accurate recognition."),
                BridgeRPCParamDef(name: "scale", type: "number", required: false, description: "Minimum confidence 0..1."),
            ],
            returns: "{count, items, overlay_text?, coordinate_space, hint}",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "logs",
            description: "Recent redacted server log lines over the encrypted RPC channel. Answers while UI automation is busy.",
            params: [
                BridgeRPCParamDef(name: "text", type: "string", required: false, description: "Only lines containing this substring."),
                BridgeRPCParamDef(name: "max_elements", type: "number", required: false, description: "How many lines to return (default 80, max 500)."),
            ],
            returns: "{lines, count, total, hint}",
            methodClass: .service
        ),
        BridgeRPCMethodDef(
            name: "reset",
            description: "Clear cached element refs and recover the automation channel. It does not start or restart the engine by itself.",
            params: [],
            returns: "{reset, cleared_refs, hint}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "screenshot",
            description: "Capture a screenshot as bounded base64 JPEG or PNG, inside the encrypted JSON reply.",
            params: [
                BridgeRPCParamDef(name: "scale", type: "number", required: false, description: "Pixels per point (default 2, max 3)."),
                BridgeRPCParamDef(name: "bundle_id", type: "string", required: false, description: "Crop to this app."),
                BridgeRPCParamDef(name: "format", type: "string", required: false, description: "'jpeg' (default) or 'png'."),
                BridgeRPCParamDef(name: "quality", type: "number", required: false, description: "JPEG quality 0.1..1.0."),
            ],
            returns: "{data, format, bytes, pixel_width, pixel_height, point_width, point_height, scale, scope, hint}",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "tap",
            description: "Tap by stable ref or by x/y points.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "ref", type: "string", required: false, description: "Element ref."),
                BridgeRPCParamDef(name: "x", type: "number", required: false, description: "X in points."),
                BridgeRPCParamDef(name: "y", type: "number", required: false, description: "Y in points."),
                BridgeRPCParamDef(name: "fast", type: "boolean", required: false, description: "Use the synthesized fast path."),
            ],
            returns: "{message, screen}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "double_tap",
            description: "Double tap by ref or x/y.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "ref", type: "string", required: false, description: "Element ref."),
                BridgeRPCParamDef(name: "x", type: "number", required: false, description: "X in points."),
                BridgeRPCParamDef(name: "y", type: "number", required: false, description: "Y in points."),
            ],
            returns: "{message, screen}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "long_press",
            description: "Long press by ref or x/y.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "ref", type: "string", required: false, description: "Element ref."),
                BridgeRPCParamDef(name: "x", type: "number", required: false, description: "X in points."),
                BridgeRPCParamDef(name: "y", type: "number", required: false, description: "Y in points."),
                BridgeRPCParamDef(name: "duration", type: "number", required: false, description: "Press duration in seconds."),
            ],
            returns: "{message, screen}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "swipe",
            description: "Low-level swipe gesture.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "x", type: "number", required: false, description: "Start X."),
                BridgeRPCParamDef(name: "y", type: "number", required: false, description: "Start Y."),
                BridgeRPCParamDef(name: "direction", type: "string", required: false, description: "up/down/left/right."),
                BridgeRPCParamDef(name: "distance", type: "number", required: false, description: "Finger travel in points."),
                BridgeRPCParamDef(name: "velocity", type: "string", required: false, description: "fast/flick, normal, slow/precise."),
                BridgeRPCParamDef(name: "fast", type: "boolean", required: false, description: "Use the synthesized fast path."),
            ],
            returns: "{message, from, velocity, note}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "page",
            description: "Scroll by one screenful without momentum.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "direction", type: "string", required: false, description: "'down' (default) or 'up'."),
                BridgeRPCParamDef(name: "distance", type: "number", required: false, description: "Number of screenfuls."),
            ],
            returns: "{message, screen, moved, position?, at_end?, hint?}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "collect",
            description: "Read a long list in one call by paging and reading repeatedly.",
            params: [
                BridgeRPCParamDef(name: "pages", type: "integer", required: false, description: "Page moves after the first read (default 3, max 8)."),
                BridgeRPCParamDef(name: "direction", type: "string", required: false, description: "'down' (default) or 'up'."),
                BridgeRPCParamDef(name: "min_length", type: "integer", required: false, description: "Skip shorter labels."),
                BridgeRPCParamDef(name: "fresh", type: "boolean", required: false, description: "Forget earlier collect results."),
                BridgeRPCParamDef(name: "source", type: "string", required: false, description: "'auto', 'tree' or 'ocr'."),
            ],
            returns: "{items, new_count, screens_read, at_end, elapsed_ms, hint}",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "scroll_to_element",
            description: "Scroll until an element is in view, then return a stable ref.",
            params: [
                BridgeRPCParamDef(name: "element_id", type: "string", required: true, description: "Accessibility label or identifier."),
                BridgeRPCParamDef(name: "match", type: "string", required: false, description: "'exact' or 'contains'."),
                BridgeRPCParamDef(name: "element_type", type: "string", required: false, description: "Element type filter."),
                BridgeRPCParamDef(name: "direction", type: "string", required: false, description: "Search direction."),
                BridgeRPCParamDef(name: "distance", type: "number", required: false, description: "Maximum scroll moves."),
                BridgeRPCParamDef(name: "bundle_id", type: "string", required: false, description: "App to search."),
            ],
            returns: "{found, swipes, ref, x, y, center_x, center_y, label, visibility, hint}",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "scroll",
            description: "Deprecated coarse full-screen scroll; use swipe or page.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "direction", type: "string", required: false, description: "up/down/left/right."),
            ],
            returns: "{message}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "type",
            description: "Type text into the focused field. Ordinary input is available to a paired client; the executor checks the owner grant only for a third-party secure field.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "text", type: "string", required: true, description: "Text to type (optional if clear:true)."),
                BridgeRPCParamDef(name: "clear", type: "boolean", required: false, description: "Empty the field before typing."),
                BridgeRPCParamDef(name: "submit", type: "boolean", required: false, description: "Press Return/Search after typing."),
                BridgeRPCParamDef(name: "x", type: "number", required: false, description: "Tap X to focus first."),
                BridgeRPCParamDef(name: "y", type: "number", required: false, description: "Tap Y to focus first."),
                BridgeRPCParamDef(name: "fast", type: "boolean", required: false, description: "Use fast mode."),
                BridgeRPCParamDef(name: "via", type: "string", required: false, description: "'keyboard' to tap on-screen keys."),
            ],
            returns: "{message, via?, note?, warning?}",
            methodClass: .input
        ),
        BridgeRPCMethodDef(
            name: "clear_text",
            description: "Empty the focused text field. Ordinary input is available to a paired client; the executor checks the owner grant only for a third-party secure field.",
            params: [],
            returns: "{message, warning?}",
            methodClass: .input
        ),
        BridgeRPCMethodDef(
            name: "home",
            description: "Press Home and verify SpringBoard is frontmost.",
            params: [],
            returns: "{message, foreground_app, previous_app}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "lock",
            description: "Lock the screen.",
            params: [],
            returns: "{message}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "unlock",
            description: "Wake the screen by pressing Home. Never enters a passcode.",
            params: [],
            returns: "{message}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "is_locked",
            description: "Check whether the screen is locked.",
            params: [],
            returns: "boolean",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "list_apps",
            description: "List installed apps, or the opened-history fallback on newer iOS.",
            params: [
                BridgeRPCParamDef(name: "text", type: "string", required: false, description: "Name or bundle id substring."),
                BridgeRPCParamDef(name: "element_type", type: "string", required: false, description: "'all' to include system apps."),
            ],
            returns: "{count, source, apps, hint}",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "resolve_app",
            description: "Resolve an app name or keyword to a bundle id.",
            params: [
                BridgeRPCParamDef(name: "text", type: "string", required: true, description: "Name/keyword, several separated by |."),
                BridgeRPCParamDef(name: "country", type: "string", required: false, description: "App Store region."),
                BridgeRPCParamDef(name: "distance", type: "number", required: false, description: "Maximum results."),
            ],
            returns: "{count, term, source, apps, hint}",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "open_url",
            description: "Open a URL, app scheme or deep link.",
            params: [
                BridgeRPCParamDef(name: "url", type: "string", required: true, description: "The URL to open."),
            ],
            returns: "{message}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "launch_app",
            description: "Open an app by bundle id.",
            params: [
                BridgeRPCParamDef(name: "bundle_id", type: "string", required: true, description: "App bundle identifier."),
            ],
            returns: "{message, hint}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "activate_app",
            description: "Bring an installed app to the foreground.",
            params: [
                BridgeRPCParamDef(name: "bundle_id", type: "string", required: true, description: "App bundle identifier."),
            ],
            returns: "{message}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "terminate_app",
            description: "Terminate a running app.",
            params: [
                BridgeRPCParamDef(name: "bundle_id", type: "string", required: true, description: "App bundle identifier."),
            ],
            returns: "{message}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "find_element",
            description: "Find an element by label or identifier and return a stable ref.",
            params: [
                BridgeRPCParamDef(name: "element_id", type: "string", required: true, description: "Accessibility label or identifier."),
                BridgeRPCParamDef(name: "match", type: "string", required: false, description: "'exact' or 'contains'."),
                BridgeRPCParamDef(name: "element_type", type: "string", required: false, description: "Element type filter."),
                BridgeRPCParamDef(name: "bundle_id", type: "string", required: false, description: "App to search."),
            ],
            returns: "{exists, hittable, ref, element_type, is_text_input, x, y, width, height, center_x, center_y, label, value, note?}",
            methodClass: .read
        ),
        BridgeRPCMethodDef(
            name: "tap_element",
            description: "Find an element and tap it in one call.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "element_id", type: "string", required: true, description: "Accessibility label or identifier."),
                BridgeRPCParamDef(name: "match", type: "string", required: false, description: "'exact' or 'contains'."),
                BridgeRPCParamDef(name: "element_type", type: "string", required: false, description: "Element type filter."),
            ],
            returns: "{message}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "find_and_tap",
            description: "Locate an element and tap it, with a native-tap fallback.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "element_id", type: "string", required: true, description: "Accessibility label or identifier."),
                BridgeRPCParamDef(name: "match", type: "string", required: false, description: "'exact' or 'contains'."),
                BridgeRPCParamDef(name: "element_type", type: "string", required: false, description: "Element type filter."),
                BridgeRPCParamDef(name: "bundle_id", type: "string", required: false, description: "Target app."),
                BridgeRPCParamDef(name: "fast", type: "boolean", required: false, description: "false uses the native tap pipeline."),
            ],
            returns: "{message, matched, frame}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "drag",
            description: "One uninterrupted single-finger drag along endpoints or a point path.",
            params: [
                BridgeRPCParamDef(name: "settle", type: "boolean", required: false, description: "Wait for the screen to settle."),
                BridgeRPCParamDef(name: "settle_timeout", type: "number", required: false, description: "Maximum settle wait in seconds."),
                BridgeRPCParamDef(name: "points", type: "array", required: false, description: "2..64 {x,y} points."),
                BridgeRPCParamDef(name: "from_ref", type: "string", required: false, description: "Start element ref."),
                BridgeRPCParamDef(name: "to_ref", type: "string", required: false, description: "End element ref."),
                BridgeRPCParamDef(name: "from_x", type: "number", required: false, description: "Start X."),
                BridgeRPCParamDef(name: "from_y", type: "number", required: false, description: "Start Y."),
                BridgeRPCParamDef(name: "to_x", type: "number", required: false, description: "End X."),
                BridgeRPCParamDef(name: "to_y", type: "number", required: false, description: "End Y."),
                BridgeRPCParamDef(name: "duration", type: "number", required: false, description: "Duration in seconds."),
            ],
            returns: "{message, screen}",
            methodClass: .control
        ),
        BridgeRPCMethodDef(
            name: "wait",
            description: "Pause for a fixed duration. Prefer settle reporting for ordinary actions.",
            params: [
                BridgeRPCParamDef(name: "duration", type: "number", required: false, description: "Duration in seconds."),
            ],
            returns: "{message}",
            methodClass: .control
        ),
    ]

    public static let methodNames: Set<String> = Set(methods.map(\.name))

    public static func method(named name: String) -> BridgeRPCMethodDef? {
        methods.first { $0.name == name }
    }

    /// Capability names are method names plus stable core features. Nothing is
    /// advertised for a method the registry did not report as implemented.
    public static func capabilities(supportedEngineMethods: Set<String>,
                                    logsAvailable: Bool,
                                    streamAvailable: Bool,
                                    lanAvailable: Bool) -> [String] {
        var result: Set<String> = [
            "envelope_v1",
            "jsonrpc_2.0",
            "schema",
            "dual_loopback",
            "config",
        ]
        if logsAvailable {
            result.insert("logs")
            result.insert("nonui_lane")
        }
        if streamAvailable {
            result.insert("stream")
            result.insert("stream_ticket")
        }
        if lanAvailable {
            result.insert("lan_optional")
        }
        for name in supportedEngineMethods where methodNames.contains(name) {
            result.insert(name)
        }
        return result.sorted()
    }

    public static func generateJSONSchema(supportedEngineMethods: Set<String>,
                                          availableServiceMethods: Set<String>,
                                          capabilities: [String]) -> [String: BridgeRPCJSONValue] {
        let methodValues: [BridgeRPCJSONValue] = methods.map { method in
            .object([
                "name": .string(method.name),
                "description": .string(method.description),
                "params": .array(method.params.map { parameter in
                    .object([
                        "name": .string(parameter.name),
                        "type": .string(parameter.type),
                        "required": .bool(parameter.required),
                        "description": .string(parameter.description),
                    ])
                }),
                "returns": .string(method.returns),
                "available": .bool(supportedEngineMethods.contains(method.name)
                                   || availableServiceMethods.contains(method.name)),
            ])
        }
        return [
            "protocol": .string("JSON-RPC 2.0"),
            "server_version": .string(BridgeRPCVersion.serverVersion),
            "skill_version": .string(BridgeRPCVersion.skillVersion),
            "protocol_version": .int(BridgeRPCVersion.protocolVersion),
            "capability_tags": .array(capabilities.map { .string($0) }),
            "transport": .string("localhost-first HTTP on 127.0.0.1 and ::1; optional normal-LAN listener"),
            "endpoints": .object([
                "info": .string("GET /"),
                "schema": .string("GET /schema"),
                "skill": .string("GET /skill and GET /skill.md"),
                "pair": .string("POST /pair {client_name, plain:true | pub:<raw 32B X25519 base64>}"),
                "rpc": .string("POST /rpc with a v1 encrypted envelope"),
                "stream": .string("GET /stream[.ts]?ticket=<t>"),
                "logs": .string("GET /logs, /logs/files, /logs/history?ticket=<t>"),
                "remote": .string("GET /remote (self-contained browser control page)"),
            ]),
            "methods": .array(methodValues),
            "limits": .object([
                "request_body_bytes": .int(BridgeRPCLimits.default.maxRequestBodyBytes),
                "encrypted_json_response_bytes": .int(BridgeRPCLimits.default.maxJSONResponseBytes),
                "connections": .int(BridgeRPCLimits.default.maxConnections),
                "queued_automation_calls": .int(BridgeRPCLimits.default.maxQueuedAutomationCalls),
            ]),
        ]
    }
}
