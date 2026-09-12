//
//  TranscriptSegmentRow.swift
//  VideoEditorKit
//
//  Created by Codex on 06.04.2026.
//

import SwiftUI

struct TranscriptSegmentRow: View {

    // MARK: - Public Properties

    let segment: EditableTranscriptSegment

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(segmentTimeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)

            Text(segment.editedText)
                .font(.subheadline)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if segment.isEdited {
                Text(VideoEditorStrings.edited)
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Private Properties

    private var segmentTimeLabel: String {
        "\(formattedTime(segment.timeMapping.sourceStartTime)) - \(formattedTime(segment.timeMapping.sourceEndTime))"
    }

    // MARK: - Private Methods

    private func formattedTime(_ value: Double) -> String {
        value.formatterTimeString()
    }

}

#Preview {
    TranscriptSegmentRow(
        segment: EditableTranscriptSegment(
            id: UUID(),
            timeMapping: TranscriptTimeMapping(
                sourceStartTime: 0,
                sourceEndTime: 5.2
            ),
            originalText: "Hello world, this is a sample transcript segment.",
            editedText: "Hello world, this is a sample transcript segment."
        )
    )
    .padding()
}
