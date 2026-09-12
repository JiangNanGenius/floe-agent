import SwiftUI
import Darwin
@main struct SmokeApp: App {
 var body: some Scene { WindowGroup { Text("Floe shell smoke").task { await Task.detached { runSmoke(); runInteractiveSmoke() }.value } } }
}
func runSmoke() {
 let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
 var results: [[String: Any]] = []
 try? Data("[]".utf8).write(to: root.appendingPathComponent("shell-results.json"), options: .atomic)
 let commands = ["dash -c 'for x in hello world; do echo \"$x\"; done | tr a-z A-Z'", "dash -c 'cat; exit 7'", "dash -c 'printf %s \"$FLOE_SHELL_TEST_SCOPE\"'", "dash -c 'printf %s \"${FLOE_SHELL_TEST_SCOPE-unset}\"'"]
 var expanded = commands
 expanded += ["dash -c 'printf \"one\\ntwo\\n\" | tr a-z A-Z | sed s/ONE/FIRST/'", "dash -c 'floe_nonexistent_command_qualification'", "dash -c 'while :; do :; done'"]
 expanded += ["dash -c 'echo after-cancel'", "dash -c 'while :; do :; done'"]
 for index in [2, 3, 1, 0, 4, 5, 6, 7, 8] {
  let command = expanded[index]
  var out: NSString?, err: NSString?, code: Int32 = -1
  let env: [String: String] = index == 2 ? ["FLOE_SHELL_TEST_SCOPE": "scoped"] : [:]
  let input = index == 1 ? Data(String(repeating: "a", count: 32768).utf8) : nil
  let sessionID = UUID().uuidString
  let started = Date()
  let status = FloeShellRunCommand(command, root.path, root.path, sessionID, env, input, index == 8 ? 0.2 : 5, 100, { index == 6 && Date().timeIntervalSince(started) > 0.2 }, &out, &err, &code)
  let deadline = Date().addingTimeInterval(3)
  while FloeShellHasActiveWorker(sessionID) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
  results.append(["index":index,"status":status.rawValue,"exit":code,"stdout":out ?? "","stderr":err ?? "", "workerStopped": !FloeShellHasActiveWorker(sessionID)])
  if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted) { try? data.write(to: root.appendingPathComponent("shell-results.json"), options: .atomic) }
 }
 if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted) { try? data.write(to: root.appendingPathComponent("shell-results.json"), options: .atomic) }
}
func runInteractiveSmoke() {
 let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
 let id = UUID().uuidString
 var input: Int32 = -1, output: Int32 = -1
 var initial: NSString?
 let opened = FloeShellOpenSession("dash -c 'read line; printf \"received:%s\" \"$line\"'", root.path, root.path, id, [:], 80, 24, &input, &output, &initial)
 var data = Data()
 if opened {
  let bytes = Data("interactive\n".utf8)
  _ = bytes.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
  let deadline = Date().addingTimeInterval(3)
  var buffer = [UInt8](repeating: 0, count: 1024)
  repeat {
   let count = Darwin.read(output, &buffer, buffer.count)
   if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
   if String(decoding: data, as: UTF8.self).contains("received:interactive") { break }
   Thread.sleep(forTimeInterval: 0.01)
  } while Date() < deadline
  FloeShellCloseSession(id)
 }
 let deadline = Date().addingTimeInterval(3)
 while FloeShellHasActiveWorker(id) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
 let text = String(decoding: data, as: UTF8.self)
 let result: [String: Any] = ["opened":opened,"stdout":text,"workerStopped":!FloeShellHasActiveWorker(id),"passed":opened && text.contains("received:interactive") && !FloeShellHasActiveWorker(id)]
 if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) { try? data.write(to: root.appendingPathComponent("shell-interactive-results.json"), options: .atomic) }
}
@_cdecl("floe_shell_command_main")
func commandMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 { 127 }
