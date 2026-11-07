// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// Library rows, recent items and grids share the read-only original preview.
/// Recycled cells are fenced by the record identity and revision.
struct PersonalLibraryCover: View {
    let record: PersonalContentRecord
    var body: some View {
        PersonalContentPreviewView(record: record)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}
#endif
