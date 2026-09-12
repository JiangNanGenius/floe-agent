import Foundation
import WAT
let arguments = CommandLine.arguments
if arguments.count != 3 { fatalError("usage: CapabilityAssembler INPUT.wat OUTPUT.wasm") }
let text = try String(contentsOfFile: arguments[1], encoding: .utf8)
try Data(wat2wasm(text)).write(to: URL(fileURLWithPath: arguments[2]))
