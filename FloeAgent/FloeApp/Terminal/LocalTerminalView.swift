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

/// Poll cadence for the local terminal loop. One exchange already blocks up
/// to its `waitMs` server-side, so the loop only adds pacing when the guest
/// is quiet: no delay at all while input was sent or output arrived (echo and
/// sustained output then drain at transport speed), and a short bounded
/// backoff while idle. The previous fixed 150 ms sleep stacked on top of
/// every round trip, which made typing and output feel "toothpaste".
struct TerminalPollCadence: Sendable {
    private(set) var idleRounds = 0

    /// Delay before the next exchange after one completes.
    mutating func delayAfterExchange(sentInput: Bool, bytesRead: Int) -> Duration {
        if sentInput || bytesRead > 0 {
            idleRounds = 0
            return .zero
        }
        idleRounds += 1
        return .milliseconds(min(10 * idleRounds, 100))
    }

    /// Delay when an exchange is still in flight (the loop is single-flight;
    /// this only smooths the re-check).
    var busyDelay: Duration { .milliseconds(20) }
}

@MainActor @Observable
final class LocalTerminalOwner: Identifiable {
    let id = UUID()
    let root: URL
    private let sessions: ShellSessionCenter
    private(set) var sessionID: String?
    private(set) var output = Data()
    private(set) var outputEnd = 0
    private(set) var outputGeneration = UUID()
    let presentation = TerminalPresentation()
    private(set) var status = String(localized: "terminal.status.not_started")
    private(set) var alive = false
    private(set) var opening = false
    /// Set when the Linux image is missing or fails qualification; drives the
    /// authoritative Linux component card (never shown for an installed or
    /// running guest).
    private(set) var missingImageID: String?
    private var token = CancellationToken()
    private var exchangeInFlight = false
    private var pendingInput = Data()
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
        outputEnd = 0
        outputGeneration = UUID()
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
        var cadence = TerminalPollCadence()
        while !Task.isCancelled {
            if alive, !exchangeInFlight {
                let input = pendingInput
                pendingInput.removeAll(keepingCapacity: true)
                if input.isEmpty {
                    let bytesRead = await exchange(nil)
                    let delay = cadence.delayAfterExchange(sentInput: false, bytesRead: bytesRead)
                    if delay > .zero {
                        do { try await Task.sleep(for: delay) } catch { return }
                    }
                } else {
                    await send(input)
                    // Input went out: poll again immediately so the echo and
                    // any follow-up keystroke batch at transport speed.
                    _ = cadence.delayAfterExchange(sentInput: true, bytesRead: 0)
                }
            } else {
                do { try await Task.sleep(for: cadence.busyDelay) } catch { return }
            }
        }
    }

    func enqueue(_ data: Data) {
        guard alive else { return }
        guard pendingInput.count + data.count <= 64 * 1024 else {
            status = IDELanguageRunText.t("输入过多，请分段粘贴。", "Too much input; paste in smaller parts.")
            return
        }
        pendingInput.append(data)
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
        pendingInput.removeAll()
        if let sessionID { await sessions.close(sessionID: sessionID, runID: id) }
        alive = false
        sessionID = nil
        status = String(localized: "terminal.status.closed")
    }

    @discardableResult
    /// One visible-loop iteration (flush pending input / drain output), with
    /// the cadence sleep left to the caller. DEBUG-only seam so the cadence
    /// measurements drive the real production body instead of a copy.
    #if DEBUG
    func pollOnceForTesting() async {
        guard alive, !exchangeInFlight else { return }
        let input = pendingInput
        pendingInput.removeAll(keepingCapacity: true)
        if input.isEmpty { _ = await exchange(nil) }
        else { await send(input) }
    }
    #endif

    private func exchange(_ input: String?) async -> Int {
        guard let sessionID, alive, !exchangeInFlight else { return 0 }
        exchangeInFlight = true
        defer { exchangeInFlight = false }
        do {
            let result = try await sessions.exchange(sessionID: sessionID, input: input, waitMs: 50, maxBytes: 64 * 1024, runID: id, cancellation: token, forTerminal: true)
            guard self.sessionID == sessionID else { return 0 }
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
            return result.bytesRead
        } catch let error as LinuxGuestError {
            guard self.sessionID == sessionID else { return 0 }
            alive = false
            if case .imageNotQualified = error {
                missingImageID = LinuxGuestImageDistributionCatalog.defaultImageID
                status = String(localized: "environment.backend.image_missing")
            } else {
                status = String(describing: error)
            }
        } catch {
            guard self.sessionID == sessionID else { return 0 }
            alive = false
            status = String(describing: error)
        }
        return 0
    }

    private func append(_ data: Data) {
        outputEnd += data.count
        output.append(data)
        if output.count > 1024 * 1024 { output = Data(output.suffix(1024 * 1024)) }
        presentation.consume(output, byteEnd: outputEnd, generation: outputGeneration)
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
    @State private var expanded = false
    @State private var showingPorts = false

    var body: some View {
        if embedded {
            Group {
                if expanded { Color.clear }
                else { content }
            }
            .fullScreenCover(isPresented: $expanded) {
                LocalTerminalView(owner: owner)
            }
        } else {
            NavigationStack {
                content
                    .navigationTitle(String(localized: "terminal.title"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(String(localized: "terminal.hide")) { dismiss() }.accessibilityIdentifier("terminal.fullscreen.close") }
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
                    Button { expanded = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel(IDELanguageRunText.t("全屏终端", "Full screen terminal"))
                    .accessibilityIdentifier("terminal.fullscreen")
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            Button("portforward.title", systemImage: "network") { showingPorts = true }.frame(minHeight: 44)
            TerminalControls(presentation: owner.presentation, interactive: owner.alive, send: owner.enqueue)
            SSHEmulatorView(output: owner.output, byteEnd: owner.outputEnd, generation: owner.outputGeneration,
                presentation: owner.presentation, isInteractive: owner.alive,
                onSend: { data in owner.enqueue(data) },
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
        .sheet(isPresented: $showingPorts) { NavigationStack { LinuxPortManagementView() } }
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
