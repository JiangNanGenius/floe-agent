// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeGISKit

/// The qualified GIS native panels own their split-view chrome.
struct GISProjectEditorSurface: View {
    @Bindable var session: GISProjectSession
    let onClose: () -> Void
    let onAssistant: () -> Void
    var body: some View {
        GISEditorView(controller: session.controller, onClose: onClose)
            .onAppear { session.controller.onAssistant = onAssistant }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !session.exportURLs.isEmpty || session.listingError != nil {
                    VStack(alignment: .leading, spacing: 5) {
                        if let error = session.listingError { Text(error).font(.caption).foregroundStyle(.secondary) }
                        if !session.exportURLs.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 12) {
                                    ForEach(session.exportURLs, id: \.self) { file in
                                        ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "square.and.arrow.up").lineLimit(1).frame(minHeight: 44) }
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal, 12).background(.bar)
                }
            }
    }
}
#endif
