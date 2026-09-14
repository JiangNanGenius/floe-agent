import SwiftUI

@main struct PythonSmokeApp: App {
    var body: some Scene {
        WindowGroup { Text("Embedded Python package qualification").task { await Task.detached { qualify() }.value } }
    }
}

func qualify() {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let layer = documents.appendingPathComponent(UUID().uuidString)
    let target = layer.appendingPathComponent("usr/lib/floe-python/site-packages")
    var results: [[String: Any]] = []
    do {
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        let resource = Bundle.main.url(forResource: "managed_package_install", withExtension: "py")!
        let installer = try String(contentsOf: resource, encoding: .utf8)
        let context: [String: Any] = ["environmentID": "native-package-qualification", "workingDirectory": layer.path,
            "environment": ["FLOE_PYTHON_PACKAGE_TARGET": target.path, "FLOE_PYTHON_WRITABLE_LAYER": layer.path, "PYTHONPATH": target.path]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
        for version in ["0.4.6", "0.4.5", "0.4.6"] {
            let script = installer + "\ninstall(['colorama==\(version)'], Path(os.environ['FLOE_PYTHON_PACKAGE_TARGET']))\n"
            let response = FloeCPythonBridge.runScript(script, inputJSON: nil, contextJSON: json,
                timeout: 180, maxOutputBytes: 65536, allowPackageInstaller: true, shouldCancel: nil)
            var step: [String: Any] = ["version": version, "response": response]
            let directories = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            step["metadataDirectories"] = try directories.filter { $0.lastPathComponent.hasSuffix(".dist-info") }.map { directory in
                ["name": directory.lastPathComponent,
                 "entries": try FileManager.default.contentsOfDirectory(atPath: directory.path),
                 "metadataExists": FileManager.default.fileExists(atPath: directory.appendingPathComponent("METADATA").path)] as [String: Any]
            }
            results.append(step)
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: documents.appendingPathComponent("python-package-results.json"), options: .atomic)
        }
        let imported = FloeCPythonBridge.runScript("import colorama; print(colorama.__version__)", inputJSON: nil,
            contextJSON: json, timeout: 10, maxOutputBytes: 4096, allowPackageInstaller: false, shouldCancel: nil)
        results.append(["step": "import", "response": imported])
        let remover = try String(contentsOf: Bundle.main.url(forResource: "managed_package_remove", withExtension: "py")!, encoding: .utf8)
        let removed = FloeCPythonBridge.runScript(remover, inputJSON: "{\"distribution\":\"colorama\"}",
            contextJSON: json, timeout: 30, maxOutputBytes: 4096, allowPackageInstaller: true, shouldCancel: nil)
        let remaining = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".dist-info") }.map(\.lastPathComponent)
        results.append(["step": "remove", "response": removed, "remainingDistributions": remaining])
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: documents.appendingPathComponent("python-package-results.json"), options: .atomic)
    } catch {
        results.append(["error": error.localizedDescription])
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: documents.appendingPathComponent("python-package-results.json"), options: .atomic)
        }
    }
}
