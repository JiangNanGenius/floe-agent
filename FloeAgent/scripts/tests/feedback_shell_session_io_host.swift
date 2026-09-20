//
//  feedback_shell_session_io_host.swift
//  Floe Agent — shell session pump EOF/descriptor host harness.
//
//  The real SessionIO pump state machine is spliced in by
//  run_feedback_shell_session_io_host.sh from the current working tree
//  (FloeApp/Execution/IOSSystemShellBackend.swift) between the markers below;
//  the stub declarations here stand in for the FloeError / ShellExchangeResult
//  / FloeShell* bridge seam the app target provides. The checks drive the real
//  pump on real pipes:
//    * sendEOF() flushes every byte enqueued before it, in order, and only
//      then closes the stdin write end: the program reads the queued input
//      followed by a real EOF (read returns 0), and input enqueued after the
//      EOF request is refused;
//    * a hard write error (EPIPE with no reader) closes the owned stdin
//      descriptor exactly once — merely flagging it closed would leak it —
//      and the pump keeps draining the program's output;
//    * the descriptor number closed early by EOF or a write error is
//      reoccupied by an unrelated descriptor: teardown closing it again
//      (double close) would close the probe, which the harness measures;
//    * a queue larger than the pipe buffer is delivered completely and in
//      order across EAGAIN partial-write retries (no dropped or reordered
//      bytes), and teardown closes each owned descriptor once.
//
//  This is a desktop host check of the pump state machine, not an iOS or
//  device qualification.
//

import Foundation
import Darwin

// MARK: - Seam stubs (app-target signatures the pump depends on)

struct FloeError: Error {
    let message: String
    static func validationFailed(_ message: String) -> FloeError { FloeError(message: message) }
}

struct ShellExchangeResult {
    var output: String
    var terminalOutput: Data?
    var alive: Bool
    var exitCode: Int32?
    var bytesRead: Int
    var bytesWritten: Int
    init(output: String, alive: Bool, exitCode: Int32? = nil, terminalOutput: Data? = nil, bytesRead: Int = 0, bytesWritten: Int = 0) {
        self.output = output
        self.terminalOutput = terminalOutput
        self.alive = alive
        self.exitCode = exitCode
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }
}

final class FloeShellCommandRegistry: @unchecked Sendable {
    static let shared = FloeShellCommandRegistry()
    func unbind(sessionID: String) {}
    func cancelCurrent(sessionID: String) {}
}

@discardableResult
func FloeShellSessionExitCode(_ sessionID: String, _ code: UnsafeMutablePointer<Int32>) -> Bool { false }
func FloeShellEndSession(_ sessionID: String) {}
func FloeShellSignalSession(_ sessionID: String, _ signalNumber: Int32) {}

// MARK: - SessionIO (spliced from IOSSystemShellBackend.swift)

// >>> SESSION-IO-SOURCE
// <<< SESSION-IO-SOURCE

// MARK: - Harness

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        print("FAIL  \(label)")
        failures += 1
    }
}

func waitFor(_ condition: () -> Bool, _ seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}

func makePipe() -> (readEnd: Int32, writeEnd: Int32) {
    var fds: [Int32] = [-1, -1]
    let result = fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress) }
    precondition(result == 0, "pipe() failed")
    return (fds[0], fds[1])
}

func fdIsClosed(_ fd: Int32) -> Bool {
    errno = 0
    return fcntl(fd, F_GETFD, 0) == -1 && errno == EBADF
}

/// Reoccupies `fd` (which the pump must treat as closed) with an unrelated
/// descriptor. A later second close of the same number would close this probe
/// instead of nothing, so the caller can observe the double close directly.
/// Returns the probe descriptor, or -1 if it could not be installed.
func installDoubleCloseProbe(_ fd: Int32) -> Int32 {
    var probe = open("/dev/null", O_RDONLY)
    guard probe >= 0 else { return -1 }
    if probe != fd {
        let moved = dup2(probe, fd)
        if moved < 0 { close(probe); return -1 }
        close(probe)
        probe = moved
    }
    return probe
}

/// Reads up to `count` bytes with a bounded wait. Returns what arrived; an
/// early return is itself evidence a byte was dropped.
func readUpTo(_ fd: Int32, count: Int, timeout: TimeInterval) -> Data {
    var data = Data()
    let deadline = Date().addingTimeInterval(timeout)
    while data.count < count && Date() < deadline {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready <= 0 { continue }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let got = read(fd, &buffer, buffer.count)
        if got > 0 { data.append(contentsOf: buffer.prefix(got)) }
        else if got == 0 { break }
        else if errno != EAGAIN && errno != EINTR { break }
    }
    return data
}

/// Reads exactly through end-of-file after `alreadyRead` bytes, bounded so a
/// never-closed write end fails instead of hanging the harness.
func observeEOF(_ fd: Int32, timeout: TimeInterval) -> Int {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&descriptor, 1, Int32(timeout * 1000))
    guard ready > 0 else { return -1 }
    var buffer = [UInt8](repeating: 0, count: 16)
    return read(fd, &buffer, buffer.count)
}

