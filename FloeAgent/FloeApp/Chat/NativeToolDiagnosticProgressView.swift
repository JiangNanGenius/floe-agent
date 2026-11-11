// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI)
import SwiftUI
import FloeTools

struct NativeToolDiagnosticViewScope: Sendable {
    let conversationID: UUID?
    let runID: UUID?
    let observations: [String: [TaskDiagnosticProgress]]
    static let empty = Self(conversationID: nil, runID: nil, observations: [:])
    func values(conversationID: UUID?, runID: UUID, callID: String?) -> [TaskDiagnosticProgress] {
        guard let conversationID, conversationID == self.conversationID,
              runID == self.runID, let callID else { return [] }
        return observations[callID] ?? []
    }
}
private struct NativeToolDiagnosticsKey: EnvironmentKey {
    static let defaultValue = NativeToolDiagnosticViewScope.empty
}
extension EnvironmentValues {
    var nativeToolDiagnostics: NativeToolDiagnosticViewScope {
        get { self[NativeToolDiagnosticsKey.self] }
        set { self[NativeToolDiagnosticsKey.self] = newValue }
    }
}
struct NativeTracerouteProgressView: View {
    let observations: [TaskDiagnosticProgress]
    @Environment(\.locale) private var locale
    private var chinese: Bool { locale.language.languageCode?.identifier == "zh" }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(observations.filter { $0.ttl != nil }, id: \.ttl) { value in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(value.ttl ?? 0) · \(value.address ?? "*")")
                    Spacer(minLength: 8)
                    switch value.status {
                    case .timeout: Text(chinese ? "超时" : "Timeout")
                    case .unreachable: Text(chinese ? "无法到达" : "Unreachable")
                    default: Text(value.milliseconds.map { String(format: "%.2f ms", $0) }.joined(separator: " · "))
                    }
                }.font(.caption).monospacedDigit().textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("network.traceroute.hops")
    }
}
#endif
