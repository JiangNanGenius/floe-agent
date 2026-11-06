// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeInteractiveContentCore

guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
    FileHandle.standardError.write(Data("Usage: floe-interactive-examples /absolute/output/directory\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for example in InteractiveExample.allCases {
    let owner = ContentOwner(conversationID: UUID(), runID: UUID(), messageID: UUID())
    let document = try InteractiveExamples.document(example, owner: owner)
    let state = InteractiveState(document: document)
    try InteractiveHTML.export(document: document, state: state)
        .write(to: directory.appendingPathComponent(example.rawValue + ".html"), options: .atomic)
    try InteractiveHTML.exportData(document: document, state: state)
        .write(to: directory.appendingPathComponent(example.rawValue + ".json"), options: .atomic)
}
print("Exported five standalone interactive examples and data snapshots.")
