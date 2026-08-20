// FloeExecution — Pre-installed pure-JS npm packages for the agent.
//
// Bundles a curated set of high-frequency, pure-JavaScript npm packages
// (lodash, dayjs, marked, uuid, zod) as resource files so the agent can
// use them in exec.javascript without network access. Packages are loaded
// from the app bundle and injected into the JSContext before the user
// script runs.

import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// A pre-installed JS package: name, global variable it exposes, and the
/// bundled resource file name.
public struct JSPackage: Sendable {
    public let name: String
    public let globalName: String
    public let resourceName: String

    public init(name: String, globalName: String, resourceName: String) {
        self.name = name
        self.globalName = globalName
        self.resourceName = resourceName
    }
}

/// Pre-installed packages, keyed by package name.
public enum JSPackages {
    /// The curated set of pre-installed packages. Each is a pure-JS,
    /// zero-dependency (or dependency-bundled) UMD build that works in
    /// JavaScriptCore without Node APIs.
    public static let preInstalled: [JSPackage] = [
        JSPackage(name: "lodash", globalName: "_", resourceName: "lodash.min"),
        JSPackage(name: "dayjs", globalName: "dayjs", resourceName: "dayjs.min"),
        JSPackage(name: "marked", globalName: "marked", resourceName: "marked.min"),
        JSPackage(name: "uuid", globalName: "uuid", resourceName: "uuid.min"),
        JSPackage(name: "zod", globalName: "z", resourceName: "zod.min")
    ]

    /// Loads a package's source from the app bundle.
    public static func source(for package: JSPackage) -> String? {
        guard let url = Bundle.main.url(forResource: package.resourceName, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return source
    }

    /// Injects all pre-installed packages into a JSContext.
    /// Each package's source is evaluated, and its global name is bound.
    #if canImport(JavaScriptCore)
    public static func inject(into context: JSContext) {
        for package in preInstalled {
            guard let source = source(for: package) else { continue }
            context.evaluateScript(source)
        }
    }
    #endif
}
