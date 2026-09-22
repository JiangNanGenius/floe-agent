import Foundation
import SwiftUI
import Observation
import FloeExecution
import FloeTools

/// App-lifetime ownership keeps a terminal alive when its sheet is dismissed.
@MainActor
final class LocalTerminalStore {
    private let sessions: ShellSessionCenter
    private var owners: [UUID: LocalTerminalOwner] = [:]
    init(sessions: ShellSessionCenter) { self.sessions = sessions }
    func owner(workspaceID: UUID, root: URL) -> LocalTerminalOwner {
        if let owner = owners[workspaceID], owner.root == root { return owner }
        if let previous = owners[workspaceID] { Task { await previous.close() } }
        let owner = LocalTerminalOwner(root: root, sessions: sessions)
        owners[workspaceID] = owner
        return owner
    }
}

@MainActor @Observable
final class LocalTerminalOwner: Identifiable {
    let id = UUID()
    let root: URL
    private let sessions: ShellSessionCenter
    private(set) var sessionID: String?
    private(set) var output = Data()
    private(set) var status = String(localized: "terminal.status.not_started")
    private(set) var alive = false
    private(set) var opening = false
    /// Set when the Linux image is missing or fails qualification; drives the
    /// Set when the Linux image is missing or fails qualification; drives the
    /// authoritative Linux component card (never shown for an installed or
    /// running guest).
    private(set) var missingImageID: String?
    private var token = CancellationToken()
    private var columns = 80
    private var rows = 24

    init(root: URL, sessions: ShellSessionCenter) { self.root = root; self.sessions = sessions }

    func open() async {
        guard !alive, !opening else { return }
        opening = true
        defer { opening = false }
        token = CancellationToken()
        sessionID = nil
        output = Data()
        missingImageID = nil
        status = String(localized: "terminal.status.starting")
        do {
            let result = try await sessions.open(command: "", cwd: ".", environment: [:], columns: columns, rows: rows, runID: id, rootURL: root, cancellation: token, forTerminal: true)
            sessionID = result.sessionID
            alive = result.alive
            status = alive ? String(localized: "terminal.status.running") : String(localized: "terminal.status.exited")
            append(result.terminalOutput ?? Data(result.initialOutput.utf8))
        } catch let error as LinuxGuestError {
            if case .imageNotQualified = error {
                missingImageID = LinuxGuestImageDistributionCatalog.defaultImageID
                status = String(localized: "environment.backend.image_missing")
            } else {
                status = String(describing: error)
            }
        } catch {
            status = String(describing: error)
        }
    }

    /// The IDE embeds this view and expects a started shell; an already-live
    /// session is never restarted just because the panel was re-shown.
    func startIfNeeded() async {
        guard sessionID == nil, !opening else { return }
        await open()
    }

    func resetAndStart() async {
        await close()
        await open()
    }

