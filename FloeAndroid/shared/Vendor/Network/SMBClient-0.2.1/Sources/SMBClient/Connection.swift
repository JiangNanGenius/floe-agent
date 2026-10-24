// Patched vendored file (FloeAndroid lane job-bf610b6f22fe42ab): the
// upstream SMBClient 0.2.1 Connection (Network.framework/NWConnection) is
// preserved BYTE-IDENTICAL inside the `canImport(Network) &&
// !FLOE_PORTABLE_SMB` branch below. The `#else` branch is the
// narrow documented Android/Linux transport for the same class:
//   * a plain blocking POSIX TCP socket (getaddrinfo, socket, connect,
//     send/recv) executed on the connection's own serial GCD queue;
//   * identical DirectTCP framing — `Transport.swift` (DirectTCPPacket) is
//     NOT patched — and the same buffer accumulation, multi-command
//     (`nextCommand`) walk and SMB2 PENDING re-read flow, expressed through
//     the same `receive(completion:)`/`receive(upTo:completion:)` shapes so
//     the protocol authority stays entirely upstream;
//   * the same public surface used by the rest of SMBClient
//     (`init(host:)`, `init(host:port:)`, `connect()`, `disconnect()`,
//     `send(_:) async throws -> Data`, `onDisconnected`) and the same
//     `ConnectionError` cases, so
//     `NetworkWorkspaceMount.classifySMB` maps failures exactly as before
//     (no secret or URL detail can escape: only typed errors cross the
//     boundary);
//   * credentials never flow through this class at all — authentication
//     happens in the untouched upstream SMB-level code.
// Documented deltas of the portable branch (nothing else changes):
//   1. every read is frame-boundary-exact: the 4-byte DirectTCP length
//      prefix is completed before parsing, and exactly one whole transport
//      frame is handed to the framing logic per step. NWConnection in
//      practice delivered whole frames; a raw socket may split them, so
//      this *guarantees* the invariant upstream assumed. Framing math and
//     buffer accounting themselves are upstream's, unchanged.
//   2. `NWConnection.State` is not exposed on the portable branch (the
//      type does not exist there). No other SMBClient source file reads
//      `state` outside this class (verified against 0.2.1).
//   3. `disconnect()` issues `shutdown(SHUT_RDWR)` immediately so a blocked
//      reader wakes with EOF/RESET, then closes the descriptor on the
//      owning queue; in-flight sends surface as
//      `ConnectionError.disconnected`/`.cancelled` — exactly the typed
//      connection-loss positions upstream produced on
//      `NWConnection.cancel()`.
//   4. connect timeout is the platform default (upstream configured none).
// Lifecycle: one socket per Connection; SMBClient creates the Connection
// per mount adapter instance and the adapter drops the client on failure,
// same as the original iOS flow — no view or ambient process coupling.

import Foundation

#if canImport(Network) && !FLOE_PORTABLE_SMB
import Network

public class Connection {
  let host: String
  var onDisconnected: (Error) -> Void

  private let connection: NWConnection
  private var buffer = Data()

  private let semaphore = Semaphore(value: 1)

  public var state: NWConnection.State {
    connection.state
  }