// Watchdog: a hung pump or a never-delivered EOF fails loudly.
let watchdog = Thread {
    sleep(60)
    print("FAIL  watchdog expired; harness hung")
    _exit(97)
}
watchdog.start()

// A: sendEOF flushes pending input first, then closes stdin; later input is
// refused; the descriptor is closed exactly once.
do {
    let input = makePipe()
    let output = makePipe()
    let io = SessionIO(id: "eof-flush", input: input.writeEnd, output: output.readEnd)
    io.start()
    let queued = Data("line-one\nline-two\n".utf8)
    try io.enqueue(Data("line-one\n".utf8))
    try io.enqueue(Data("line-two\n".utf8))
    try io.sendEOF()
    try io.sendEOF() // idempotent
    var lateRejected = false
    do { try io.enqueue(Data("late\n".utf8)) } catch { lateRejected = true }
    check(lateRejected, "A: input enqueued after sendEOF is rejected")

    let received = readUpTo(input.readEnd, count: queued.count, timeout: 3.0)
    check(received == queued, "A: sendEOF flushes every pending byte first, in order")
    let eofResult = observeEOF(input.readEnd, timeout: 3.0)
    check(eofResult == 0, "A: the flushed bytes are followed by a real end-of-file")
    check(io.drain(maxBytes: 1024).bytesWritten == queued.count, "A: the flushed bytes are counted as written")
    check(fdIsClosed(input.writeEnd), "A: sendEOF closed the stdin descriptor exactly once")

    // A second close of the same descriptor number at teardown would close
    // this probe; the pump must leave it alone.
    let probeA = installDoubleCloseProbe(input.writeEnd)
    check(probeA == input.writeEnd, "A: the closed stdin descriptor number is reused for the double-close probe")
    close(output.writeEnd) // program output ends; the pump must exit
    check(waitFor({ !io.alive }, 3.0), "A: the pump stops once the program's output ends")
    check(probeA >= 0 && !fdIsClosed(probeA), "A: teardown does not close the EOF-closed stdin descriptor again")
    if probeA >= 0 { close(probeA) }
    close(input.readEnd)
    close(output.readEnd)
}

// B: a hard stdin write error closes the owned descriptor exactly once (the
// flag-only path would leak it) and stops neither the output drain nor
// teardown.
do {
    let input = makePipe()
    close(input.readEnd) // no reader: the next write is EPIPE, not EAGAIN
    let output = makePipe()
    let io = SessionIO(id: "epipe", input: input.writeEnd, output: output.readEnd)
    io.start()
    try io.enqueue(Data("dropped\n".utf8))
    check(waitFor({ fdIsClosed(input.writeEnd) }, 3.0), "B: EPIPE closes the owned stdin descriptor")
    let probeB = installDoubleCloseProbe(input.writeEnd)
    check(probeB == input.writeEnd, "B: the closed stdin descriptor number is reused for the double-close probe")

    let payload = Data("still-draining\n".utf8)
    payload.withUnsafeBytes { _ = Darwin.write(output.writeEnd, $0.baseAddress, $0.count) }
    var drained = Data()
    let deadline = Date().addingTimeInterval(3.0)
    while drained.count < payload.count && Date() < deadline {
        drained.append(io.drain(maxBytes: 1024).terminalOutput ?? Data())
        usleep(10_000)
    }
    check(drained == payload, "B: a hard stdin write error does not stop the output drain")

    close(output.writeEnd)
    check(waitFor({ !io.alive }, 3.0), "B: the pump still stops on output EOF after the write error")
    check(probeB >= 0 && !fdIsClosed(probeB), "B: teardown does not close the write-error-closed stdin descriptor again")
    if probeB >= 0 { close(probeB) }
    close(output.readEnd)
}

// C: a queue larger than the pipe buffer is delivered completely and in order
// across EAGAIN/partial-write retries; no byte is dropped or reordered.
do {
    let input = makePipe()
    let output = makePipe()
    let io = SessionIO(id: "eagain", input: input.writeEnd, output: output.readEnd)
    io.start()
    var payload = Data()
    let line = Data("0123456789abcdef\n".utf8)
    while payload.count < 192 * 1024 { payload.append(line) }
    try io.enqueue(payload)
    usleep(200_000) // let the pump hit the full pipe buffer (EAGAIN) first

    var received = Data()
    let deadline = Date().addingTimeInterval(10.0)
    while received.count < payload.count && Date() < deadline {
        let chunk = readUpTo(input.readEnd, count: payload.count - received.count, timeout: 1.0)
        if chunk.isEmpty { continue }
        received.append(chunk)
    }
    check(received == payload, "C: a buffer-sized queue is delivered completely and in order")
    check(io.drain(maxBytes: 1024).bytesWritten == payload.count, "C: every byte is counted as written once")

    close(output.writeEnd)
    check(waitFor({ !io.alive }, 3.0), "C: the pump stops after the large queue and output EOF")
    check(fdIsClosed(input.writeEnd), "C: stdin is closed exactly once after the large flush")
    check(fdIsClosed(output.readEnd), "C: output is closed exactly once at teardown")
    close(input.readEnd)
}

print("\n\(checks - failures)/\(checks) shell session-io host checks passed")
exit(failures == 0 ? 0 : 1)
