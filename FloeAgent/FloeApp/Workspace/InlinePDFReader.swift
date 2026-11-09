#if canImport(UIKit)
import SwiftUI
import PDFKit
import Combine

/// PDF points measured from the top-left, with one-based page numbers.
struct PDFReadingDestination:Equatable {let page:Int;let x:Double;let y:Double}

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
    @Published var destination:PDFReadingDestination?
    weak var activeView: PDFView?
    var pageIndex = 0
    var pagePoint = CGPoint.zero
    var zoomRelativeToFit: CGFloat?
    private var modificationDate: Date?
    private var byteCount: Int?
    private var loadedURL:URL?
    @Published private(set) var searchDocumentReady=false

    struct SearchKey: Hashable { var query: String; var matchCase: Bool; var revision: UUID }
    @Published var searchVisible = false
    @Published var searchQuery = ""
    @Published var searchMatchCase = false
    @Published private(set) var searchBusy = false
    @Published private(set) var searchCount = 0
    @Published private(set) var searchIndex = -1
    @Published private(set) var searchCapped = false
    @Published private(set) var searchFailure: String?
    @Published private(set) var searchRevision = UUID()
    @Published private(set) var searchNavigation = UUID()
    @Published var documentRevision = UUID()
    private(set) var searchMatches = [PDFSelection]()
    private var searchDocument: PDFDocument?
    private var searchObservers = Set<AnyCancellable>()
    private var activeSearchKey: SearchKey?
    private var searchReadValidation:(() throws -> Void)?
    static let maximumSearchMatches = 1000
    var searchKey: SearchKey { .init(query: searchVisible ? searchQuery : "", matchCase: searchMatchCase, revision: documentRevision) }
    var selectedSearchMatch: PDFSelection? { searchMatches.indices.contains(searchIndex) ? searchMatches[searchIndex] : nil }

    func clearSearch() {
        // Clear identity before cancelling: synchronous or queued old hits
        // cannot attach themselves to the next query or another PDF.
        let previous = searchDocument
        searchDocument = nil; activeSearchKey = nil; searchObservers.removeAll()
        if let previous { try? withPDFExceptionGuard { previous.cancelFindString() } }
        searchBusy = false; searchMatches = []; searchCount = 0; searchIndex = -1
        searchCapped = false; searchFailure = nil; searchRevision = UUID()
    }
    func closeSearch() { searchVisible = false; searchQuery = ""; clearSearch() }
    func beginSearch() {
        let key = searchKey
        do {try searchReadValidation?()} catch {clearSearch();searchFailure=error.localizedDescription;return}
        guard activeSearchKey != key || searchDocument == nil else { return }
        clearSearch()
        guard searchVisible, !key.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document, !locked, error == nil, searchDocumentReady else { return }
        guard key.query.utf16.count <= 1024 else {
            searchFailure = IDELanguageRunText.t("搜索内容过长", "Search text is too long"); return
        }
        do {
            // PDFKit's public asynchronous find stays on the reader's main
            // run loop. A separate copied document fences late notifications;
            // no UI-owned PDF object is transferred to a worker thread.
            let copied = try withPDFExceptionGuard { document.copy() as? PDFDocument }
            guard let copied, copied !== document, !copied.isLocked else {
                searchFailure = IDELanguageRunText.t("暂时无法搜索此 PDF", "This PDF cannot be searched right now"); return
            }
            searchDocument = copied; activeSearchKey = key; searchBusy = true
            NotificationCenter.default.publisher(for: .PDFDocumentDidFindMatch, object: copied)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notice in
                    MainActor.assumeIsolated { self?.receiveSearchMatch(notice) }
                }.store(in: &searchObservers)
            NotificationCenter.default.publisher(for: .PDFDocumentDidEndFind, object: copied)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notice in
                    MainActor.assumeIsolated { self?.finishSearch(notice) }
                }.store(in: &searchObservers)
            try withPDFExceptionGuard { copied.beginFindString(key.query, withOptions: key.matchCase ? [.literal] : [.literal, .caseInsensitive]) }
        } catch {
            clearSearch(); searchFailure = error.localizedDescription
        }
    }
    private func receiveSearchMatch(_ notice: Notification) {
        guard let searched = notice.object as? PDFDocument, searched === searchDocument,
              activeSearchKey == searchKey, searchMatches.count < Self.maximumSearchMatches,
              let found = notice.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection,
              let document else { return }
        do {
            try searchReadValidation?()
            let result = try withPDFExceptionGuard { () -> PDFSelection? in
                let result = PDFSelection(document: document)
                var pieces = 0
                for page in found.pages {
                    let index = searched.index(for: page)
                    guard index != NSNotFound, let target = document.page(at: index) else { continue }
                    for part in 0..<found.numberOfTextRanges(on: page) {
                        let range = found.range(at: part, on: page)
                        guard range.location != NSNotFound, range.length > 0,
                              range.location <= target.numberOfCharacters,
                              range.length <= target.numberOfCharacters - range.location,
                              let selection = target.selection(for: range) else { continue }
                        result.add(selection); pieces += 1
                    }
                }
                guard pieces > 0 else { return nil }
                result.color = UIColor.systemYellow.withAlphaComponent(0.35)
                return result
            }
            guard let result else { return }
            searchMatches.append(result); searchCount = searchMatches.count
            if searchIndex < 0 { searchIndex = 0; searchNavigation = UUID() }
            if searchCount == 1 || searchCount.isMultiple(of: 32) { searchRevision = UUID() }
            if searchCount == Self.maximumSearchMatches {
                searchCapped = true; searchBusy = false; searchRevision = UUID()
                try withPDFExceptionGuard { searched.cancelFindString() }
            }
        } catch {
            clearSearch(); searchFailure = error.localizedDescription
        }
    }
    private func finishSearch(_ notice: Notification) {
        guard let searched = notice.object as? PDFDocument, searched === searchDocument,
              activeSearchKey == searchKey else { return }
        searchBusy = false; searchRevision = UUID()
    }
    func moveSearch(_ step: Int) {
        guard !searchMatches.isEmpty else { return }
        do {try searchReadValidation?()} catch {clearSearch();searchFailure=error.localizedDescription;return}
        searchIndex = (max(0, searchIndex) + step % searchMatches.count + searchMatches.count) % searchMatches.count
        searchRevision = UUID(); searchNavigation = UUID()
    }

    func capture() {
        guard let view = activeView, let page = view.currentPage, let document else { return }
        pageIndex = document.index(for: page)
        pagePoint = view.currentDestination?.point ?? .zero
        let fit=view.scaleFactorForSizeToFit
        let zoom=view.scaleFactor/fit
        zoomRelativeToFit=fit.isFinite && fit>0 && zoom.isFinite && zoom>0 ? zoom:nil
    }

    func load(_ url: URL, force: Bool = false, validateRead: (() throws -> Void)? = nil) async {
        searchReadValidation=validateRead
        if force || loadedURL != url {clearSearch();searchDocumentReady=false}
        do {
            try validateRead?()
            var freshURL = url
            freshURL.removeAllCachedResourceValues()
            let info = try freshURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard force || loadedURL != url || document == nil || info.contentModificationDate != modificationDate
                    || info.fileSize != byteCount else { return }
            guard (info.fileSize ?? 0) <= 64 * 1024 * 1024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            clearSearch();searchDocumentReady=false
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
            clearSearch()
            documentRevision = UUID()
            modificationDate = info.contentModificationDate
            byteCount = info.fileSize
            error = nil
            locked = loaded.isLocked
            document = loaded
            loadedURL=url;searchDocumentReady=true
        } catch is CancellationError {
        } catch {
            clearSearch();searchDocumentReady=false
            self.error = error.localizedDescription
        }
    }
}