  public init(host: String) {
    self.host = host
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(integerLiteral: 445)
    )
    connection = NWConnection(to: endpoint, using: .tcp)
    onDisconnected = { _ in }
  }

  public init(host: String, port: Int) {
    self.host = host
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: UInt16(port))!
    )
    connection = NWConnection(to: endpoint, using: .tcp)
    onDisconnected = { _ in }
  }

  public func connect() async throws {
    return try await withCheckedThrowingContinuation { (continuation) in
      connection.stateUpdateHandler = { (state) in
        switch state {
        case .setup, .preparing:
          break
        case .waiting(let error):
          continuation.resume(throwing: error)
          self.connection.stateUpdateHandler = nil
        case .ready:
          continuation.resume()
          self.connection.stateUpdateHandler = stateUpdateHandler
        case .failed(let error):
          continuation.resume(throwing: error)
          self.connection.stateUpdateHandler = nil
        case .cancelled:
          continuation.resume(throwing: ConnectionError.cancelled)
          self.connection.stateUpdateHandler = nil
        @unknown default:
          break
        }
      }

      connection.start(queue: .global(qos: .userInitiated))
    }

    @Sendable
    func stateUpdateHandler(_ state: NWConnection.State) {
      switch state {
      case .waiting(let error), .failed(let error):
        onDisconnected(error)
      case .setup, .preparing, .ready, .cancelled:
        break
      @unknown default:
        break
      }
    }
  }

  public func disconnect() {
    connection.cancel()
  }

  public func send(_ data: Data) async throws -> Data {
    await semaphore.wait()
    defer { Task { await semaphore.signal() } }

    switch connection.state {
    case .setup:
      try await connect()
    case .waiting(let error), .failed(let error):
      onDisconnected(error)
      throw error
    case .preparing, .ready:
      break
    case .cancelled:
      throw ConnectionError.cancelled
    @unknown default:
      throw ConnectionError.unknown
    }

    let transportPacket = DirectTCPPacket(smb2Message: data)
    let content = transportPacket.encoded()

    return try await withCheckedThrowingContinuation { (continuation) in
      connection.send(content: content, completion: .contentProcessed() { (error) in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        self.receive() { (result) in
          switch result {
          case .success(let data):
            continuation.resume(returning: data)
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
      })
    }
  }

  private func receive(completion: @escaping (Result<Data, Error>) -> Void) {
    let minimumIncompleteLength = 0
    let maximumLength = 65536

    connection.receive(
      minimumIncompleteLength: minimumIncompleteLength,
      maximumLength: maximumLength)
    { (content, contentContext, isComplete, error) in
      if let error = error {
        completion(.failure(error))
        return
      }

      guard let content else {
        if isComplete {
          completion(.failure(ConnectionError.disconnected))
        } else {
          completion(.failure(ConnectionError.noData))
        }
        return
      }

      let transportPacket = DirectTCPPacket(response: content)
      let length = Int(transportPacket.protocolLength)

      self.buffer.append(Data(transportPacket.smb2Message))

      self.receive(upTo: length) { (result) in
        switch result {
        case .success:
          let data = Data(self.buffer.prefix(length))
          self.buffer = Data(self.buffer.suffix(from: length))

          let reader = ByteReader(data)
          var offset = 0

          var header: Header
          var response = Data()
          repeat {
            header = reader.read()

            switch NTStatus(header.status) {
            case
              .success,
              .moreProcessingRequired,
              .noMoreFiles,
              .endOfFile:
              response += data
            case .pending:
              if self.buffer.count > 0 {
                let transportPacket = DirectTCPPacket(response: self.buffer)
                let length = Int(transportPacket.protocolLength)

                if self.buffer.count < length {
                  self.receive(completion: completion)
                  return
                }

                let data = transportPacket.smb2Message
                self.buffer = Data(self.buffer.suffix(from: 4 + length))

                let reader = ByteReader(data)
                let header: Header = reader.read()

                switch NTStatus(header.status) {
                case
                  .success,
                  .moreProcessingRequired,
                  .noMoreFiles,
                  .endOfFile:
                  response += data
                  break
                default:
                  completion(.failure(ErrorResponse(data: data)))
                  return
                }
              } else {
                self.receive(completion: completion)
                return
              }
            default:
              completion(.failure(ErrorResponse(data: Data(data[offset...]))))
              return
            }

            offset += Int(header.nextCommand)
            reader.seek(to: offset)
          } while header.nextCommand > 0

          completion(.success(response))
        case .failure(let error):
          completion(.failure(error))
        }
      }
    }
  }

  private func receive(upTo byteCount: Int, completion: @escaping (Result<(), Error>) -> Void) {
    let minimumIncompleteLength = 0
    let maximumLength = 65536

    if self.buffer.count < byteCount {
      self.connection.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { (data, _, isComplete, error) in
        if let error = error {
          completion(.failure(error))
          return
        }

        guard let data else {
          if isComplete {
            completion(.failure(ConnectionError.disconnected))
          } else {
            completion(.failure(ConnectionError.noData))
          }
          return
        }

        self.buffer.append(data)
        self.receive(upTo: byteCount, completion: completion)
      }
      return
    }

    completion(.success(()))
  }
}

public enum ConnectionError: Error {
  case noData
  case disconnected
  case cancelled
  case unknown
}
#else

#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// errno-bearing socket failure. The mount adapter only branches on typed
/// `ConnectionError`/`ErrorResponse`, so no detail escapes this module.
private struct PosixConnectionFailure: Error {
  let code: Int32
}

public class Connection {
  let host: String
  var onDisconnected: (Error) -> Void

  private let port: UInt16
  /// Serial queue owns every blocking syscall. One request/response pair is
  /// in flight at a time — the same `Semaphore` serialization upstream used
  /// around NWConnection.
  private let queue: DispatchQueue
  private let semaphore = Semaphore(value: 1)
  private let stateLock = NSLock()
  private var fd: Int32 = -1
  private var cancelled = false
  private var buffer = Data()

  public convenience init(host: String) {
    self.init(host: host, port: 445)
  }

  public init(host: String, port: Int) {
    self.host = host
    self.port = UInt16(truncatingIfNeeded: port)
    self.queue = DispatchQueue(
      label: "com.floe.smbclient.connection.\(UUID().uuidString)",
      qos: .userInitiated
    )
    onDisconnected = { _ in }
  }

  deinit {
    stateLock.lock()
    let current = fd
    fd = -1
    stateLock.unlock()
    if current >= 0 { close(current) }
  }

  public func connect() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          try self.establishIfNeeded()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func disconnect() {
    stateLock.lock()
    cancelled = true
    let current = fd
    fd = -1
    stateLock.unlock()
    if current >= 0 {
      // Wake the blocked reader from any thread-safe call site, then close
      // only on the queue that owns the descriptor (delta #3).
      #if canImport(Android)
      // bionic imports the SHUT_* macros as Int while shutdown() takes
      // Int32; same how value, same reader wake.
      shutdown(current, Int32(SHUT_RDWR))
      #else
      shutdown(current, SHUT_RDWR)
      #endif
      queue.async {
        close(current)
      }
    }
  }

  public func send(_ data: Data) async throws -> Data {
    await semaphore.wait()
    defer { Task { await semaphore.signal() } }

    let transportPacket = DirectTCPPacket(smb2Message: data)
    let content = transportPacket.encoded()

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
      queue.async {
        do {
          try self.establishIfNeeded()
          try self.writeAll(content)
          self.receive { result in continuation.resume(with: result) }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - socket plumbing

  private func establishIfNeeded() throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    if fd >= 0 { return }
    if cancelled { throw ConnectionError.cancelled }
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let first = result else {
      throw PosixConnectionFailure(code: status == 0 ? EADDRNOTAVAIL : status)
    }
    defer { freeaddrinfo(result) }
    var lastError: Int32 = ECONNREFUSED
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor {
      let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
      if sock >= 0 {
        if connectSocket(sock, info.pointee.ai_addr, socklen_t(info.pointee.ai_addrlen)) == 0 {
          var noDelay: Int32 = 1
          #if canImport(Android)
          // bionic imports IPPROTO_TCP/TCP_NODELAY as Int while setsockopt()
          // takes Int32 level/optname; same options, same value and length.
          setsockopt(sock, Int32(IPPROTO_TCP), Int32(TCP_NODELAY), &noDelay, socklen_t(MemoryLayout<Int32>.size))
          #else
          setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
          #endif
          #if canImport(Darwin)
          // Darwin has no MSG_NOSIGNAL; silence SIGPIPE the supported way.
          var noSigPipe: Int32 = 1
          setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
          #endif
          fd = sock
          buffer.removeAll(keepingCapacity: true)
          return
        }
        lastError = errno
        close(sock)
      } else {
        lastError = errno
      }
      cursor = info.pointee.ai_next
    }
    throw PosixConnectionFailure(code: lastError)
  }

  /// Drops the socket and produces the typed failure for the caller; the
  /// disconnected callback mirrors the upstream `onDisconnected` wiring.
  private func fail(_ error: Error) -> Error {
    stateLock.lock()
    let wasLive = fd >= 0
    if fd >= 0 { close(fd); fd = -1 }
    stateLock.unlock()
    buffer.removeAll(keepingCapacity: true)
    if wasLive { onDisconnected(error) }
    return error
  }

  private func writeAll(_ payload: Data) throws {
    try payload.withUnsafeBytes { raw in
      var cursor = raw.bindMemory(to: UInt8.self).baseAddress
      var remaining = payload.count
      while remaining > 0 {
        guard fd >= 0 else { throw fail(ConnectionError.disconnected) }
        let sent = sendBytes(fd, cursor, remaining)
        if sent > 0 {
          cursor = cursor.map { $0.advanced(by: sent) }
          remaining -= sent
          continue
        }
        let code = errno
        if code == EINTR { continue }
        throw fail(ConnectionError.disconnected)
      }
    }
  }

  /// Reads exactly `count` bytes. Returns nil only on a clean EOF at a
  /// frame boundary — the upstream `ConnectionError.disconnected` position.
  private func readExact(_ count: Int) throws -> Data? {
    var chunk = Data()
    var scratch = [UInt8](repeating: 0, count: min(65536, max(count, 4096)))
    while chunk.count < count {
      guard fd >= 0 else { throw fail(ConnectionError.disconnected) }
      let want = min(scratch.count, count - chunk.count)
      let got = recvBytes(fd, &scratch, want)
      if got > 0 {
        chunk.append(contentsOf: scratch[0..<got])
        continue
      }
      if got == 0 { return nil }
      let code = errno
      if code == EINTR { continue }
      throw fail(ConnectionError.disconnected)
    }
    return chunk
  }

  /// Delta #1: one complete transport frame (4-byte length prefix + that
  /// many message bytes) per call, delivered exactly.
  private func readFrame() throws -> Data {
    let headerBytes = try readExact(4)
    guard let headerBytes, headerBytes.count == 4 else { return headerBytes ?? Data() }
    let frameLength = Int(headerBytes.withUnsafeBytes { raw in
      UInt32(bigEndian: raw.load(as: UInt32.self))
    })
    guard frameLength >= 4 else {
      throw fail(ConnectionError.noData)
    }
    guard frameLength > 4 else { return headerBytes }
    let body = try readExact(frameLength - 4)
    guard let body else {
      // Clean EOF in the middle of a declared frame is a broken connection,
      // never a truncated response to hand to the framing logic.
      throw fail(ConnectionError.disconnected)
    }
    var frame = headerBytes
    frame.append(body)
    return frame
  }

  // MARK: - framing (upstream receive logic, frame-exact reads)

  private func receive(completion: @escaping (Result<Data, Error>) -> Void) {
    let content: Data
    do {
      content = try readFrame()
    } catch {
      completion(.failure(error))
      return
    }
    if content.isEmpty {
      completion(.failure(ConnectionError.disconnected))
      return
    }

    let transportPacket = DirectTCPPacket(response: content)
    let length = Int(transportPacket.protocolLength)

    self.buffer.append(Data(transportPacket.smb2Message))

    self.receive(upTo: length) { (result) in
      switch result {
      case .success:
        let data = Data(self.buffer.prefix(length))
        self.buffer = Data(self.buffer.suffix(from: length))

        var header: Header
        var response = Data()

        var reader = ByteReader(data)
        var offset = 0

        repeat {
          header = reader.read()

          switch NTStatus(header.status) {
          case
            .success,
            .moreProcessingRequired,
            .noMoreFiles,
            .endOfFile:
            response += data
          case .pending:
            if self.buffer.count > 0 {
              let transportPacket = DirectTCPPacket(response: self.buffer)
              let length = Int(transportPacket.protocolLength)

              if self.buffer.count < length {
                self.receive(completion: completion)
                return
              }

              let data = transportPacket.smb2Message
              self.buffer = Data(self.buffer.suffix(from: 4 + length))

              let reader = ByteReader(data)
              let header: Header = reader.read()

              switch NTStatus(header.status) {
              case
                .success,
                .moreProcessingRequired,
                .noMoreFiles,
                .endOfFile:
                response += data
                break
              default:
                completion(.failure(ErrorResponse(data: data)))
                return
              }
            } else {
              self.receive(completion: completion)
              return
            }
          default:
            completion(.failure(ErrorResponse(data: Data(data[offset...]))))
            return
          }

          offset += Int(header.nextCommand)
          reader.seek(to: offset)
        } while header.nextCommand > 0

        completion(.success(response))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  private func receive(upTo byteCount: Int, completion: @escaping (Result<(), Error>) -> Void) {
    if self.buffer.count < byteCount {
      let data: Data
      do {
        data = try readFrame()
      } catch {
        completion(.failure(error))
        return
      }
      if data.isEmpty {
        completion(.failure(ConnectionError.disconnected))
        return
      }
      self.buffer.append(data)
      self.receive(upTo: byteCount, completion: completion)
      return
    }

    completion(.success(()))
  }
}

public enum ConnectionError: Error {
  case noData
  case disconnected
  case cancelled
  case unknown
}

private func connectSocket(
  _ fd: Int32,
  _ address: UnsafePointer<sockaddr>?,
  _ length: socklen_t
) -> Int32 {
  #if canImport(Android)
  // A null ai_addr from getaddrinfo is a malformed address, not a
  // force-unwrap: report EINVAL and let the caller try the next result.
  guard let address else {
    errno = EINVAL
    return -1
  }
  return Android.connect(fd, address, length)
  #elseif canImport(Glibc)
  return Glibc.connect(fd, address, length)
  #elseif canImport(Darwin)
  return Darwin.connect(fd, address, length)
  #endif
}

private func sendBytes(_ fd: Int32, _ pointer: UnsafeRawPointer?, _ count: Int) -> Int {
  #if canImport(Android)
  // writeAll never calls with count>0 and a null pointer; if that ever
  // happened it is a programming error surface as EINVAL/-1 (mapped by the
  // caller to ConnectionError.disconnected), never a forced unwrap.
  guard let pointer else {
    errno = EINVAL
    return -1
  }
  return Android.send(fd, pointer, count, Int32(MSG_NOSIGNAL))
  #elseif canImport(Glibc)
  return Glibc.send(fd, pointer, count, Int32(MSG_NOSIGNAL))
  #elseif canImport(Darwin)
  return Darwin.send(fd, pointer, count, 0)
  #endif
}

private func recvBytes(_ fd: Int32, _ pointer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
  #if canImport(Android)
  return Android.recv(fd, pointer, count, 0)
  #elseif canImport(Glibc)
  return Glibc.recv(fd, pointer, count, 0)
  #elseif canImport(Darwin)
  return Darwin.recv(fd, pointer, count, 0)
  #endif
}

#endif
