#if canImport(UIKit)
import SwiftUI
import PDFKit
import Combine

extension Notification.Name {
    /// Posted after any PDF tool commits a document, so an open reader can
    /// refresh in near-real-time instead of waiting for its poll interval.
    static let floePDFDocumentDidChange = Notification.Name("org.floeagent.pdf-document-did-change")
}

/// Both presentation sizes share one document and reading position. The
/// document is never decoded as text and PDF passwords never leave this view.
@MainActor
final class PDFReadingSession: ObservableObject {
    @Published var document: PDFDocument?
    @Published var error: String?
    @Published var locked = false
    @Published var fullScreen = false
    weak var activeView: PDFView?
    var pageIndex = 0
    var pagePoint = CGPoint.zero
    var scale: CGFloat?
    private var modificationDate: Date?
    private var byteCount: Int?

    func capture() {
        guard let view = activeView, let page = view.currentPage, let document else { return }
        pageIndex = document.index(for: page)
        pagePoint = view.currentDestination?.point ?? .zero
        scale = view.scaleFactor
    }

    func load(_ url: URL, force: Bool = false, validateRead: (() throws -> Void)? = nil) async {
        do {
            try validateRead?()
            var freshURL = url
            freshURL.removeAllCachedResourceValues()
            let info = try freshURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard force || document == nil || info.contentModificationDate != modificationDate
                    || info.fileSize != byteCount else { return }
            guard (info.fileSize ?? 0) <= 64 * 1024 * 1024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            // Read bytes off the main thread, but build the document on the
            // MainActor: this PDFDocument is owned by PDFView and must never
            // migrate threads (the previous background-built handoff was a
            // top crash candidate). Tool edits use separate, gated documents.
            let bytes = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            try Task.checkCancellation()
            let loaded = try withPDFExceptionGuard { PDFDocument(data: bytes) }
            guard let loaded else { throw CocoaError(.fileReadCorruptFile) }
            capture()
            modificationDate = info.contentModificationDate
            byteCount = info.fileSize
            error = nil
            locked = loaded.isLocked
            document = loaded
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct InlinePDFReader: View {
    let url: URL
    var validateRead: (() throws -> Void)? = nil
    @StateObject private var session = PDFReadingSession()
    @State private var expanded = false
    @State private var password = ""
    @State private var wrongPassword = false

    var body: some View {
        reader(inFullScreen: false)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.capture()
                        session.fullScreen = true
                        expanded = true
                    } label: {
                        Label("pdf.reader.expand", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(session.document == nil || session.locked)
                    .accessibilityIdentifier("pdf.reader.expand")
                }
            }
            .task(id: url) {
                await session.load(url, force: true, validateRead: validateRead)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                    await session.load(url, validateRead: validateRead)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .floePDFDocumentDidChange)) { notification in
                guard let changed = notification.object as? URL, changed == url else { return }
                Task { await session.load(url, force: true, validateRead: validateRead) }
            }
            .fullScreenCover(isPresented: $expanded, onDismiss: { password = ""; session.fullScreen = false }) {
                NavigationStack {
                    reader(inFullScreen: true)
                        .navigationTitle(url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("action.done") {
                                    session.capture()
                                    session.fullScreen = false
                                    expanded = false
                                }
                                .accessibilityIdentifier("pdf.reader.collapse")
                            }
                        }
                }
            }
    }

    @ViewBuilder private func reader(inFullScreen: Bool) -> some View {
        if let error = session.error {
            ContentUnavailableView {
                Label("inspector.preview.error", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("pdf.reader.retry") { Task { await session.load(url, force: true, validateRead: validateRead) } }
            }
        } else if session.locked {
            VStack(spacing: 16) {
                Image(systemName: "lock.doc").font(.largeTitle)
                SecureField("pdf.reader.password", text: $password)
                    .textFieldStyle(.roundedBorder)
                if wrongPassword { Text("pdf.reader.wrong_password").foregroundStyle(.red) }
                Button("pdf.reader.unlock") {
                    let unlocked = session.document?.unlock(withPassword: password) == true
                    password = ""
                    wrongPassword = !unlocked
                    session.locked = !unlocked
                }.buttonStyle(.borderedProminent)
            }.padding().frame(maxWidth: 360)
        } else if session.document != nil {
            PDFReadingSurface(session: session, presentationID: inFullScreen)
                .accessibilityIdentifier("pdf.reader.document")
        } else {
            ProgressView("inspector.preview.loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PDFReadingSurface: UIViewRepresentable {
    @ObservedObject var session: PDFReadingSession
    let presentationID: Bool

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard presentationID == session.fullScreen else { return }
        let changed = view.document !== session.document
        let restored = session.activeView !== view
        guard changed || restored else { return }
        view.document = session.document
        context.coordinator.presentationID = presentationID
        if let page = session.document?.page(at: min(session.pageIndex, max(0, (session.document?.pageCount ?? 1) - 1))) {
            view.layoutIfNeeded()
            if let scale = session.scale {
                view.scaleFactor = scale
                view.go(to: PDFDestination(page: page, at: session.pagePoint))
            } else { view.go(to: page) }
        }
        session.activeView = view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var presentationID: Bool? }
}
#endif
