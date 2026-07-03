import Foundation
import Network

/// Thrown when a connect or read does not complete within its timeout.
public struct TimeoutError: Error {}

/// Single-use guard so a continuation backed by multiple callbacks resumes once.
/// All access is serialized on the connection's dispatch queue.
private final class ResumeGuard: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  func tryResume() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if done { return false }
    done = true
    return true
  }
}

/// The outcome of one wait inside `readPacket`: a complete packet, a request to
/// retry after more bytes arrived, a timeout, or a terminal stream error.
private enum ReadOutcome {
  case packet([UInt8])
  case more
  case timedOut
  case failure(Error)
}

/// TCP transport for the Midea LAN protocol. Version-3 devices use the "8370"
/// framing with the key handshake; version-2 devices use the unauthenticated
/// `0x5A5A` framing directly, with no handshake.
///
/// Not thread-safe: drive it from a single task, awaiting each call in turn.
/// `@unchecked Sendable` because all receive-side mutable state (`buffer`,
/// `terminalError`, `waiter`) is confined to the serial `queue`, and the
/// send-side state (`packetId`, `localKey`) is only touched by that single
/// driving task.
public final class MideaConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let deviceId: UInt64
  private let version: Int
  private let queue = DispatchQueue(label: "midea.connection")

  private var buffer = [UInt8]()
  // Index of the first unconsumed byte in `buffer`. Consuming a packet advances
  // this instead of shifting the array; the prefix is reclaimed in bulk by
  // `compactBuffer()`, keeping packet assembly O(1) amortized rather than O(n²).
  private var bufferStart = 0
  private var packetId: UInt16 = 0
  private var localKey: [UInt8]?

  // Receive-pump state, touched only on `queue`. A single long-lived receive
  // loop feeds `buffer`; a blocked reader parks its wake-up in `waiter` until
  // the loop appends bytes or the stream ends. Keeping one receive in flight —
  // and never abandoning it when a reader times out — means bytes are never
  // lost mid-stream, so the framing stays in sync across timeouts.
  private var pumpStarted = false
  private var terminalError: Error?
  private var waiter: (() -> Void)?

  /// Create a connection to the device. No socket is opened until ``connect(timeout:)``.
  ///
  /// - Parameters:
  ///   - host: The device's IP address or hostname.
  ///   - port: The device's control port.
  ///   - deviceId: The device's numeric id.
  ///   - version: The device's LAN protocol version (2 or 3); selects the framing
  ///     and whether ``authenticate(token:key:)`` is required.
  public init(host: String, port: UInt16, deviceId: UInt64, version: Int) {
    self.deviceId = deviceId
    self.version = version
    self.connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!,
      using: .tcp
    )
  }

  deinit {
    // Break the pump's receive cycle if the connection is dropped without an
    // explicit disconnect; otherwise the NWConnection would linger.
    connection.cancel()
  }

  /// Open the TCP socket, returning once the connection is ready.
  ///
  /// - Parameter timeout: How long, in seconds, to wait for the connection.
  /// - Throws: ``TimeoutError`` if the timeout elapses, or a network error if
  ///   the connection fails.
  public func connect(timeout: TimeInterval = 6) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      let guardState = ResumeGuard()
      queue.asyncAfter(deadline: .now() + timeout) {
        if guardState.tryResume() { cont.resume(throwing: TimeoutError()) }
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if guardState.tryResume() { cont.resume() }
        case .failed(let error):
          if guardState.tryResume() { cont.resume(throwing: error) }
        default:
          break
        }
      }
      connection.start(queue: queue)
    }
  }

  /// Close the socket.
  public func disconnect() {
    connection.cancel()
  }

  /// Perform the V3 key handshake and derive the session key used to encrypt
  /// subsequent frames.
  ///
  /// - Parameters:
  ///   - token: The authentication token sent to the device.
  ///   - key: The key the handshake response is verified against.
  /// - Throws: An error if the handshake fails or the response can't be verified.
  public func authenticate(token: [UInt8], key: [UInt8]) async throws {
    try await writeRaw(encodeHandshake(token))
    let packet = try await readPacket()
    let data = try process(packet)
    guard data.count == 64 else { throw ProtocolError.invalidHandshake }

    let payload = Array(data[0..<32])
    let receivedHash = Array(data[32...])
    let decrypted = try Crypto.decryptCBC(key: key, payload)
    guard Crypto.sha256(decrypted) == receivedHash else { throw ProtocolError.hashMismatch }
    localKey = Crypto.xor(decrypted, key)
  }

  /// Send an application command frame to the device.
  ///
  /// - Parameter frame: The application command frame to send.
  /// - Throws: An error if the connection isn't authenticated or the send fails.
  public func sendApplicationFrame(_ frame: [UInt8]) async throws {
    let packet = try V2Packet.encode(deviceId: deviceId, command: frame)
    // V3 wraps the 0x5A5A packet in the encrypted 8370 layer; V2 sends it bare.
    try await writeRaw(version >= 3 ? try encodeEncrypted(packet) : packet)
  }

  /// Read one application command frame from the device. Buffered bytes survive a
  /// timeout, so the stream stays in sync.
  ///
  /// - Parameter timeout: How long, in seconds, to wait for more bytes; a short
  ///   value lets a caller probe without blocking long.
  /// - Returns: The decoded application command frame.
  /// - Throws: ``TimeoutError`` if the timeout elapses, or an error if the
  ///   stream ends or a frame can't be decoded.
  public func readApplicationFrame(timeout: TimeInterval = 8) async throws -> [UInt8] {
    // V3 unwraps the 8370 layer around the 0x5A5A packet; V2 reads it bare.
    let inner =
      version >= 3
      ? try process(try await readPacket(timeout: timeout))
      : try await readV2Packet(timeout: timeout)
    return try V2Packet.decode(inner)
  }

  private func nextPacketId() -> UInt16 {
    let id = packetId
    packetId = (packetId &+ 1) & 0xFFF
    return id
  }

  private func encodeHandshake(_ token: [UInt8]) -> [UInt8] {
    let id = nextPacketId()
    var header: [UInt8] = [0x83, 0x70]
    header += be16(UInt16(token.count))
    header += [0x20, 0x00]  // magic byte + (pad<<4 | HANDSHAKE_REQUEST)
    return header + be16(id) + token
  }

  private func encodeEncrypted(_ data: [UInt8]) throws -> [UInt8] {
    guard let key = localKey else { throw ProtocolError.notAuthenticated }
    let id = nextPacketId()
    let remainder = (data.count + 2) % 16
    let pad = remainder == 0 ? 0 : 16 - remainder
    let length = data.count + pad + 32

    var header: [UInt8] = [0x83, 0x70]
    header += be16(UInt16(length))
    header += [0x20, UInt8((pad << 4) | 0x06)]  // pad<<4 | ENCRYPTED_REQUEST

    var payload = be16(id) + data
    payload += (0..<pad).map { _ in UInt8.random(in: 0...255) }

    let hash = Crypto.sha256(header + payload)
    let encrypted = try Crypto.encryptCBC(key: key, payload)
    return header + encrypted + hash
  }

  /// Validate a received 8370 packet and return its application-level bytes:
  /// for a handshake response the raw 64-byte key material, for an encrypted
  /// response the decrypted inner (0x5A5A) packet.
  private func process(_ packet: [UInt8]) throws -> [UInt8] {
    guard packet.count >= 6, packet[0] == 0x83, packet[1] == 0x70 else {
      throw ProtocolError.badStartOfPacket
    }
    guard packet[4] == 0x20 else { throw ProtocolError.badStartOfPacket }

    let type = packet[5] & 0xF
    switch type {
    case 0x1:  // HANDSHAKE_RESPONSE
      guard packet.count >= 8 else { throw ProtocolError.invalidHandshake }
      return Array(packet[8...])  // 6 header + 2 packet id
    case 0x3:  // ENCRYPTED_RESPONSE
      guard let key = localKey else { throw ProtocolError.notAuthenticated }
      // 6-byte header + at least an empty encrypted body + 32-byte hash.
      guard packet.count >= 38 else { throw ProtocolError.shortPacket }
      let header = Array(packet[0..<6])
      let encrypted = Array(packet[6..<(packet.count - 32)])
      let receivedHash = Array(packet[(packet.count - 32)...])
      let decrypted = try Crypto.decryptCBC(key: key, encrypted)
      guard Crypto.sha256(header + decrypted) == receivedHash else {
        throw ProtocolError.hashMismatch
      }
      let pad = Int(header[5] >> 4)
      // Reject a body too short to hold the 2-byte id and the declared padding,
      // so a malformed (or hostile) packet can't slice out of bounds.
      guard decrypted.count >= 2 + pad else { throw ProtocolError.shortPacket }
      return pad > 0
        ? Array(decrypted[2..<(decrypted.count - pad)])
        : Array(decrypted[2...])
    case 0xF:  // ERROR
      throw ProtocolError.errorPacket
    default:
      throw ProtocolError.unexpectedPacketType(type)
    }
  }

  /// Assemble and return one complete 8370 packet from the receive buffer.
  private func readPacket(timeout: TimeInterval = 8) async throws -> [UInt8] {
    try await readFramed(timeout: timeout) { self.extractPacket() }
  }

  /// Assemble and return one complete bare 0x5A5A packet (V2 transport).
  private func readV2Packet(timeout: TimeInterval = 8) async throws -> [UInt8] {
    try await readFramed(timeout: timeout) { self.extractV2Packet() }
  }

  /// Wait for `extract` to yield one complete packet from the receive buffer,
  /// pulling more bytes as they arrive. `timeout` bounds only the wait; on a
  /// timeout every received byte stays buffered (the pump never abandons a
  /// receive), so the stream stays in sync and a later read resumes cleanly.
  private func readFramed(
    timeout: TimeInterval, _ extract: @escaping @Sendable () -> [UInt8]?
  ) async throws -> [UInt8] {
    let deadline = DispatchTime.now() + timeout
    while true {
      let outcome: ReadOutcome = await withCheckedContinuation { cont in
        let resumed = ResumeGuard()
        queue.async {
          self.startPump()
          if let packet = extract() {
            if resumed.tryResume() { cont.resume(returning: .packet(packet)) }
          } else if let error = self.terminalError {
            if resumed.tryResume() { cont.resume(returning: .failure(error)) }
          } else {
            // Park the wake-up and arm the timeout as a cancelable item, so a
            // wake-up before the deadline cancels it instead of leaving a timer
            // pending for every partial read.
            let timeoutItem = DispatchWorkItem {
              if resumed.tryResume() {
                self.waiter = nil
                cont.resume(returning: .timedOut)
              }
            }
            self.waiter = {
              timeoutItem.cancel()
              if resumed.tryResume() { cont.resume(returning: .more) }
            }
            self.queue.asyncAfter(deadline: deadline, execute: timeoutItem)
          }
        }
      }
      switch outcome {
      case .packet(let packet): return packet
      case .failure(let error): throw error
      case .timedOut: throw TimeoutError()
      case .more: continue
      }
    }
  }

  /// Start the single long-lived receive loop that feeds `buffer`. Idempotent;
  /// must be called on `queue`.
  private func startPump() {
    guard !pumpStarted else { return }
    pumpStarted = true
    receiveLoop()
  }

  /// One iteration of the receive pump. The completion runs on `queue`, appends
  /// to `buffer`, wakes a waiting reader, and re-arms — so bytes are never lost
  /// to an abandoned receive, even when a reader has already timed out.
  private func receiveLoop() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data = data, !data.isEmpty {
        self.buffer.append(contentsOf: data)
        self.wakeWaiter()
      }
      if let error = error {
        self.terminalError = error
        self.wakeWaiter()
      } else if isComplete {
        // A clean EOF is the peer closing the socket, not a malformed frame.
        self.terminalError = self.terminalError ?? ProtocolError.connectionClosed
        self.wakeWaiter()
      } else {
        self.receiveLoop()
      }
    }
  }

  /// Wake the reader blocked in `readPacket`, if any. Must be called on `queue`.
  private func wakeWaiter() {
    guard let waiter = waiter else { return }
    self.waiter = nil
    waiter()
  }

  /// Pull one complete 8370 packet from `buffer`, or nil if a whole packet isn't
  /// buffered yet. Advances `bufferStart` past consumed bytes. Must be called on
  /// `queue`.
  private func extractPacket() -> [UInt8]? {
    guard let start = indexOfStart(0x83, 0x70) else { return nil }
    bufferStart = start  // discard any garbage before the start marker
    let available = buffer.count - bufferStart
    guard available >= 6 else { return nil }
    let total = (Int(buffer[bufferStart + 2]) << 8 | Int(buffer[bufferStart + 3])) + 8
    guard available >= total else { return nil }
    let packet = Array(buffer[bufferStart..<(bufferStart + total)])
    bufferStart += total
    compactBuffer()
    return packet
  }

  /// Pull one complete bare 0x5A5A packet from `buffer`, or nil if a whole packet
  /// isn't buffered yet. Its total length lives at bytes 4-5, little-endian.
  /// Advances `bufferStart` past consumed bytes. Must be called on `queue`.
  private func extractV2Packet() -> [UInt8]? {
    guard let start = indexOfStart(0x5A, 0x5A) else { return nil }
    bufferStart = start  // discard any garbage before the start marker
    let available = buffer.count - bufferStart
    guard available >= 6 else { return nil }
    let total = Int(buffer[bufferStart + 4]) | (Int(buffer[bufferStart + 5]) << 8)
    guard total >= 6, available >= total else { return nil }
    let packet = Array(buffer[bufferStart..<(bufferStart + total)])
    bufferStart += total
    compactBuffer()
    return packet
  }

  /// Index of the next `first second` start marker at or after `bufferStart`, or
  /// nil if none is buffered yet. Must be called on `queue`.
  private func indexOfStart(_ first: UInt8, _ second: UInt8) -> Int? {
    guard buffer.count - bufferStart >= 2 else { return nil }
    var index = bufferStart
    while index < buffer.count - 1 {
      if buffer[index] == first && buffer[index + 1] == second { return index }
      index += 1
    }
    return nil
  }

  /// Reclaim the consumed prefix. Resets to empty once fully drained (the common
  /// steady state); otherwise compacts only when the prefix grows large, so the
  /// O(n) shift is amortized away rather than paid per packet. Must be called on
  /// `queue`.
  private func compactBuffer() {
    if bufferStart == buffer.count {
      buffer.removeAll(keepingCapacity: true)
      bufferStart = 0
    } else if bufferStart > 4096 {
      buffer.removeFirst(bufferStart)
      bufferStart = 0
    }
  }

  private func writeRaw(_ data: [UInt8]) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      connection.send(
        content: Data(data),
        completion: .contentProcessed { error in
          if let error = error { cont.resume(throwing: error) } else { cont.resume() }
        })
    }
  }

  private func be16(_ value: UInt16) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
  }
}
