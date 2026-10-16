// Real service qualification, not a model or UI test. Opt-in only: the
// production pinned Linux image may be downloaded on first activation.
// Run this suite serially with other real-guest tests; it owns only the
// canonical project environment for its unique workspace root.
#if canImport(UIKit) && DEBUG
import Foundation
import Testing
import UserNotifications
import FloeCore
import FloeExecution
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeApp

@Suite("FloeApp.LocalLinuxStaticServiceRealVM", .serialized)
@MainActor struct LocalLinuxStaticServiceRealVMTests {
    private struct Progress: Decodable {
        var state: String
        var previewURL: String?
    }

    private func ownedEnvironment(root: URL, app: AppEnvironment) async throws -> String? {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let owner = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        let matches = await app.environmentRegistry.containersOwned(by: owner)
            .filter { $0.kind == .project && $0.state != .deleting }
        guard matches.count <= 1 else {
            throw FloeError.validationFailed("Qualification workspace has multiple project environments; none was selected")
        }
        return matches.first?.id
    }

    private func waitForTerminal(_ jobs: BackgroundJobService, id: UUID, seconds: TimeInterval = 90) async throws -> BackgroundJob {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let job = try await jobs.job(id: id), job.state.isTerminal { return job }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FloeError.validationFailed("Own service did not acknowledge exit; preserve its environment and workspace")
    }

    private func waitForPreview(_ jobs: BackgroundJobService, id: UUID) async throws -> URL {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            guard let job = try await jobs.job(id: id) else { throw FloeError.notFound("Qualification job disappeared") }
            if job.state.isTerminal {
                throw FloeError.validationFailed("Static service ended before readiness: \(job.lastError ?? job.state.rawValue)")
            }
            if let data = job.progressJSON,
               let progress = try? JSONDecoder().decode(Progress.self, from: data),
               progress.state == "running", let value = progress.previewURL, let url = URL(string: value) {
                return url
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw FloeError.validationFailed("Static HTML readiness deadline exceeded; inspect the one existing job, do not resubmit")
    }

    private func fetch(_ url: URL, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FloeError.validationFailed("Preview did not return HTTP") }
        return (data, http)
    }

