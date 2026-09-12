import SwiftUI
import FloeExecution
import FloeTools
@main struct SmokeApp: App {
 var body: some Scene { WindowGroup { Text("Floe Node smoke").task { await Task.detached { runSmoke() }.value; await runAdapterSmoke() } } }
}
func runSmoke() {
 let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
 var results: [[String: Any]] = []
 let initialCWD = FileManager.default.currentDirectoryPath
 try? Data("scoped-file".utf8).write(to: root.appendingPathComponent("value.txt"))
 let cases = ["console.log(process.env.FLOE_TEST)", "process.stdin.on('data',b=>process.stdout.write(b));", "process.stdout.write('x'.repeat(100000));", "while(true){}", "console.log('alive')", "process.stdout.write(require('fs').readFileSync(0))", "while(true){}", "console.log('after-cancel')", "console.log(require('fs').readFileSync('value.txt','utf8')); setTimeout(()=>{},100)"]
 for (index, source) in cases.enumerated() {
  var out: NSString?, err: NSString?, code: Int32 = -1
  var truncated: ObjCBool = false
  let started = Date()
  var cwdChanged = false
  let status = FloeNodeRun(nil, ["-e",source], root.path, ["FLOE_TEST":"scoped", "FLOE_ENVIRONMENT_ID":"qualification"], Data("input-data".utf8), index == 3 ? 0.1 : 5, 100, {
   if FileManager.default.currentDirectoryPath != initialCWD { cwdChanged = true }
   return index == 6 && Date().timeIntervalSince(started) > 0.1
  }, &out, &err, &code, &truncated)
  results.append(["index":index,"status":status.rawValue,"exit":code,"stdout":out ?? "","stderr":err ?? "", "truncated":truncated.boolValue, "workerStopped":!FloeNodeHasActiveTask("qualification"), "processCwdPreserved": !cwdChanged && FileManager.default.currentDirectoryPath == initialCWD])
  if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted) { try? data.write(to: root.appendingPathComponent("node-results.json"), options: .atomic) }
 }
}

func runAdapterSmoke() async {
 let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
 let runtime = IOSSystemNodeRuntime.shared
 var checks: [String: Bool] = [:]
 let request = NodeRunRequest(entryScript: nil, arguments: ["-e", "process.stdout.write(require('fs').readFileSync(0))"], workingDirectory: root, stdin: "adapter-input", timeout: 5, maxOutputBytes: 100)
 let result = await runtime.run(request, cancellation: nil)
 if case .exited(let code, let stdout, _, _, _) = result { checks["stdinThroughAdapter"] = code == 0 && stdout == "adapter-input" } else { checks["stdinThroughAdapter"] = false }
 var invalid = request; invalid.maxOutputBytes = -1
 if case .failed = await runtime.run(invalid, cancellation: nil) { checks["rejectsNegativeLimit"] = true } else { checks["rejectsNegativeLimit"] = false }
 var endless = request; endless.arguments = ["-e", "while(true){}"]
 endless.timeout = 0.1
 if case .timedOut = await runtime.run(endless, cancellation: nil) { checks["timeoutThroughAdapter"] = true } else { checks["timeoutThroughAdapter"] = false }
 endless.timeout = 5
 let cancellation = CancellationToken()
 let trigger = Task { try? await Task.sleep(for: .milliseconds(100)); cancellation.cancel() }
 if case .cancelled = await runtime.run(endless, cancellation: cancellation) { checks["cancelThroughAdapter"] = true } else { checks["cancelThroughAdapter"] = false }
 trigger.cancel()
 checks["passed"] = checks.values.allSatisfy { $0 }
 if let data = try? JSONEncoder().encode(checks) { try? data.write(to: root.appendingPathComponent("node-adapter-results.json"), options: .atomic) }
}
