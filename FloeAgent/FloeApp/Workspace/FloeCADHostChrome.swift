// SPDX-License-Identifier: MPL-2.0
// FloeApp — shared Floe-level chrome for the native `.floecad` workbench.
//
// The FilePreview host and the qualification fixture must present the SAME
// Floe-level surface around the imported editor (CUA 2026-10-10: the fixture
// previously showed only imported-editor controls, so acceptance could not
// see the production chrome). This modifier is that shared surface:
//
//   * Save status — an explicit save control with an honest outcome line
//     (the package also autosaves on background/release; this button is the
//     user-visible commit + status).
//   * Fullscreen — the same expansion the 2D engineering preview has, with
//     a Done return that keeps the live session (sizing transition, no
//     discard).
//
// The proposal banner, Canvas actions and assistant entry stay host-owned:
// the banner and Canvas actions appear in the real preview; the fixture has
// no assistant/Canvas by design.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCAD

@MainActor
struct FloeCADHostChrome: ViewModifier {
    let document: FloeCADDocument
    var canvasActions: CADCanvasActions? = nil

    @State private var saving = false
    @State private var saveOutcome: String?
    @State private var fullScreen = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        Label(saving
                              ? FloeCADStrings.text("cad.host.saving", "Saving…")
                              : FloeCADStrings.text("cad.host.save", "Save"),
                              systemImage: saving ? "arrow.triangle.2.circlepath" : "tray.and.arrow.down")
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("cad.host.save")
                    Button {
                        fullScreen = true
                    } label: {
                        Label(FloeCADStrings.text("engineering.fullscreen", "Full Screen"),
                              systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityIdentifier("cad.host.fullscreen")
                }
            }
            .fullScreenCover(isPresented: $fullScreen) {
                NavigationStack {
                    FloeCADWorkbenchView(document: document, canvasActions: canvasActions)
                        .navigationTitle(document.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(FloeCADStrings.text("engineering.done", "Done")) {
                                    fullScreen = false
                                }
                                .accessibilityIdentifier("cad.host.done")
                            }
                        }
                }
                // Same sizing-transition rule as the 2D fullscreen: the live
                // session (including unsaved edits) is re-adopted on return.
            }
            .overlay(alignment: .top) {
                if let saveOutcome {
                    Text(saveOutcome)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.bar, in: Capsule())
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("cad.host.saveOutcome")
                }
            }
            .task(id: saveOutcome) {
                guard saveOutcome != nil else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    withAnimation { saveOutcome = nil }
                }
            }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let outcome = await document.save()
        saveOutcome = outcome.error
            ?? FloeCADStrings.text("cad.host.saved", "Saved")
    }
}
#endif