    func pollWhileVisible() async {
        while !Task.isCancelled {
            if alive { await exchange(nil) }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
    }

    func send(_ data: Data) async {
        if data.contains(3) {
            await interrupt()
            let remaining = data.filter { $0 != 3 }
            if !remaining.isEmpty { await exchange(String(decoding: remaining, as: UTF8.self)) }
        } else { await exchange(String(decoding: data, as: UTF8.self)) }
    }

    func resize(columns: Int, rows: Int) async {
        self.columns = columns; self.rows = rows
        if let sessionID { await sessions.resize(sessionID: sessionID, columns: columns, rows: rows, runID: id) }
    }

    func interrupt() async {
        if let sessionID { await sessions.signal(sessionID: sessionID, signal: .interrupt, runID: id) }
    }

    func close() async {
        token.cancel()
        if let sessionID { await sessions.close(sessionID: sessionID, runID: id) }
        alive = false
        sessionID = nil
        status = String(localized: "terminal.status.closed")
    }

    private func exchange(_ input: String?) async {
        guard let sessionID, alive else { return }
        do {
            let result = try await sessions.exchange(sessionID: sessionID, input: input, waitMs: 50, maxBytes: 64 * 1024, runID: id, cancellation: token, forTerminal: true)
            append(result.terminalOutput ?? Data(result.output.utf8))
            alive = result.alive
            if !alive {
                status = result.exitCode.map { String(format: String(localized: "terminal.status.exited_code"), Int64($0)) } ?? String(localized: "terminal.status.exited")
                self.sessionID = nil
            } else if result.bytesRead == 0 {
                // Distinguishes a live shell that has not written anything
                // yet from output that was read but not returned.
                status = String(localized: "terminal.status.waiting_output")
            } else {
                status = String(localized: "terminal.status.running")
            }
        } catch let error as LinuxGuestError {
            alive = false
            if case .imageNotQualified = error {
                missingImageID = LinuxGuestImageDistributionCatalog.defaultImageID
                status = String(localized: "environment.backend.image_missing")
            } else {
                status = String(describing: error)
            }
        } catch {
            alive = false
            status = String(describing: error)
        }
    }

    private func append(_ data: Data) {
        output.append(data)
        if output.count > 1024 * 1024 { output = Data(output.suffix(1024 * 1024)) }
    }
}

struct LocalTerminalView: View {
    let owner: LocalTerminalOwner
    /// Embedded panels (the IDE bottom panel) must not create their own
    /// navigation chrome; the panel owns placement and the hide affordance.
    /// Session lifetime is unaffected by either presentation: the owner comes
    /// from the app-lifetime `LocalTerminalStore`, so closing the panel never
    /// stops the shell.
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var installModel: LinuxImageInstallModel?

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content
                    .navigationTitle(String(localized: "terminal.title"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(String(localized: "terminal.hide")) { dismiss() } }
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button {
                                Task { await owner.resetAndStart() }
                            } label: { Label(String(localized: "terminal.restart"), systemImage: "arrow.clockwise") }
                                .disabled(owner.opening)
                            Button(role: .destructive) {
                                Task { await owner.close() }
                            } label: { Label(String(localized: "terminal.end_session"), systemImage: "stop.circle") }
                                .disabled(!owner.alive)
                        }
                    }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(owner.alive ? Color.green : (owner.opening ? Color.orange : Color.secondary))
                    .frame(width: 8, height: 8)
                Text(owner.status).font(.caption).lineLimit(1)
                Spacer(minLength: 8)
                if embedded {
                    Button {
                        Task { await owner.resetAndStart() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(owner.opening)
                        .accessibilityLabel(String(localized: "terminal.restart"))
                    Button(role: .destructive) {
                        Task { await owner.close() }
                    } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless)
                        .disabled(!owner.alive)
                        .accessibilityLabel(String(localized: "terminal.end_session"))
                }
                Button("Ctrl-C") { Task { await owner.interrupt() } }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(!owner.alive)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            SSHEmulatorView(output: owner.output, isInteractive: owner.alive,
                onSend: { data in Task { await owner.send(data) } },
                onResize: { columns, rows in Task { await owner.resize(columns: columns, rows: rows) } })
            if let missingID = owner.missingImageID,
               let model = installModel, model.imageID == missingID {
                LinuxImageInstallCard(
                    model: model,
                    onInstalled: { await owner.open() }
                )
                .padding()
                .task { await model.refresh() }
            } else if owner.missingImageID == nil, !owner.alive {
                Button(owner.opening ? String(localized: "terminal.starting") : String(localized: "terminal.start")) { Task { await owner.open() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(owner.opening)
                    .padding()
            }
        }
        .task(id: owner.missingImageID) {
            if let missingID = owner.missingImageID, installModel?.imageID != missingID {
                installModel = LinuxImageInstallModel(imageID: missingID)
            }
        }
        .task {
            // Opening a shell here is the explicit intent of presenting this
            // panel; a live session is reused, never restarted. Cancelling
            // this task on panel close only stops polling.
            await owner.startIfNeeded()
            await owner.pollWhileVisible()
        }
    }
}
