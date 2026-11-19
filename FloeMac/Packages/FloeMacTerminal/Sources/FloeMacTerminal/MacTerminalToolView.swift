// FloeMacTerminal — the toolbox terminal tool view.
//
// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// The built-in interactive terminal tool for the Mac toolbox.
///
/// Contract for the toolbox coordinator:
/// - `MacTerminalToolView()` shows a start screen; nothing launches until
///   the user presses the start button (manual sessions only).
/// - `MacTerminalToolView(projectDirectory:)` additionally offers a
///   "current project" scope pre-validated from the bound path.
/// - `MacTerminalToolView(session:)` uses a session owned elsewhere (e.g.
///   the toolbox services owner); teardown then calls
///   `await session.stop()` / `close(timeout:)` from the owning side.
/// - User input goes only through the on-screen terminal; there is no API
///   on this view (or on `MacTerminalSession`) that lets model-authored
///   code reach the PTY.
/// - Closing is explicit: the close button drains the child via
///   `MacTerminalSession.close(timeout:)`; if the view is destroyed first,
///   the session's deinit backstop terminates the child.
public struct MacTerminalToolView: View {
    @ObservedObject private var session: MacTerminalSession
    @Binding private var projectDirectory: String?

    @State private var scope: ScopeChoice = .home
    @State private var pickedFolder: String?
    @State private var startError: String?
    @State private var stopping = false

    /// Shows the terminal tool with its own session, which ends when the
    /// view is torn down.
    public init() {
        _session = ObservedObject(wrappedValue: MacTerminalSession())
        _projectDirectory = .constant(nil)
    }

    /// Shows the terminal tool with a session owned by the caller, so the
    /// toolbox can keep/drain it across view teardown (resume/close).
    public init(session: MacTerminalSession) {
        _session = ObservedObject(wrappedValue: session)
        _projectDirectory = .constant(nil)
    }

    /// Shows the terminal tool with an additional "current project" scope.
    /// The binding is read (and re-validated) when the session starts.
    public init(projectDirectory: Binding<String?>) {
        _session = ObservedObject(wrappedValue: MacTerminalSession())
        _projectDirectory = projectDirectory
    }

    public var body: some View {
        VStack(spacing: 0) {
            switch session.state {
            case .idle:
                startScreen
            case .running, .stopping:
                runningChrome
                Divider()
                MacTerminalSurface(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .exited(let code):
                exitedBanner(code)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Start screen

    private var startScreen: some View {
        Form {
            Picker(selection: $scope) {
                Text(MacTerminalCopy.t("主目录", "Home")).tag(ScopeChoice.home)
                if let projectDirectory {
                    Text(MacTerminalCopy.t("当前项目：", "Current project: ") + projectDirectory)
                        .tag(ScopeChoice.project)
                }
                if let pickedFolder {
                    Text(MacTerminalCopy.t("所选文件夹：", "Selected folder: ") + pickedFolder)
                        .tag(ScopeChoice.picked)
                } else {
                    Text(MacTerminalCopy.t("选择文件夹…", "Choose Folder…")).tag(ScopeChoice.pick)
                }
            } label: {
                Text(MacTerminalCopy.t("启动位置", "Start in"))
            }
            .pickerStyle(.radioGroup)

            HStack {
                Button {
                    pickFolder()
                } label: {
                    Text(MacTerminalCopy.t("选择文件夹…", "Choose Folder…"))
                }
                Spacer()
                Button {
                    startSession()
                } label: {
                    Text(MacTerminalCopy.t("启动终端", "Start Terminal"))
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canStart)
            }
            if let startError {
                Text(startError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canStart: Bool {
        resolvedScope != nil
    }

    private var resolvedScope: MacTerminalScope? {
        switch scope {
        case .home:
            return .home
        case .project:
            guard let projectDirectory else { return nil }
            return try? .validatedDirectory(projectDirectory)
        case .picked:
            guard let pickedFolder else { return nil }
            return try? .validatedDirectory(pickedFolder)
        case .pick:
            return nil
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: pickedFolder ?? NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedFolder = url.path
        scope = .picked
    }

    private func startSession() {
        startError = nil
        guard let resolvedScope else { return }
        do {
            try session.start(scope: resolvedScope)
        } catch {
            startError = MacTerminalCopy.t(
                "无法启动终端：\(String(reflecting: error))",
                "Could not start the terminal: \(String(reflecting: error))"
            )
        }
    }

    // MARK: Running

    private var runningChrome: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.state == .running ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                stopping = true
                Task {
                    await session.close()
                    stopping = false
                }
            } label: {
                if stopping {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(MacTerminalCopy.t("结束会话", "End Session"))
                }
            }
            .disabled(stopping)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusText: String {
        let title = session.terminalTitle.isEmpty
            ? MacTerminalCopy.t("终端", "Terminal")
            : session.terminalTitle
        switch session.state {
        case .running:
            if let cwd = session.currentDirectory {
                return "\(title) — \(cwd)"
            }
            return title
        case .stopping:
            return MacTerminalCopy.t("正在结束…", "Ending…")
        default:
            return title
        }
    }

    // MARK: Exited

    private func exitedBanner(_ code: Int32?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.largeTitle)
            Text(exitText(code))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                session.reset()
            } label: {
                Text(MacTerminalCopy.t("新建会话", "New Session"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exitText(_ code: Int32?) -> String {
        switch code {
        case .some(let code):
            return MacTerminalCopy.t("会话已结束，退出代码 \(code)", "Session ended with exit code \(code)")
        case .none:
            return MacTerminalCopy.t("会话已结束", "Session ended")
        }
    }

    // MARK: Scope choice

    private enum ScopeChoice: Hashable {
        case home
        case project
        case picked
        case pick
    }
}
