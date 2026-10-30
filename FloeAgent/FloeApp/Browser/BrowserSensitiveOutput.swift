// FloeApp — safe encoding for explicit browser-session value reads.
//
// Raw cookie/storage values belong only in ToolExecutionOutput's
// `ephemeralSensitiveOutput` (immediate model request, never captured or
// persisted). The ordinary summary and its digest always use this sanitized
// copy, so even an accidental summary capture cannot contain the values.

#if canImport(SwiftUI) && canImport(WebKit)
import Foundation

enum BrowserSensitiveOutput {
    static let redactionMarker = "[redacted browser session value]"

    static func encodedSummary(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
