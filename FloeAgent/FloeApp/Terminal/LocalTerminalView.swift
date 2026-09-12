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
    private(set) var status = "尚未启动"
    private(set) var alive = false
    private(set) var opening = false
    private var token = CancellationToken()
    private var columns = 80
    private var rows = 24

    init(root: URL, sessions: ShellSessionCenter) { self.root = root; self.sessions = sessions }

    func open() async {
        guard !alive, !opening else { return }
        opening = true
        defer { opening = false }
        token = CancellationToken()
        do {
            let result = try await sessions.open(command: "", cwd: ".", environment: [:], columns: columns, rows: rows, runID: id, rootURL: root, cancellation: token, forTerminal: true)
            sessionID = result.sessionID
            alive = result.alive
            status = alive ? "运行中" : "已结束"
            append(result.terminalOutput ?? Data(result.initialOutput.utf8))
        } catch { status = String(describing: error) }
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
        status = "已关闭"
    }

    private func exchange(_ input: String?) async {
        guard let sessionID, alive else { return }
        do {
            let result = try await sessions.exchange(sessionID: sessionID, input: input, waitMs: 50, maxBytes: 64 * 1024, runID: id, cancellation: token, forTerminal: true)
            append(result.terminalOutput ?? Data(result.output.utf8))
            alive = result.alive
            if !alive { status = result.exitCode.map { "已结束（\($0)）" } ?? "已结束" }
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text(owner.status).font(.caption)
                    Spacer()
                    Button("Ctrl-C") { Task { await owner.interrupt() } }.disabled(!owner.alive)
                }.padding()
                SSHEmulatorView(output: owner.output, isInteractive: owner.alive,
                    onSend: { data in Task { await owner.send(data) } },
                    onResize: { columns, rows in Task { await owner.resize(columns: columns, rows: rows) } })
                if !owner.alive {
                    Button(owner.opening ? "正在启动…" : "启动本地终端") { Task { await owner.open() } }
                        .buttonStyle(.borderedProminent).disabled(owner.opening).padding()
                }
            }
            .navigationTitle("本地终端")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("收起") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("结束会话", role: .destructive) { Task { await owner.close() } }.disabled(!owner.alive)
                }
            }
            .task { await owner.pollWhileVisible() }
        }
    }
}
