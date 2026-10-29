// FloeProviders — Server-Sent Events event value type.

import Foundation

/// One fully-assembled SSE event, per the WHATWG SSE specification.
public struct SSEEvent: Sendable, Codable, Hashable {
    /// Value of the `event:` field; empty string means the default
    /// "message" event type.
    public var event: String
    /// Concatenated `data:` fields, joined by "\n".
    public var data: String
    /// Value of the `id:` field; nil when absent.
    public var id: String?
    /// Reconnection delay in milliseconds from the `retry:` field.
    public var retry: Int?

    public init(event: String = "", data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}
