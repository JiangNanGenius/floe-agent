// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO
import FloeGameCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum GameSaveManagerLocale: String, CaseIterable, Sendable {
    case automatic
    case english
    case simplifiedChinese

    public static var resolved: GameSaveManagerLocale {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return language.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    var isChinese: Bool {
        (self == .simplifiedChinese) || (self == .automatic && Self.resolved == .simplifiedChinese)
    }
}

/// Native slot manager for one running player. It owns no file browser, source
/// save or game shell; the host decides whether to present it as a sheet,
/// popover or iPad side panel. On wide windows the slot list and details share
/// one split surface; compact width and accessibility type use a linear list
/// with a native detail sheet.
@MainActor
public struct GameSaveManagerView: View {
    @ObservedObject private var session: GameSaveManagementSession
    private let strings: GameSaveStrings
    private let showsTitle: Bool

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selection: UUID?
    @State private var compactDetailID: UUID?
    @State private var showNewSave = false
    @State private var newTitle = ""
    @State private var renameTarget: GameSaveSlotDescriptor?
    @State private var renameTitle = ""
    @State private var deleteTarget: GameSaveSlotDescriptor?
    @State private var overwriteTarget: GameSaveSlotDescriptor?
    @State private var loadTarget: GameSaveSlotDescriptor?
    @State private var showImporter = false
    @State private var exportStage: GameSaveExportStage?
    @State private var showExporter = false
    @State private var localError: String?
    @State private var localNotice: String?

    public init(session: GameSaveManagementSession,
                locale: GameSaveManagerLocale = .automatic,
                showsTitle: Bool = true) {
        _session = ObservedObject(wrappedValue: session)
        strings = GameSaveStrings(locale: locale)
        self.showsTitle = showsTitle
    }

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                notices
                if isWide(proxy.size.width) {
                    HStack(spacing: 0) {
                        slotList(wide: true)
                            .frame(width: min(max(proxy.size.width * 0.34, 300), 430))
                        Divider()
                        detailPane(id: selection)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    slotList(wide: false)
                        .overlay(alignment: .top) {
                            if session.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(8)
                                    .background(.thinMaterial, in: Capsule())
                                    .padding(.top, 8)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("game.save.manager")
        }
        .background(backgroundColor)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .font(.callout)
        .task { await initialLoad() }
        .sheet(isPresented: Binding(
            get: { compactDetailID != nil },
            set: { if !$0 { compactDetailID = nil } })) {
            if let id = compactDetailID {
                NavigationStack {
                    detailPane(id: id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(strings.done) { compactDetailID = nil }
                                    .frame(minWidth: 44, minHeight: 44)
                                    .accessibilityIdentifier("game.save.detail.done")
                            }
                        }
                }
            }
        }
        .alert(strings.newSave, isPresented: $showNewSave) {
            TextField(strings.namePlaceholder, text: $newTitle)
                .accessibilityIdentifier("game.save.new.title")
            Button(strings.cancel, role: .cancel) {}
            Button(strings.create) {
                let title = newTitle
                clearLocalFeedback()
                session.startCreate(title: title)
            }
            .accessibilityIdentifier("game.save.new.confirm")
        } message: {
            Text(strings.newSaveMessage)
        }
        .alert(strings.rename, isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField(strings.namePlaceholder, text: $renameTitle)
                .accessibilityIdentifier("game.save.rename.title")
            Button(strings.cancel, role: .cancel) { renameTarget = nil }
            Button(strings.rename) {
                if let target = renameTarget {
                    let title = renameTitle
                    renameTarget = nil
                    clearLocalFeedback()
                    session.startRename(target.id, to: title)
                }
            }
            .accessibilityIdentifier("game.save.rename.confirm")
        } message: {
            Text(strings.renameMessage)
        }
        .confirmationDialog(strings.deleteTitle,
                            isPresented: Binding(
                                get: { deleteTarget != nil },
                                set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: deleteTarget) { target in
            Button(strings.delete, role: .destructive) {
                deleteTarget = nil
                clearLocalFeedback()
                session.startDelete(target.id)
            }
            .accessibilityIdentifier("game.save.delete.confirm")
            Button(strings.cancel, role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text(strings.deleteMessage)
        }
        .confirmationDialog(strings.overwriteTitle,
                            isPresented: Binding(
                                get: { overwriteTarget != nil },
                                set: { if !$0 { overwriteTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: overwriteTarget) { target in
            Button(strings.overwrite, role: .destructive) {
                overwriteTarget = nil
                clearLocalFeedback()
                session.startOverwrite(target.id, expectedRevision: target.revision)
            }
            .accessibilityIdentifier("game.save.overwrite.confirm")
            Button(strings.cancel, role: .cancel) { overwriteTarget = nil }
        } message: { _ in
            Text(strings.overwriteMessage)
        }
        .confirmationDialog(strings.loadTitle,
                            isPresented: Binding(
                                get: { loadTarget != nil },
                                set: { if !$0 { loadTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: loadTarget) { target in
            Button(strings.load) {
                loadTarget = nil
                clearLocalFeedback()
                session.startLoad(target.id,
                                  checkpointTitle: strings.checkpointTitle(target.title))
            }
            .accessibilityIdentifier("game.save.load.confirm")
            Button(strings.cancel, role: .cancel) { loadTarget = nil }
        } message: { target in
            Text(session.isCompatible(target) ? strings.loadMessage
                                              : strings.loadMessage + "\n\n" + strings.differentRevision)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            Task { @MainActor in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    localError = nil
                    localNotice = nil
                    if let result = try? await session.importBackup(from: url) {
                        localNotice = strings.importedReadback(title: result.slot.title,
                            bytes: result.backup.fileBytes, sha256: result.backup.sha256,
                            scope: shortScope)
                    }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        localError = strings.importFailed
                    }
                }
            }
        }
        .fileExporter(isPresented: $showExporter,
                      item: exportStage.map { GameSaveBackupTransfer(url: $0.url) },
                      contentTypes: [.json],
                      defaultFilename: exportStage?.package.suggestedFileName) { result in
            Task { @MainActor in finishExport(result) }
        } onCancellation: {
            Task { @MainActor in
                cleanupExportStage()
                localNotice = strings.exportCancelled
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if showsTitle {
                        Text(strings.title)
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("game.save.title")
                    }
                    Text(strings.engineName(session.identity.engine))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("game.save.scope")
                }
                Spacer(minLength: 4)
                if session.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityIdentifier("game.save.busy")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    creationActions
                    Spacer(minLength: 4)
                    autosaveToggle.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    creationActions
                    autosaveToggle
                }
            }
            if let readinessText {
                Label(readinessText, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("game.save.readiness")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var creationActions: some View {
        HStack(spacing: 12) {
            Button { prepareNewSave() } label: {
                    Label(strings.newSave, systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(minHeight: 44)
                .disabled(session.isBusy || !session.supportsNativeState)
                .accessibilityIdentifier("game.save.new")

                Menu {
                    Button {
                        localError = nil
                        localNotice = nil
                        showImporter = true
                    } label: {
                        Label(strings.importBackup, systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("game.save.import")
                    Button {
                        clearLocalFeedback()
                        session.startImportLegacy(title: strings.legacyImportName)
                    } label: {
                        Label(strings.importLegacy, systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("game.save.import.legacy")
                } label: {
                    Label(strings.importAction, systemImage: "square.and.arrow.down")
                        .frame(minHeight: 44)
                }
                .disabled(session.isBusy || !session.runGenerationIsCurrent)
                .accessibilityIdentifier("game.save.import.menu")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var autosaveToggle: some View {
        Toggle(strings.autosave, isOn: $session.autosaveEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .frame(minHeight: 44)
                    .help(strings.autosaveHelp)
                    .accessibilityIdentifier("game.save.autosave.toggle")
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        if let localError {
            noticeBanner(localError, symbol: "exclamationmark.triangle.fill", tint: .orange,
                         identifier: "game.save.error")
        } else if let error = session.lastError {
            noticeBanner(strings.error(error), symbol: "exclamationmark.triangle.fill",
                         tint: .orange, identifier: "game.save.error")
        } else if let localNotice {
            noticeBanner(localNotice, symbol: "checkmark.circle.fill", tint: .green,
                         identifier: "game.save.status")
        } else if let outcome = session.lastOutcome {
            noticeBanner(strings.outcome(outcome), symbol: "checkmark.circle.fill",
                         tint: .green, identifier: "game.save.status")
        }
    }

    private func noticeBanner(_ text: String, symbol: String, tint: Color,
                              identifier: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
            Button(strings.dismiss) {
                localError = nil
                localNotice = nil
                session.dismissNotice()
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier(identifier + ".dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier + ".banner")
    }

    // MARK: Slot list

    private func slotList(wide: Bool) -> some View {
        List {
            Section {
                if session.activeSlots.isEmpty {
                    Text(strings.empty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("game.save.empty")
                } else {
                    ForEach(session.activeSlots) { slot in
                        row(slot, wide: wide)
                    }
                }
            } header: {
                Text(strings.saves)
                    .accessibilityIdentifier("game.save.saves.header")
            }
            if !session.deletedSlots.isEmpty {
                Section {
                    ForEach(session.deletedSlots) { slot in
                        row(slot, wide: wide)
                    }
                } header: {
                    Text(strings.recentlyDeleted)
                        .accessibilityIdentifier("game.save.trash.header")
                } footer: {
                    Text(strings.trashMessage)
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("game.save.list")
    }

    private func row(_ slot: GameSaveSlotDescriptor, wide: Bool) -> some View {
        Button {
            if wide {
                selection = slot.id
            } else {
                compactDetailID = slot.id
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: slot.kind == .manual ? "tray.full" : "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(slot.isDeleted ? Color.secondary : Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(strings.kind(slot.kind))
                        Text("·")
                        Text(strings.bytes(slot.stateBytes))
                        if !session.isCompatible(slot) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityLabel(strings.differentRevisionShort)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if slot.isDeleted {
                    Text(strings.deletedBadge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(slot.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .background(wide && selection == slot.id
                        ? Color.accentColor.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityIdentifier("game.save.row.\(slot.id.uuidString.lowercased())")
        .accessibilityLabel("\(slot.title), \(strings.kind(slot.kind))")
    }

    // MARK: Detail

    @ViewBuilder private func detailPane(id: UUID?) -> some View {
        if let id, let slot = descriptor(id) {
            detail(slot)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(strings.noSelection)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("game.save.detail.empty")
        }
    }

    private func detail(_ slot: GameSaveSlotDescriptor) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(slot.title)
                            .font(.title2.weight(.semibold))
                            .accessibilityIdentifier("game.save.detail.title")
                        Text(strings.kind(slot.kind))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if slot.isDeleted {
                        Text(strings.deletedBadge)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                }

                GameSavePreview(session: session, slotID: slot.id, strings: strings)

                if !session.isCompatible(slot) {
                    Label {
                        Text(strings.differentRevision).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                        .font(.callout)
                        .accessibilityIdentifier("game.save.detail.warning")
                }
                if !session.supportsNativeState && !slot.isDeleted {
                    Label(strings.loadNeedsRunningGame, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("game.save.detail.unavailable")
                }

                VStack(alignment: .leading, spacing: 8) {
                    detailRow(strings.updated) {
                        Text(slot.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .accessibilityIdentifier("game.save.detail.updated")
                    }
                    detailRow(strings.stateSize) {
                        Text(strings.bytes(slot.stateBytes))
                            .accessibilityIdentifier("game.save.detail.size")
                    }
                    DisclosureGroup(strings.technicalDetails) {
                        detailRow(strings.revision) { Text("\(slot.revision)") }
                        detailRow(strings.stateDigest) {
                            Text(String(slot.stateDigest.prefix(16)) + "…")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityValue(Text(slot.stateDigest))
                                .accessibilityIdentifier("game.save.detail.digest")
                        }
                        detailRow(strings.sourceRevision) {
                            Text(slot.sourceRevision)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("game.save.detail.source")
                        }
                        detailRow(strings.scope) {
                            Text(String(slot.scopeID.uuidString.prefix(8)).lowercased())
                                .font(.system(.caption, design: .monospaced))
                                .accessibilityIdentifier("game.save.detail.scope")
                        }
                    }
                    .accessibilityIdentifier("game.save.detail.technical")
                }
                .font(.callout)

                Divider()
                actions(slot)
                Text(strings.backupNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("game.save.detail")
    }

    private func detailRow(_ title: String,
                           @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value()
        }
    }

    @ViewBuilder private func actions(_ slot: GameSaveSlotDescriptor) -> some View {
        if slot.isDeleted {
            Button {
                clearLocalFeedback()
                session.startRecover(slot.id)
            } label: {
                Label(strings.recover, systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(session.isBusy)
            .accessibilityIdentifier("game.save.detail.recover")
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    loadButton(slot)
                    overwriteButton(slot)
                    exportButton(slot)
                    moreActions(slot)
                }
                VStack(alignment: .leading, spacing: 10) {
                    loadButton(slot)
                    overwriteButton(slot)
                    exportButton(slot)
                    moreActions(slot)
                }
            }
        }
    }

    private func moreActions(_ slot: GameSaveSlotDescriptor) -> some View {
        Menu {
            renameButton(slot)
            deleteButton(slot)
        } label: {
            Label(strings.moreActions, systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .help(strings.moreActions)
        .disabled(session.isBusy || !session.runGenerationIsCurrent)
        .accessibilityIdentifier("game.save.detail.more")
    }

    private func loadButton(_ slot: GameSaveSlotDescriptor) -> some View {
        Button {
            loadTarget = slot
        } label: {
            Label(strings.load, systemImage: "arrow.down.doc")
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(session.isBusy || !session.supportsNativeState)
        .accessibilityIdentifier("game.save.detail.load")
    }

    private func overwriteButton(_ slot: GameSaveSlotDescriptor) -> some View {
        Button {
            overwriteTarget = slot
        } label: {
            Label(strings.overwrite, systemImage: "square.and.arrow.down.on.square")
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(session.isBusy || !session.supportsNativeState)
        .accessibilityIdentifier("game.save.detail.overwrite")
    }

    private func exportButton(_ slot: GameSaveSlotDescriptor) -> some View {
        Button {
            export(slot)
        } label: {
            Label(strings.exportBackup, systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(session.isBusy || !session.runGenerationIsCurrent)
        .accessibilityIdentifier("game.save.detail.export")
    }

    private func renameButton(_ slot: GameSaveSlotDescriptor) -> some View {
        Button {
            renameTarget = slot
            renameTitle = slot.title
        } label: {
            Label(strings.rename, systemImage: "pencil")
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(session.isBusy || !session.runGenerationIsCurrent)
        .accessibilityIdentifier("game.save.detail.rename")
    }

    private func deleteButton(_ slot: GameSaveSlotDescriptor) -> some View {
        Button(role: .destructive) {
            deleteTarget = slot
        } label: {
            Label(strings.delete, systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(session.isBusy || !session.runGenerationIsCurrent)
        .accessibilityIdentifier("game.save.detail.delete")
    }

    // MARK: Actions and lifecycle

    private func clearLocalFeedback() {
        localNotice = nil
        localError = nil
    }

    private func initialLoad() async {
        session.refreshReadiness()
        try? await session.refresh()
        if selection == nil { selection = session.activeSlots.first?.id }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(600))
            session.refreshReadiness()
        }
    }

    private func prepareNewSave() {
        let used = Set(session.activeSlots.map { $0.title.lowercased() })
        let first = session.activeSlots.count + 1
        for offset in 0...used.count {
            let candidate = strings.defaultSaveName(first + offset)
            if !used.contains(candidate.lowercased()) { newTitle = candidate; break }
        }
        showNewSave = true
    }

    private func export(_ slot: GameSaveSlotDescriptor) {
        localError = nil
        localNotice = nil
        Task {
            do {
                let package = try await session.exportBackup(slot.id)
                let stage = try stageExport(package)
                exportStage = stage
                showExporter = true
            } catch {
                localError = strings.exportFailed
            }
        }
    }

    private func stageExport(_ package: GameSaveBackupPackage) throws -> GameSaveExportStage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeSaveExport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(package.suggestedFileName)
        try package.data.write(to: url, options: [.atomic])
        return GameSaveExportStage(id: UUID(), url: url, package: package)
    }

    private func finishExport(_ result: Result<URL, any Error>) {
        guard let stage = exportStage else {
            showExporter = false
            return
        }
        showExporter = false
        Task {
            defer { cleanupExportStage() }
            switch result {
            case .failure:
                localError = strings.exportFailed
            case .success(let destination):
                do {
                    let summary = try await session.inspectBackup(at: destination)
                    guard summary.sha256 == stage.package.summary.sha256,
                          summary.fileBytes == stage.package.summary.fileBytes else {
                        localError = strings.exportVerificationFailed
                        return
                    }
                    localError = nil
                    localNotice = strings.exported(bytes: summary.fileBytes,
                        sha256: summary.sha256,
                        engine: strings.engineName(session.identity.engine),
                        scope: shortScope)
                } catch {
                    localError = strings.exportVerificationFailed
                }
            }
        }
    }

    private func cleanupExportStage() {
        if let stage = exportStage {
            try? FileManager.default.removeItem(at: stage.url.deletingLastPathComponent())
        }
        exportStage = nil
    }

    private func descriptor(_ id: UUID) -> GameSaveSlotDescriptor? {
        session.activeSlots.first(where: { $0.id == id })
            ?? session.deletedSlots.first(where: { $0.id == id })
    }

    private func isWide(_ width: CGFloat) -> Bool {
        #if os(iOS)
        guard sizeClass != .compact else { return false }
        #endif
        return width >= 720 && !dynamicTypeSize.isAccessibilitySize
    }

    private var readinessText: String? {
        switch session.readiness {
        case .notRunning: return strings.notRunning
        case .unsupported: return strings.unsupported
        case .ready: return session.runGenerationIsCurrent ? nil : strings.staleRun
        }
    }

    private var shortScope: String {
        String(session.identity.uuid.uuidString.prefix(8)).lowercased()
    }

    private var backgroundColor: Color {
        #if os(iOS)
        return Color(uiColor: .systemGroupedBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

// MARK: - Export transfer

private struct GameSaveBackupTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { value in
            SentTransferredFile(value.url, allowAccessingOriginalFile: true)
        }
        .suggestedFileName { $0.url.lastPathComponent }
    }
}

private struct GameSaveExportStage: Identifiable {
    let id: UUID
    let url: URL
    let package: GameSaveBackupPackage
}

// MARK: - Preview

@MainActor
private struct GameSavePreview: View {
    let session: GameSaveManagementSession
    let slotID: UUID
    let strings: GameSaveStrings
    @State private var image: CGImage?
    @State private var loading = true

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 220)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                Label(strings.noPreview, systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.preview)
        .accessibilityIdentifier("game.save.preview")
        .task(id: slotID) { await load() }
    }

    private func load() async {
        loading = true
        image = nil
        defer { loading = false }
        guard let data = try? await session.thumbnail(for: slotID) else { return }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 800,
                       kCGImageSourceShouldCacheImmediately: false] as [CFString: Any]
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Strings

private struct GameSaveStrings: Sendable {
    let locale: GameSaveManagerLocale

    init(locale: GameSaveManagerLocale) { self.locale = locale }

    private func text(_ english: String, _ chinese: String) -> String {
        locale.isChinese ? chinese : english
    }

    var title: String { text("Save slots", "存档") }
    var saves: String { text("Saves", "存档槽") }
    var recentlyDeleted: String { text("Recently deleted", "最近删除") }
    var scope: String { text("Scope", "范围") }
    var technicalDetails: String { text("Technical details", "技术详情") }
    var moreActions: String { text("More actions", "更多操作") }
    var autosave: String { text("Autosave", "自动存档") }
    var autosaveHelp: String {
        text("Capture one bounded autosave before the game stops.",
             "在游戏停止前捕获一次有界自动存档。")
    }
    var newSave: String { text("New save", "新建存档") }
    var newSaveMessage: String {
        text("The running game's current state is captured when you create the slot.",
             "创建存档槽时会捕获正在运行游戏的当前状态。")
    }
    var namePlaceholder: String { text("Save name", "存档名称") }
    var create: String { text("Create", "创建") }
    var importAction: String { text("Import", "导入") }
    var importBackup: String { text("Import backup", "导入备份") }
    var importLegacy: String { text("Import legacy save", "导入旧版存档") }
    var legacyImportName: String { text("Imported legacy save", "导入的旧版存档") }
    var exportBackup: String { text("Export backup", "导出备份") }
    var load: String { text("Load", "读取") }
    var overwrite: String { text("Overwrite", "覆盖") }
    var rename: String { text("Rename", "重命名") }
    var delete: String { text("Delete", "删除") }
    var recover: String { text("Restore", "恢复") }
    var done: String { text("Done", "完成") }
    var cancel: String { text("Cancel", "取消") }
    var dismiss: String { text("Dismiss", "关闭") }
    var updated: String { text("Updated", "更新时间") }
    var stateSize: String { text("State size", "状态大小") }
    var stateDigest: String { text("State digest", "状态摘要") }
    var sourceRevision: String { text("Game revision", "游戏修订") }
    var revision: String { text("Revision", "修订") }
    var empty: String {
        text("No saves yet. Start the game and create one while it is running.",
             "还没有存档。请先开始游戏，并在运行时新建存档。")
    }
    var noSelection: String {
        text("Select a save to see its details.", "选择一个存档查看详情。")
    }
    var noPreview: String { text("No preview", "无预览") }
    var preview: String { text("Save preview", "存档预览") }
    var trashMessage: String {
        text("Deleted saves remain recoverable until this list fills.",
             "删除的存档会保留到该列表达到上限，可随时恢复。")
    }
    var deletedBadge: String { text("Deleted", "已删除") }
    var differentRevisionShort: String {
        text("Captured from a different game revision",
             "来自不同的游戏修订")
    }
    var differentRevision: String {
        text("This save was captured from a different game revision. Loading it may not fit the current build.",
             "此存档来自不同的游戏修订；读取后可能与当前版本不匹配。")
    }
    var notRunning: String {
        text("Start the game to capture a native save.",
             "请先开始游戏，才能捕获原生存档。")
    }
    var staleRun: String {
        text("This game restarted. Reopen save management for the new run.",
             "游戏已重新启动，请为新运行重新打开存档管理。")
    }
    var unsupported: String {
        text("This engine doesn't expose native snapshots. Its own in-game saves still work.",
             "此引擎不提供原生状态快照；游戏自带的存档仍可正常使用。")
    }
    var loadNeedsRunningGame: String {
        text("Load and overwrite are available while this game is running and supports snapshots.",
             "只有在游戏运行且支持状态快照时，才能读取或覆盖存档。")
    }
    var loadTitle: String { text("Load this save?", "读取此存档？") }
    var loadMessage: String {
        text("Current progress is captured as a safety checkpoint first. If restore fails, that checkpoint remains.",
             "读取前会先把当前进度保存为安全检查点；若恢复失败，该检查点仍会保留。")
    }
    var overwriteTitle: String { text("Overwrite this save?", "覆盖此存档？") }
    var overwriteMessage: String {
        text("The saved snapshot will be replaced. This cannot be undone.",
             "已保存的快照将被替换，且无法撤销。")
    }
    var deleteTitle: String { text("Delete this save?", "删除此存档？") }
    var deleteMessage: String {
        text("The slot moves to Recently deleted and can be restored later.",
             "存档会移入“最近删除”，之后仍可恢复。")
    }
    var renameMessage: String {
        text("Only the slot name changes; the snapshot stays the same.",
             "只修改存档名称，快照内容保持不变。")
    }
    var backupNote: String {
        text("Backups contain one save slot only. Source files are never included, and import always creates a new slot.",
             "备份仅包含一个存档槽，不包含任何源文件；导入始终创建新存档槽。")
    }
    var exportFailed: String {
        text("The backup could not be written.", "无法写入备份。")
    }
    var exportVerificationFailed: String {
        text("The saved backup didn't match its digest.", "保存后的备份与摘要不一致。")
    }
    var exportCancelled: String {
        text("Export cancelled.", "已取消导出。")
    }
    var importFailed: String {
        text("The backup could not be imported.", "无法导入备份。")
    }

    func defaultSaveName(_ index: Int) -> String {
        text("Save \(index)", "存档 \(index)")
    }

    func checkpointTitle(_ title: String) -> String {
        text("Before loading: \(title)", "读取前：\(title)")
    }

    func kind(_ kind: GameSaveSlotKind) -> String {
        switch kind {
        case .manual: return text("Manual", "手动")
        case .autosave: return text("Autosave", "自动存档")
        }
    }

    func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    func outcome(_ outcome: GameSaveManagementOutcome) -> String {
        switch outcome {
        case .created(let title): return text("Saved “\(title)”.", "已保存“\(title)”。")
        case .overwrote(let title): return text("Overwrote “\(title)”.", "已覆盖“\(title)”。")
        case .loaded(let title): return text("Loaded “\(title)”.", "已读取“\(title)”。")
        case .renamed(let title): return text("Renamed to “\(title)”.", "已重命名为“\(title)”。")
        case .deleted(let title): return text("Moved “\(title)” to Recently deleted.", "已将“\(title)”移入最近删除。")
        case .recovered(let title): return text("Restored “\(title)”.", "已恢复“\(title)”。")
        case .imported(let title): return text("Imported as “\(title)”.", "已导入为“\(title)”。")
        case .importedLegacy(let title): return text("Imported legacy save as “\(title)”.", "已导入旧版存档为“\(title)”。")
        case .legacyAlreadyImported(let title): return text("“\(title)” was already imported.", "“\(title)”已经导入过。")
        }
    }

    func exported(bytes: Int, sha256: String, engine: String, scope: String) -> String {
        text("Backup exported and verified · \(self.bytes(bytes))",
             "备份已导出并验证 · \(self.bytes(bytes))")
    }

    func importedReadback(title: String, bytes: Int, sha256: String, scope: String) -> String {
        text("Imported as a new save “\(title)” · \(self.bytes(bytes))",
             "已导入为新存档“\(title)” · \(self.bytes(bytes))")
    }

    func engineName(_ engine: GameEngineID) -> String {
        switch engine {
        case .rpgMakerXP: return "RPG Maker XP"
        case .rpgMakerVX: return "RPG Maker VX"
        case .rpgMakerVXAce: return "RPG Maker VX Ace"
        case .rpgMakerMV: return "RPG Maker MV"
        case .rpgMakerMZ: return "RPG Maker MZ"
        case .phaser: return "Phaser"
        case .kaplay: return "KAPLAY"
        case .godot: return "Godot"
        case .babylon: return "Babylon.js"
        case .playcanvas: return "PlayCanvas"
        case .love: return "LÖVE"
        case .renpy: return "Ren'Py"
        case .tic80: return "TIC-80"
        case .ink: return "ink"
        case .twine: return "Twine"
        case .gdevelop: return "GDevelop"
        case .cocosCreator: return "Cocos Creator"
        case .microStudio: return "microStudio"
        case .wasm4: return "WASM-4"
        case .unity: return "Unity"
        }
    }

    func error(_ error: GameSaveManagementError) -> String {
        switch error {
        case .invalidated:
            return text("The game run ended. Reopen save management from the running game.",
                        "游戏运行已结束，请从正在运行的游戏重新打开存档管理。")
        case .cancelled:
            return text("The save operation was cancelled.", "存档操作已取消。")
        case .busy:
            return text("Wait for the current save operation to finish.", "请等待当前存档操作完成。")
        case .stateUnavailable:
            return text("This engine can't capture native state. Use its own in-game saves.",
                        "此引擎无法捕获原生状态，请使用游戏自带的存档。")
        case .staleRun:
            return text("The game run changed. Reopen save management for the new run.",
                        "游戏运行已变化，请为新运行重新打开存档管理。")
        case .captureFailed:
            return text("The game couldn't capture a snapshot. Your progress is unchanged.",
                        "游戏无法捕获快照；当前进度未改变。")
        case .restoreFailed:
            return text("The game couldn't restore that save. Your progress was kept in the safety checkpoint.",
                        "游戏无法恢复该存档；当前进度已保留在安全检查点。")
        case .repository(let code):
            return repositoryError(code)
        case .backupTooLarge:
            return text("The backup is too large to import.", "备份过大，无法导入。")
        case .backupReadFailed:
            return text("The backup file couldn't be read.", "无法读取备份文件。")
        case .invalidFileURL:
            return text("The selected backup is not a file.", "所选备份不是文件。")
        case .unexpected:
            return text("The save operation failed.", "存档操作失败。")
        }
    }

    private func repositoryError(_ code: GameSaveSlotError) -> String {
        switch code {
        case .staleRevision:
            return text("This save changed elsewhere. The list was refreshed; try again.",
                        "此存档已在别处变化；列表已刷新，请重试。")
        case .limitExceeded(let limit) where limit == "slots":
            return text("The save list is full. Delete a save first.", "存档列表已满，请先删除一个存档。")
        case .limitExceeded(let limit) where limit == "bytes":
            return text("The save store is full. Delete a save first.", "存档空间已满，请先删除一个存档。")
        case .limitExceeded(let limit) where limit == "autosaves":
            return text("Autosave space is full. Delete a save and try again.",
                        "自动存档空间已满，请删除一个存档后重试。")
        case .titleInUse:
            return text("Another save already uses that name.", "已有存档使用该名称。")
        case .scopeMismatch:
            return text("This backup belongs to a different game or project.", "此备份属于其他游戏或工程。")
        case .backupDigestMismatch, .invalidBackup:
            return text("The backup is damaged or was modified. Nothing was imported.",
                        "备份已损坏或被修改；未导入任何内容。")
        case .unsupportedBackupVersion:
            return text("This backup needs a newer version of the app.", "此备份需要更新版本的应用。")
        case .legacyStoreMissing:
            return text("No legacy save was found for this game.", "未找到此游戏的旧版存档。")
        case .legacyScopeMismatch:
            return text("The legacy save belongs to another project or owner.",
                        "旧版存档属于其他工程或所有者。")
        case .legacyStoreCorrupt:
            return text("The legacy save is damaged.", "旧版存档已损坏。")
        case .slotNotFound, .slotNotDeleted, .payloadMissing, .corruptSlot, .corruptCatalog:
            return text("The save is no longer available. Refresh the list and try again.",
                        "该存档已不可用；请刷新列表后重试。")
        default:
            return text("The save operation failed.", "存档操作失败。")
        }
    }
}
