// FloeExecution — Internal JavaScript package resources.
//
// The model-facing `exec.javascript` tool is retired. The remaining production
// JavaScript consumer is the PDF form processor (PDFFillFormTool), which needs
// pdf-lib. The five generic packages that were bundled only for the retired
// tool (lodash, dayjs, marked, uuid, zod) are no longer packaged; keeping their
// resources would ship dead payload. Packages are still loaded from the app
// bundle and injected into the JSContext before the internal script runs.

import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
import Security
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
    /// The internal PDF processor's package set. The generic language
    /// packages were retired with exec.javascript and are deliberately not
    /// listed here anymore.
    public static let preInstalled: [JSPackage] = [
        JSPackage(name: "pdf-lib", globalName: "PDFLib", resourceName: "pdf-lib.min")
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
    public static func inject(
        into context: JSContext,
        sourceProvider: (JSPackage) -> String? = { source(for: $0) }
    ) {
        // Expose only a bounded native byte source for package code that
        // probes WebCrypto; no native objects cross the bridge.
        let randomBytes: @convention(block) (Int) -> [UInt8]? = { count in
            guard (0...65_536).contains(count) else { return nil }
            var bytes = [UInt8](repeating: 0, count: count)
            guard count > 0 else { return bytes }
            let status = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
            }
            return status == errSecSuccess ? bytes : nil
        }
        context.setObject(randomBytes, forKeyedSubscript: "__floeRandomBytes" as NSString)
        context.evaluateScript("""
            var crypto = { getRandomValues: function(array) {
                if (!(array instanceof Uint8Array) || array.length > 65536) {
                    throw new TypeError('Expected a Uint8Array of at most 65536 bytes');
                }
                var bytes = __floeRandomBytes(array.length);
                if (!bytes) throw new Error('Secure randomness unavailable');
                array.set(bytes);
                return array;
            }};
            """)
        // JavaScriptCore has no event-loop timers. pdf-lib (and some other
        // libraries) reference setTimeout in otherwise microtask-driven code
        // paths, so provide a microtask-backed shim before any package runs.
        context.evaluateScript("""
            if (typeof setTimeout === 'undefined') {
                var setTimeout = function(fn) { Promise.resolve().then(function(){ fn(); }); return 0; };
            }
            if (typeof clearTimeout === 'undefined') {
                var clearTimeout = function() {};
            }
            """)
        for package in preInstalled {
            guard let source = sourceProvider(package) else { continue }
            context.evaluateScript(source)
        }
    }
    #endif
}
