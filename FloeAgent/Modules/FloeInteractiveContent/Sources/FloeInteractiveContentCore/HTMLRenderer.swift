// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum InteractiveHTML {
    public static let childCSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"

    public static func render(document: InteractiveDocument, seed: RuntimeSeed) throws -> String {
        try document.validate()
        try seed.state.validate(for: document)
        return try shell(document: document, state: seed.state, leaseID: seed.leaseID, native: true)
    }

    public static func export(document: InteractiveDocument, state: InteractiveState) throws -> Data {
        try document.validate()
        try state.validate(for: document)
        // A new, browser-local lease. Host/conversation/run/message IDs never enter the file.
        return Data(try shell(document: document, state: state, leaseID: UUID(), native: false).utf8)
    }

    public static func exportData(document: InteractiveDocument, state: InteractiveState) throws -> Data {
        try state.validate(for: document)
        let value = ExportData(version: 1, title: document.title, kind: document.kind,
                               modelContent: state.modelContent, privateContent: state.privateContent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }

    private struct ExportData: Codable {
        let version: Int
        let title: String
        let kind: String
        let modelContent: JSONValue
        let privateContent: JSONValue
    }

    private struct Payload: Encodable {
        let version = 1
        let leaseID: String
        let revision: UInt64
        let modelContent: JSONValue
        let privateContent: JSONValue
        let native: Bool
    }

    private static func resource(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw InteractiveError.missingResource
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func shell(document: InteractiveDocument, state: InteractiveState,
                              leaseID: UUID, native: Bool) throws -> String {
        let client = try resource("client")
        let host = try resource("host")
        let payload = Payload(leaseID: leaseID.uuidString, revision: state.revision,
                              modelContent: state.modelContent, privateContent: state.privateContent, native: native)
        let encoded = try JSONEncoder().encode(payload).base64EncodedString()
        let child = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(childCSP)">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        :root{color-scheme:light dark;--background:light-dark(#fff,#1c1c1e);--foreground:light-dark(#202124,#f3f3f3);--muted:light-dark(#efeff2,#303034);--accent:light-dark(#2563c5,#8bb7ff)}
        *{box-sizing:border-box}body{font:16px system-ui,-apple-system,sans-serif;margin:0;padding:16px;color:var(--foreground);background:var(--background)}
        button,input,select{font:inherit;min-height:44px}button{cursor:pointer;padding:8px 14px}input[type=range]{width:100%}
        label{display:block;margin:12px 0 6px}output{font-variant-numeric:tabular-nums}svg{display:block;width:100%;height:auto}
        .row{display:flex;gap:12px;align-items:center;flex-wrap:wrap}.muted{opacity:.72}.value{font-size:1.5em;font-weight:600;margin:12px 0}
        </style>
        <script>\(client)</script></head><body>\(document.html)</body></html>
        """
        let child64 = Data(child.utf8).base64EncodedString()
        // Only base64 enters the trusted shell script; model HTML/title never gets concatenated here.
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src about:; connect-src 'none'; img-src data: blob:; object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(document.title))</title>
        <style>html,body{margin:0;padding:0;color-scheme:light dark}iframe{border:0;width:100%;height:360px;display:block}#fallback{font:16px system-ui;padding:16px;white-space:pre-wrap}</style>
        </head><body><iframe id="content" title="\(escape(document.title))" sandbox="allow-scripts"></iframe>
        <noscript><div id="fallback">\(escape(document.fallbackText))</div></noscript>
        <script>(function(){'use strict';
        const decode=function(s){return new TextDecoder().decode(Uint8Array.from(atob(s),function(c){return c.charCodeAt(0)}))};
        const seed=JSON.parse(decode('\(encoded)'));
        const childHTML=decode('\(child64)');
        \(host)
        })();</script></body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