    @Test("real guest static service serves nested Unicode HTML and relative CSS, survives observer close, and exits on cancel",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1"))
    func staticHTMLNestedResourcesLifecycle() async throws {
        let app = AppEnvironment.live()
        await app.bootstrap()
        try #require(app.persistenceReady, "Production persistence bootstrap failed")
        let jobs = try #require(app.backgroundJobService, "Production job service is unavailable")
        let services = FloePlatformServices.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("static-real-vm-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversationID = UUID(), runID = UUID()
        var environmentID: String?
        var jobID: UUID?
        var observer: Task<Void, Never>?
        var recordsCreated = false
        var evidence: [String: String] = ["kind": "real-service-not-model-not-ui", "root": root.path]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        func retainEvidence(_ phase: String) {
            evidence["phase"] = phase
            if let data = try? JSONEncoder().encode(evidence) {
                try? data.write(to: root.appendingPathComponent("qualification-evidence.json"), options: .atomic)
                print("FLOE_STATIC_REALVM " + String(decoding: data, as: UTF8.self))
            }
        }

        func retainFailureEvidence() {
            guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true) else { return }
            let directory = base.appendingPathComponent("FloeAgent/QualificationEvidence/StaticServices", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(conversationID.uuidString + ".json")
                try JSONEncoder().encode(evidence).write(to: file, options: .atomic)
                print("FLOE_STATIC_REALVM_FAILURE_EVIDENCE=" + file.path)
            } catch { Issue.record("Could not retain synthetic service failure evidence: \(error)") }
        }

        // Async cleanup is explicitly awaited on both paths. No unstructured
        // defer Task can outlive the test and delete a still-mounted share.
        func cleanup() async throws {
            if let poller = observer {
                poller.cancel(); await poller.value; observer = nil
            }
            if let id = jobID {
                guard let job = try await jobs.job(id: id) else {
                    throw FloeError.validationFailed("Own submitted job is missing; preserve its environment until its worker is reconciled")
                }
                if !job.state.isTerminal { _ = try await jobs.cancel(id: id) }
                _ = try await waitForTerminal(jobs, id: id)
            }
            let ownID: String?
            if let id = environmentID { ownID = id }
            else { ownID = try await ownedEnvironment(root: root, app: app) }
            if let id = ownID {
                try await services.stopEnvironment(id: id)
                guard let status = await services.linuxGuestStatus(id: id), !status.running else {
                    throw FloeError.validationFailed("Own guest stop was not confirmed; preserve its layer")
                }
                try await services.deleteEnvironment(id: id)
            }
            if recordsCreated {
                try await app.conversationStore.deleteConversation(id: conversationID)
            }
            if let id = jobID {
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: ["jobs." + id.uuidString])
                center.removeDeliveredNotifications(withIdentifiers: ["jobs." + id.uuidString])
            }
            try FileManager.default.removeItem(at: root)
        }

        do {
            let date = Date()
            try await app.conversationStore.saveConversation(ConversationRecord(id: conversationID,
                title: "Static service qualification", createdAt: date, updatedAt: date, titleOrigin: .manual))
            recordsCreated = true
            let started = ISO8601DateFormatter().string(from: date)
            try await app.database.writer { database in
                try database.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'Synthetic static service qualification', ?)",
                    arguments: [runID.uuidString, conversationID.uuidString, started])
            }
            let relativeEntry = "嵌套 demo/页面 目录/预览 页面.html"
            let relativeCSS = "资源 子目录/配色 样式.css"
            let html = "<!doctype html><meta charset='utf-8'><link rel='stylesheet' href='\(relativeCSS)'><h1>FLOE_STATIC_REALVM_中文</h1>"
            let css = "h1 { color: rgb(17, 53, 97); } /* FLOE_STATIC_CSS_中文 */"
            let entry = root.appendingPathComponent(relativeEntry)
            let cssFile = entry.deletingLastPathComponent().appendingPathComponent(relativeCSS)
            try FileManager.default.createDirectory(at: cssFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(html.utf8).write(to: entry, options: .atomic)
            try Data(css.utf8).write(to: cssFile, options: .atomic)
            retainEvidence("workspace-ready")

            try await services.prepareWorkspaceEnvironment(root: root)
            environmentID = try await ownedEnvironment(root: root, app: app)
            let id = try #require(environmentID, "No own project environment was prepared")
            evidence["environmentID"] = id
            retainEvidence("activating-own-guest")
            try await services.activateLinuxGuestWithPreparation(id: id, cancellation: CancellationToken())
            try #require(await services.linuxEnvironmentAvailable(id: id), "Own guest did not become usable")

            // One submission only. A port conflict is a recorded test failure,
            // never a reason to secretly resubmit or restart another service.
            let port = Int.random(in: 20_000...45_000)
            let invocation = LocalServiceTool.Arguments(runtime: "static", entry: relativeEntry,
                arguments: [], cwd: "嵌套 demo/页面 目录", port: port)
            let submitted = try await jobs.submit(runID: runID, toolCallID: "static-qualification-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation), scope: .local,
                workspaceRootURL: root, allowedWorkspacePaths: [], environmentID: id,
                waitForCompletion: false)
            jobID = submitted.id; evidence["jobID"] = submitted.id.uuidString
            retainEvidence("submitted-once")
            let preview = try await waitForPreview(jobs, id: submitted.id)
            evidence["previewURL"] = preview.absoluteString
            try #require(preview.host == "127.0.0.1" && preview.port == port)
            #expect(preview.lastPathComponent == "预览 页面.html")
            let (htmlData, htmlResponse) = try await fetch(preview, session: session)
            try #require(htmlResponse.statusCode == 200)
            #expect(htmlData == Data(html.utf8))
            let cssReference = try #require(relativeCSS.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
            let cssURL = try #require(URL(string: cssReference, relativeTo: preview)?.absoluteURL)
            let (cssData, cssResponse) = try await fetch(cssURL, session: session)
            try #require(cssResponse.statusCode == 200)
            #expect(cssData == Data(css.utf8))
            evidence["htmlSHA256"] = FloeDigest.sha256Hex(htmlData)
            evidence["cssSHA256"] = FloeDigest.sha256Hex(cssData)
            retainEvidence("html-css-verified")

            // A consumer/observer owns polling only, not the service task.
            // This is intentionally not a SwiftUI/view-lifetime UI test.
            observer = Task { @MainActor in
                while !Task.isCancelled {
                    _ = try? await jobs.job(id: submitted.id)
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
            try await Task.sleep(for: .milliseconds(250))
            if let poller = observer { poller.cancel(); await poller.value; observer = nil }
            let (stillData, stillResponse) = try await fetch(preview, session: session)
            #expect(stillResponse.statusCode == 200 && stillData == htmlData)
            #expect(try await jobs.job(id: submitted.id)?.state.isTerminal == false)
            retainEvidence("observer-closed-service-alive")

            _ = try await jobs.cancel(id: submitted.id)
            let terminal = try await waitForTerminal(jobs, id: submitted.id)
            try #require(terminal.state == .cancelled, "Cancellation did not finish honestly: \(terminal.state.rawValue)")
            evidence["terminalState"] = terminal.state.rawValue
            let deadline = Date().addingTimeInterval(15)
            var accessible = true
            repeat {
                do { _ = try await fetch(preview, session: session); accessible = true }
                catch { accessible = false }
                if !accessible { break }
                try await Task.sleep(for: .milliseconds(250))
            } while Date() < deadline
            try #require(!accessible, "Cancelled service still has an accessible endpoint")
            retainEvidence("cancel-exit-endpoint-closed")
            try await cleanup()
            print("FLOE_STATIC_REALVM_CLEANUP_OK conversation=\(conversationID) job=\(submitted.id)")
        } catch {
            evidence["failure"] = String(describing: error)
            // Capture the OWN synthetic worker's guest-side log before cleanup.
            // A blank host 9p tail alone is not proof of no process error.
            if let id = environmentID, let ownJob = jobID, let runner = services.linuxCommandRunner() {
                do {
                    let diagnostic = try await runner.run(environmentID: id,
                        argv: ["/bin/sh", "-c", #"printf 'OWN_SERVICE_LOG\n'; cat "$1"; printf '\nPYTHON_CHECK\n'; python3 -c 'import sys,http.server; print(sys.version)'"#,
                               "static-qualification-diagnostic", "/floe/env/services/" + ownJob.uuidString + ".log"],
                        workingDirectory: "/workspace", standardInput: nil, timeout: 30,
                        maxOutputBytes: 16_384, cancellation: CancellationToken())
                    evidence["guestDiagnostic"] = String(describing: diagnostic)
                } catch { evidence["guestDiagnosticError"] = String(describing: error) }
            }
            retainEvidence("failed")
            retainFailureEvidence()
            do { try await cleanup() }
            catch {
                evidence["cleanupFailure"] = String(describing: error)
                retainEvidence("cleanup-preserved")
                retainFailureEvidence()
                Issue.record("Own service cleanup incomplete; retained qualification workspace: \(root.path)")
            }
            throw error
        }
    }
}
#endif
