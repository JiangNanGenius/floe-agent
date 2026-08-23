// FloeApp — Collapsible step-group row for the unified timeline.
//
// Groups consecutive reasoning/tool events between two text messages into
// one collapsible card. Only the latest group is expanded by default; history
// groups collapse to a single summary row so long runs stay readable.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence

struct StepGroupView: View {
    let events: [RunEventRecord]
    let isLatest: Bool
    let isLive: Bool
    let hasError: Bool
    @State private var isExpanded: Bool

    init(events: [RunEventRecord], isLatest: Bool, isLive: Bool, hasError: Bool) {
        self.events = events
        self.isLatest = isLatest
        self.isLive = isLive
        self.hasError = hasError
        // Keep the transcript readable while tools stream: the newest group
        // updates this summary row instead of expanding every event inline.
        self._isExpanded = State(initialValue: false)
    }

    private var summary: String {
        let count = events.count
        let lastTool = events.last(where: { $0.kind == .toolRequest || $0.kind == .toolResult })
        let lastName = lastTool.map { decodePayload($0.payloadJSON)["name"] ?? "工具" } ?? "思考"
        let status = lastTool.map { decodePayload($0.payloadJSON)["status"] ?? "" } ?? ""
        return "\(count) 个步骤 · 最后：\(lastName)\(status.isEmpty ? "" : " (\(status))")"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { event in
                        ThreadEventView(
                            event: event,
                            isLive: isLive,
                            hasError: hasError,
                            onRetry: nil
                        )
                    }
                }
                .padding(.leading, 8)
            }
        } label: {
            HStack {
                Text(summary)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
        }
        .padding(.vertical, 2)
    }

    private func decodePayload(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
#endif
