// FloeApp — guest runtime assembly (TinyEMU Linux backend).
//
// Builds the app's one guest-routed `LocalPythonService` and owns the
// recoverable reinstall of preserved native-era Python packages into the
// guest venv after a cold start (docs/PHASE2_migration.md §3.2). The legacy
// directory is never placed on PYTHONPATH and never deleted.

import Foundation
import FloeCore
import FloeExecution
import FloeTools

enum LocalPythonServiceFactory {
    /// Builds the app's one `LocalPythonService`: every request routes into
    /// the task environment's TinyEMU Linux guest. Returns nil only when no
    /// Linux backend exists in this build, leaving `exec.localPython`
    /// honestly absent from the catalog.
    static func make(
        linuxGuests: TinyEMULinuxCommandService?,
        prepareLinux: LinuxPreparationHandler? = nil
    ) -> LocalPythonService? {
        guard let linuxGuests else { return nil }
        return LocalPythonService(version: "Python 3 (Linux guest)") { request, cancellation in
            guard let environmentID = request.pythonContext?.environmentID,
                  !environmentID.isEmpty else {
                return .jsException(
                    message: "Local Python runs inside a task's Linux environment; no environment was selected",
                    stdout: ""
                )
            }
            return await GuestPythonRuntime.run(
                request,
                environmentID: environmentID,
                guests: linuxGuests,
                controller: linuxGuests,
                onColdStart: { id in
                    await LegacyPythonPackageMigration.seedIfNeeded(environmentID: id, runner: linuxGuests)
                },
                prepareLinux: prepareLinux,
                cancellation: cancellation
            )
        }
    }
}

/// Reinstalls preserved native-era Python distributions into the guest venv.
/// Best-effort and recoverable: a failure is recorded in the marker and in
/// the log, the legacy files stay untouched, and the package UI can reinstall
/// the same `name==version` specs at any time.
enum LegacyPythonPackageMigration {
    /// Marker in the environment layer recording the seed outcome.
    private static let markerRelativePath = "var/floe-legacy-python-seeded.json"

    private struct Marker: Codable {
        var seededAt: Date
        var specs: [String]
        var outcome: String
    }

    /// Reads the preserved native-era installs from the layer's
    /// `usr/lib/floe-python/site-packages` dist-info metadata (the same
    /// source the retired native inventory used), capped and validated.
    static func legacySpecs(layerURL: URL) -> [String] {
        let root = layerURL.standardizedFileURL
            .appendingPathComponent("usr/lib/floe-python/site-packages", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var specs: [String] = []
        for entry in entries where entry.hasSuffix(".dist-info") {
            let metadata = root.appendingPathComponent(entry).appendingPathComponent("METADATA")
            guard let data = try? Data(contentsOf: metadata), data.count <= 2 * 1024 * 1024 else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let name = text.components(separatedBy: .newlines)
                .first { $0.hasPrefix("Name: ") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            let version = text.components(separatedBy: .newlines)
                .first { $0.hasPrefix("Version: ") }.map { String($0.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
            guard let name, !name.isEmpty else { continue }
            // Only well-formed PyPI names/versions cross into a pip argv.
            guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { continue }
            if let version, version.range(of: #"^[A-Za-z0-9][A-Za-z0-9.+_-]*$"#, options: .regularExpression) != nil {
                specs.append("\(name)==\(version)")
            } else {
                specs.append(name)
            }
            if specs.count >= 64 { break }
        }
        return specs.sorted()
    }

    static func seedIfNeeded(environmentID: String, runner: any LinuxCommandRunning) async {
        guard let layer = await FloePlatformServices.shared.layerURL(for: environmentID) else { return }
        let markerURL = layer.appendingPathComponent(markerRelativePath)
        if FileManager.default.fileExists(atPath: markerURL.path) { return }
        let specs = legacySpecs(layerURL: layer)
        guard !specs.isEmpty else {
            writeMarker(markerURL, specs: [], outcome: "nothing-to-seed")
            return
        }
        do {
            _ = try await LinuxGuestLanguagePackages(runner: runner).pythonInstall(
                specs: specs,
                environment: ToolEnvironment(id: environmentID, writableLayerURL: layer, layerURLs: [layer], variables: [:]),
                timeout: 600,
                cancellation: nil
            )
            writeMarker(markerURL, specs: specs, outcome: "seeded")
            FloeLogger(category: .tools).info(
                "Legacy Python packages reinstalled into guest venv environment=\(environmentID) count=\(specs.count)"
            )
        } catch {
            writeMarker(markerURL, specs: specs, outcome: "failed: \(error.localizedDescription)")
            FloeLogger(category: .tools).error(
                "Legacy Python package seeding failed environment=\(environmentID) error=\(error.localizedDescription)"
            )
        }
    }

    private static func writeMarker(_ url: URL, specs: [String], outcome: String) {
        let marker = Marker(seededAt: Date(), specs: specs, outcome: outcome)
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
