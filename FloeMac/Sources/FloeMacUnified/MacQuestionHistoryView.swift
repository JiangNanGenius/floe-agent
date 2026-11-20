// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeModels

struct MacQuestionHistoryView: View {
    let requests: [UserQuestionWaitingSnapshot]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(requests, id: \.requestID) { request in
                    ForEach(request.questions, id: \.questionID) { question in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: question.text).fontWeight(.semibold)
                            if let record = question.answerRecord() {
                                let parts = record.selectedOptionLabels + [record.customText, record.freeText].compactMap { $0 }
                                Text(verbatim: parts.joined(separator: " · ")).textSelection(.enabled)
                                if record.source == .deadlineDefault { Text("mac.question.provenance.default").foregroundStyle(.secondary) }
                            } else if question.status == .cancelled {
                                Text("mac.question.cancelled").foregroundStyle(.secondary)
                            } else if question.status == .expired {
                                Text("mac.question.expired").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("mac.question.history", systemImage: "questionmark.bubble")
        }
        .font(.callout)
        .accessibilityIdentifier("mac.question.history")
    }
}
