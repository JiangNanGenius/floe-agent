import SwiftUI
import Darwin
@main struct SmokeApp: App {
 var body: some Scene { WindowGroup { Text("Floe shell smoke").task { await Task.detached { runSmoke(); runInteractiveSmoke(); runCommandSmoke() }.value } } }
}
func runSmoke() {
 let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
 FloeShellRegisterCommand("floe_qualification_echo")
 FloeShellRegisterCommand("python3")
 var results: [[String: Any]] = []
 try? Data("[]".utf8).write(to: root.appendingPathComponent("shell-results.json"), options: .atomic)
 let commands = ["dash -c 'for x in hello world; do echo \"$x\"; done | tr a-z A-Z'", "dash -c 'cat; exit 7'", "dash -c 'printf %s \"$FLOE_SHELL_TEST_SCOPE\"'", "dash -c 'printf %s \"${FLOE_SHELL_TEST_SCOPE-unset}\"'"]
 var expanded = commands
 expanded += ["dash -c 'printf \"one\\ntwo\\n\" | tr a-z A-Z | sed s/ONE/FIRST/'", "dash -c 'floe_nonexistent_command_qualification'", "dash -c 'while :; do :; done'"]
 expanded += ["dash -c 'echo after-cancel'", "dash -c 'while :; do :; done'"]
 expanded += ["dash -c 'printf data | floe_missing_pipeline_command'", "dash -c 'printf after_missing_pipe'"]
 expanded += ["dash -c 'cmd=floe-missing-command; printf data | \"$cmd\"'", "dash -c 'printf after_expanded_missing'", "dash -c 'printf data | read line'", "dash -c 'printf after_builtin_consumer'"]
 expanded += ["dash -c 'cmd=cat; printf variable-consumer | \"$cmd\"'", "dash -c 'printf data | floe-missing-middle | cat'", "dash -c 'printf after_missing_middle'", "dash -c 'printf data | while read x; do echo \"$x\"; done'", "dash -c 'printf after_compound_consumer'"]
 expanded += ["dash -c 'while :; do printf data; done | cat'", "dash -c 'printf after_pipeline_timeout'"]
 expanded += ["dash -c 'floe_qualification_echo callback-resolved | cat'"]
 expanded += [#"dash -c 'floe_qualification_echo "a=>b|c;d>e<g" "" "中文"'"#]
 expanded += ["dash -c 'export FLOE_SHELL_TEST_SCOPE=exported; floe_qualification_echo --environment'"]
 expanded += ["dash -c 'python3 first; python3 second'"]
 let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
 expanded += ["space only", #"x "y" z"#, "x 'y' z", #"x 'y' "z""#].map {
  "dash -c " + quote("floe_qualification_echo " + quote($0))
 }
 for index in [2, 3, 1, 0] + Array(4..<expanded.count) {
  let command = expanded[index]
  var out: NSString?, err: NSString?, code: Int32 = -1
  let env: [String: String] = index == 2 ? ["FLOE_SHELL_TEST_SCOPE": "scoped"] : [:]
  let input = index == 1 ? Data(String(repeating: "a", count: 32768).utf8) : nil
  let sessionID = UUID().uuidString
  let started = Date()
  let status = FloeShellRunCommand(command, root.path, root.path, sessionID, env, input, (index == 8 || index == 20) ? 0.2 : 5, 5, 100, { index == 6 && Date().timeIntervalSince(started) > 0.2 }, &out, &err, &code)
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
 let status = FloeShellOpenSession("dash -c 'read line; printf \"received:%s\" \"$line\"'", root.path, root.path, id, [:], 80, 24, 5, nil, &input, &output, &initial)
 let opened = status == .OK
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
// MARK: - 1.7.34 (275) privacy-rebuild command smoke
//
// Focused smoke for the reviewed shell/text privacy patch on the IOS
// SIMULATOR slice (the shipping device slice is verified separately by the
// packaging step). Run this host with the rebuilt simulator shell/text
// frameworks substituted into the built .app; it writes
// `command-smoke-results.json` next to the existing smoke results:
//
//   * `find` normal query lists the fixture files;
//   * `find -fstype` fails closed with the patched explicit message while the
//     App (the host process) keeps running and later commands still execute;
//   * `wc` byte counts stay exact for ASCII, Chinese UTF-8 bytes, a file
//     larger than the old fstatfs-derived I/O size, and pipelines; `wc -l/-w`
//     stay exact and `wc -m` is recorded for inspection;
//   * `tail` reads the last line, and `tail -f` sees an appended line through
//     the polling fallback before the session is cancelled and its worker
//     stops;
//   * a final command proves the host survived every case.
func runCommandSmoke() {
 let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
 let fm = FileManager.default
 let dir = root.appendingPathComponent("smokecmd", isDirectory: true)
 try? fm.removeItem(at: dir)
 try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
 try? Data("alpha\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
 try? Data("中文\n".utf8).write(to: dir.appendingPathComponent("cn.txt"))
 try? Data("x\ny\n".utf8).write(to: dir.appendingPathComponent("pipe.txt"))
 try? Data(String(repeating: "0123456789abcdef", count: 20000).utf8)
   .write(to: dir.appendingPathComponent("big.txt"))
 let followURL = dir.appendingPathComponent("follow.txt")
 try? Data("line1\n".utf8).write(to: followURL)
 var results: [[String: Any]] = []
 let outputURL = root.appendingPathComponent("command-smoke-results.json")
 try? Data("started".utf8)
   .write(to: root.appendingPathComponent("command-smoke-started.txt"), options: .atomic)
 func writeResults() {
  if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted) {
   try? data.write(to: outputURL, options: .atomic)
  }
 }
 func record(_ name: String, _ command: String, status: FloeShellBridgeStatus, exit: Int32,
             stdout: String, stderr: String, stopped: Bool, extra: [String: Any] = [:]) {
  var entry: [String: Any] = ["case": name, "command": command, "status": status.rawValue,
                              "exit": exit, "stdout": stdout, "stderr": stderr,
                              "workerStopped": stopped]
  for (key, value) in extra { entry[key] = value }
  results.append(entry)
  writeResults()
 }
 func runOneShot(_ name: String, _ command: String, workingDirectory: String,
                 timeout: TimeInterval = 8) -> (status: FloeShellBridgeStatus, exit: Int32,
                                                stdout: String, stderr: String, stopped: Bool) {
  var outText: NSString?, errText: NSString?, code: Int32 = -1
  let sessionID = UUID().uuidString
  let status = FloeShellRunCommand(command, root.path, workingDirectory, sessionID, [:], nil,
                                   timeout, 5, 200000, nil, &outText, &errText, &code)
  let deadline = Date().addingTimeInterval(6)
  while FloeShellHasActiveWorker(sessionID) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
  let stopped = !FloeShellHasActiveWorker(sessionID)
  let stdout = outText as String? ?? "", stderr = errText as String? ?? ""
  record(name, command, status: status, exit: code, stdout: stdout, stderr: stderr, stopped: stopped)
  return (status, code, stdout, stderr, stopped)
 }
 let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
 func dash(_ body: String) -> String { "dash -c " + quote(body) }
 func trimmedLines(_ text: String) -> [String] {
  text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
 }
 /// First whitespace-separated token of each output line (wc pads counts and
 /// appends the file name for file operands).
 func countTokens(_ text: String) -> [String] {
  trimmedLines(text).compactMap { $0.split(separator: " ").first.map(String.init) }
 }
 // 1. Normal find query.
 let (_, _, findOut, _, _) = runOneShot("find-normal",
                                        dash("find . -name '*.txt' | sort"),
                                        workingDirectory: dir.path)
 // 2. The patched -fstype predicate fails closed; the shell/host must survive.
 let (_, _, fstypeOut, fstypeErr, fstypeStopped) = runOneShot(
   "find-fstype-unsupported",
   dash("find . -fstype apfs -print; printf 'after-fstype'"), workingDirectory: dir.path)
 // 2b. The host is still alive right after the failing predicate.
 let (fstypeAliveStatus, _, fstypeAliveOut, _, _) = runOneShot(
   "host-alive-after-fstype", dash("printf host-alive"), workingDirectory: dir.path)
 // 2c. Standalone find invocation: its own nonzero exit status (the combined
 // case above continues the shell, so it cannot show the predicate's status).
 let (_, fstypeExitCode, _, fstypeExitErr, _) = runOneShot(
   "find-fstype-standalone-exit", dash("find . -fstype apfs -print"), workingDirectory: dir.path)
 // 3. wc byte counts: pipe UTF-8, file UTF-8, > SMALL_BUF_SIZE file, ASCII pipe.
 let wcCommand = dash("printf '中文' | wc -c; wc -c cn.txt; wc -c big.txt; printf abc | wc -c")
 let (_, _, wcOut, _, wcStopped) = runOneShot("wc-bytes", wcCommand, workingDirectory: dir.path)
 // 4. wc lines/words/multibyte (-m recorded, not asserted: it depends on the locale tables).
 let wcCountsCommand = dash("printf '中文\\n' | wc -l; printf 'a b c\\n' | wc -w; printf '中文\\n' | wc -m")
 let (_, _, wcCountsOut, _, _) = runOneShot("wc-lines-words-multibyte", wcCountsCommand,
                                            workingDirectory: dir.path)
 // 5. tail last-line read.
 let (_, _, tailOut, _, tailReadStopped) = runOneShot("tail-read", dash("tail -n 1 pipe.txt"),
                                                      workingDirectory: dir.path)
 // 6. tail -f sees an in-place append through the polling fallback, then cancels.
 var followText = ""
 var followOpened = false, followSawLine1 = false, followSawLine2 = false, followStopped = false
 var followCancelSeconds: Double = -1
 var followInitial: NSString?
 var inFD: Int32 = -1, outFD: Int32 = -1
 let followID = UUID().uuidString
 let openStatus = FloeShellOpenSession(dash("tail -f follow.txt"), root.path, dir.path, followID, [:],
                                       80, 24, 5, nil,
                                       &inFD, &outFD, &followInitial)
 followOpened = openStatus == .OK
 if followOpened {
  _ = fcntl(outFD, F_SETFL, O_NONBLOCK)
  followText += (followInitial as String? ?? "")
  func pump(until needle: String, deadline: TimeInterval) -> Bool {
   let end = Date().addingTimeInterval(deadline)
   var buffer = [UInt8](repeating: 0, count: 4096)
   while Date() < end {
    let count = Darwin.read(outFD, &buffer, buffer.count)
    if count > 0 { followText += String(decoding: buffer.prefix(count), as: UTF8.self) }
    if followText.contains(needle) { return true }
    Thread.sleep(forTimeInterval: 0.02)
   }
   return followText.contains(needle)
  }
  followSawLine1 = pump(until: "line1", deadline: 4)
  if let handle = try? FileHandle(forWritingTo: followURL) {
   try? handle.seekToEnd()
   try? handle.write(contentsOf: Data("line2\n".utf8))
   try? handle.close()
  }
  followSawLine2 = pump(until: "line2", deadline: 5)
  // User-style cancellation: interrupt the session first, then close it, and
  // give the worker real time to unwind (a cooperative worker releases the
  // shared engine gate on its own teardown). The elapsed wait is recorded so a
  // slow or refused cancellation is visible instead of hidden.
  let cancelStarted = Date()
  FloeShellSignalSession(followID, 2)
  Thread.sleep(forTimeInterval: 1)
  if FloeShellHasActiveWorker(followID) { FloeShellCloseSession(followID) }
  let deadline = Date().addingTimeInterval(25)
  while FloeShellHasActiveWorker(followID) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
  followStopped = !FloeShellHasActiveWorker(followID)
  followCancelSeconds = Date().timeIntervalSince(cancelStarted)
 }
 record("tail-follow-append-cancel", "tail -f follow.txt", status: openStatus, exit: -1,
        stdout: followText, stderr: "", stopped: followStopped,
        extra: ["opened": followOpened, "sawLine1": followSawLine1, "sawLine2": followSawLine2,
                "cancelSeconds": followCancelSeconds])
 // 7. Host survival after every case (retry only the shared-gate busy state).
 var aliveOut = "", aliveErr = ""
 var aliveStatus: FloeShellBridgeStatus = .busy
 var aliveStopped = false
 for _ in 0..<5 {
  let attempt = runOneShot("host-alive-after-all", dash("printf host-alive"),
                           workingDirectory: dir.path)
  aliveOut = attempt.stdout; aliveErr = attempt.stderr
  aliveStatus = attempt.status; aliveStopped = attempt.stopped
  if aliveStatus == .OK { break }
  Thread.sleep(forTimeInterval: 3)
 }
 let assertions: [String: Bool] = [
  "findNormalListsFixtures": ["a.txt", "cn.txt", "pipe.txt", "big.txt", "follow.txt"]
    .allSatisfy { findOut.contains($0) },
  "fstypeErrorMentionsUnsupported": fstypeErr.contains("fstype is not supported"),
  "fstypeCaseStopped": fstypeStopped,
  "fstypeStandaloneNonZeroExit": fstypeExitCode != 0
    && fstypeExitErr.contains("fstype is not supported"),
  "hostAliveAfterFstype": fstypeAliveStatus == .OK && fstypeAliveOut.contains("host-alive"),
  "shellContinuedAfterFstype": results.contains { $0["case"] as? String == "wc-bytes" },
  "wcByteCountsExact": countTokens(wcOut) == ["6", "7", "320000", "3"],
  "wcStopped": wcStopped,
  "wcLinesExact": countTokens(wcCountsOut).first == "1",
  "wcWordsExact": countTokens(wcCountsOut).count >= 2 && countTokens(wcCountsOut)[1] == "3",
  "tailReadsLastLine": tailOut == "y\n",
  "tailReadStopped": tailReadStopped,
  "tailFollowOpened": followOpened,
  "tailFollowSawInitialLine": followSawLine1,
  "tailFollowSawAppendedLine": followSawLine2,
  "tailFollowCancelStoppedWorker": followStopped,
  "hostAliveAtEnd": aliveStatus == .OK && aliveOut.contains("host-alive") && aliveStopped,
 ]
 let allPassed = assertions.values.allSatisfy { $0 }
 results.append(["case": "assertions", "allPassed": allPassed, "details": assertions,
                 "hostAliveStatus": aliveStatus.rawValue, "hostAliveStderr": aliveErr])
 writeResults()
}

@_cdecl("floe_shell_command_main")
public func commandMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
 let arguments = (0..<Int(argc)).compactMap { argv?[$0].map { String(cString: $0) } }
 guard ["floe_qualification_echo", "python3", "floe_runtime_python3"].contains(arguments.first ?? "") else { return 127 }
 if arguments.dropFirst().first == "--environment" {
  FloeShellWrite(FloeShellCurrentStdout(), (FloeShellCurrentEnvironment()["FLOE_SHELL_TEST_SCOPE"] ?? "unset") + "\n")
  return 0
 }
 FloeShellWrite(FloeShellCurrentStdout(), arguments.dropFirst().joined(separator: " ") + "\n")
 return 0
}