struct InlinePDFReader: View {
    let url: URL
    var validateRead: (() throws -> Void)? = nil
    var destination:PDFReadingDestination? = nil
    var onSource:(@MainActor (Int,Double,Double)->Void)? = nil
    @StateObject private var session = PDFReadingSession()
    @State private var expanded = false
    @State private var password = ""
    @State private var wrongPassword = false

    var body: some View {
        reader(inFullScreen: false)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    searchButton
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
                session.destination=destination
                await session.load(url, force: true, validateRead: validateRead)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                    await session.load(url, validateRead: validateRead)
                }
            }
            .onChange(of:destination) {_,value in session.destination=value}
            .overlay(alignment:.bottomTrailing) {
                if let onSource,session.document != nil,!session.locked {
                    Button(IDELanguageRunText.t("定位到源码","Locate source"),systemImage:"text.line.first.and.arrowtriangle.forward") {
                        do {
                            try withPDFExceptionGuard {
                                guard let view=session.activeView,let document=session.document,
                                      let page=view.page(for:CGPoint(x:view.bounds.midX,y:view.bounds.midY),nearest:true) else {return}
                                let point=view.convert(CGPoint(x:view.bounds.midX,y:view.bounds.midY),to:page),box=page.bounds(for:.mediaBox)
                                onSource(document.index(for:page)+1,point.x-box.minX,box.maxY-point.y)
                            }
                        } catch {session.error=error.localizedDescription}
                    }.buttonStyle(.bordered).padding(12).accessibilityIdentifier("latex.pdf.source")
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
                            ToolbarItem(placement: .topBarLeading) { searchButton }
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

    private var searchButton: some View {
        Button {
            if session.searchVisible { session.closeSearch() } else { session.searchVisible = true }
        } label: {
            Label(IDELanguageRunText.t("搜索 PDF", "Search PDF"), systemImage: "magnifyingglass")
        }
        .disabled(session.document == nil || session.locked || !session.searchDocumentReady)
        .accessibilityIdentifier("pdf.reader.search")
    }
    private var searchBar: some View {
        VStack(spacing: 4) {
            HStack {
                TextField(IDELanguageRunText.t("搜索 PDF", "Search PDF"), text: $session.searchQuery)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).onSubmit { session.beginSearch() }
                    .accessibilityIdentifier("pdf.reader.search.query")
                Menu {
                    Toggle(IDELanguageRunText.t("匹配大小写", "Match case"), isOn: $session.searchMatchCase)
                } label: { Image(systemName: "textformat") }
                    .accessibilityLabel(IDELanguageRunText.t("搜索选项", "Search options"))
                Button { session.closeSearch() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(IDELanguageRunText.t("结束搜索", "Close search"))
                    .accessibilityIdentifier("pdf.reader.search.close")
            }
            HStack {
                Button { session.moveSearch(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(session.searchCount == 0).accessibilityLabel(IDELanguageRunText.t("上一个结果", "Previous match"))
                    .accessibilityIdentifier("pdf.reader.search.previous")
                if session.searchBusy { ProgressView().controlSize(.mini) }
                Text(searchStatus).font(.caption).monospacedDigit().lineLimit(2)
                    .accessibilityIdentifier("pdf.reader.search.status")
                Button { session.moveSearch(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(session.searchCount == 0).accessibilityLabel(IDELanguageRunText.t("下一个结果", "Next match"))
                    .accessibilityIdentifier("pdf.reader.search.next")
                Spacer(minLength: 0)
            }.buttonStyle(.borderless)
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }
    private var searchStatus: String {
        if let failure = session.searchFailure { return failure }
        if session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return IDELanguageRunText.t("输入要查找的内容", "Enter text to find") }
        if session.searchCount > 0 {
            let count = String(session.searchIndex + 1) + " / " + String(session.searchCount)
            return session.searchCapped ? count + IDELanguageRunText.t("（前 1000 个）", " (first 1000)") : count
        }
        return session.searchBusy ? IDELanguageRunText.t("正在搜索…", "Searching…") : IDELanguageRunText.t("未找到结果", "No matches")
    }
    private func reader(inFullScreen: Bool) -> some View {
        VStack(spacing: 0) {
            if session.searchVisible, session.document != nil, !session.locked { searchBar; Divider() }
            readerContent(inFullScreen: inFullScreen)
        }
        .task(id: session.searchKey) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            session.beginSearch()
        }
        .onChange(of: session.searchQuery) { _, _ in session.clearSearch() }
        .onChange(of: session.searchMatchCase) { _, _ in session.clearSearch() }
        .onDisappear { if inFullScreen == session.fullScreen { session.clearSearch() } }
    }
    @ViewBuilder private func readerContent(inFullScreen: Bool) -> some View {
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
                    let value = password
                    password = ""
                    let unlocked = (try? withPDFExceptionGuard { session.document?.unlock(withPassword: value) == true }) ?? false
                    wrongPassword = !unlocked
                    session.locked = !unlocked
                    if unlocked { session.documentRevision = UUID() }
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

final class ReadingPDFView: PDFView {
    var restoreViewport: ((ReadingPDFView) -> Void)?
    var resizeViewport: ((ReadingPDFView, CGFloat, PDFDestination?) -> Void)?
    private var laidOutSize: CGSize?
    private var laidOutFit: CGFloat?
    private var layingOut = false
    override func layoutSubviews() {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        // The fit already reflects the incoming bounds by layout time. Keep
        // the preceding layout's fit so a manual zoom retains its meaning.
        let resized = laidOutSize.map { $0 != bounds.size } ?? false
        let zoom = autoScales ? 1 : laidOutFit.map { scaleFactor / $0 }
        let position = resized ? currentDestination : nil
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if let restore = restoreViewport {
            restoreViewport = nil
            restore(self)
        } else if resized, let zoom, zoom.isFinite, zoom > 0 {
            resizeViewport?(self, zoom, position)
        }
        laidOutSize = bounds.size
        let fit = scaleFactorForSizeToFit
        laidOutFit = fit.isFinite && fit > 0 ? fit : nil
    }
}

struct PDFReadingSurface: UIViewRepresentable {
    @ObservedObject var session: PDFReadingSession
    let presentationID: Bool

    func makeUIView(context: Context) -> ReadingPDFView {
        let view = ReadingPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: ReadingPDFView, context: Context) {
        guard presentationID == session.fullScreen else { return }
        let changed = view.document !== session.document
        let restored = session.activeView !== view
        if !changed && !restored {
            applyDestination(view,coordinator:context.coordinator)
            applySearch(view,coordinator:context.coordinator,restored:false)
            return
        }
        view.document = session.document
        if changed {context.coordinator.lastDestination=nil;context.coordinator.searchRevision=nil;context.coordinator.searchNavigation=nil}
        let coordinator=context.coordinator,expectedDocument=session.document,revision=session.documentRevision
        coordinator.presentationID = presentationID
        session.activeView = view
        view.resizeViewport = { [weak session] rendered, zoom, position in
            guard let session, presentationID == session.fullScreen, session.activeView === rendered,
                  session.documentRevision == revision, rendered.document === expectedDocument else { return }
            do {
                try withPDFExceptionGuard {
                    let fit = rendered.scaleFactorForSizeToFit
                    if abs(zoom - 1) > 0.02, fit.isFinite, fit > 0, (fit * zoom).isFinite {
                        rendered.autoScales = false
                        rendered.scaleFactor = min(rendered.maxScaleFactor, max(rendered.minScaleFactor, fit * zoom))
                    } else { rendered.autoScales = true }
                    if let position, position.page?.document === expectedDocument { rendered.go(to: position) }
                }
            } catch { session.error = error.localizedDescription }
        }
        // SwiftUI can supply the final bounds after updateUIView. Restore once
        // at a real layout boundary; search-result batches must not reset zoom.
        view.restoreViewport = { [weak session] rendered in
            guard let session,presentationID==session.fullScreen,session.activeView === rendered,
                  session.documentRevision==revision,rendered.document === expectedDocument else {return}
            do {
                try withPDFExceptionGuard {
                    if let document=rendered.document,let page=document.page(at:min(session.pageIndex,max(0,document.pageCount-1))) {
                        let fit=rendered.scaleFactorForSizeToFit
                        if let zoom=session.zoomRelativeToFit,abs(zoom-1)>0.02,fit.isFinite,fit>0,(fit*zoom).isFinite {
                            rendered.autoScales=false
                            rendered.scaleFactor=min(rendered.maxScaleFactor,max(rendered.minScaleFactor,fit*zoom))
                        } else {rendered.autoScales=true}
                        if session.zoomRelativeToFit != nil {rendered.go(to:PDFDestination(page:page,at:session.pagePoint))}
                        else {rendered.go(to:page)}
                    }
                }
                applyDestination(rendered,coordinator:coordinator)
                applySearch(rendered,coordinator:coordinator,restored:true)
            } catch {session.error=error.localizedDescription}
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func applySearch(_ view:PDFView,coordinator:Coordinator,restored:Bool) {
        do {
            try withPDFExceptionGuard {
                if restored || coordinator.searchRevision != session.searchRevision {
                    view.highlightedSelections=session.searchMatches
                    view.setCurrentSelection(session.selectedSearchMatch,animate:false)
                    coordinator.searchRevision=session.searchRevision
                }
                if restored || coordinator.searchNavigation != session.searchNavigation {
                    if let match=session.selectedSearchMatch {view.go(to:match)}
                    coordinator.searchNavigation=session.searchNavigation
                }
            }
        }catch {session.error=error.localizedDescription}
    }
    private func applyDestination(_ view:PDFView,coordinator:Coordinator) {
        guard let destination=session.destination,destination != coordinator.lastDestination,
              destination.page>0,destination.x.isFinite,destination.y.isFinite else {return}
        do {
            try withPDFExceptionGuard {
                guard let page=session.document?.page(at:destination.page-1) else {return}
                let box=page.bounds(for:.mediaBox)
                view.go(to:PDFDestination(page:page,at:CGPoint(x:box.minX+destination.x,y:box.maxY-destination.y)))
                coordinator.lastDestination=destination
            }
        } catch {session.error=error.localizedDescription}
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var presentationID: Bool?;var lastDestination:PDFReadingDestination?;var searchRevision:UUID?;var searchNavigation:UUID? }
}
#endif
