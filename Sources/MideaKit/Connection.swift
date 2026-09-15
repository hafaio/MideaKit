import Foundation
import Network

/// Thrown when a connect or read does not complete within its timeout.
public struct TimeoutError: Error {}

/// One thing a reader can observe: a complete framed packet, the expiry of a
/// read's own timer, or the end of the stream.
private enum Event: Sendable {
  case packet([UInt8])
  // The token identifies the read that armed the timer, so a timer that fires
  // just as its packet lands can't time out a later read.
  case timeout(UInt64)
  case ended(any Error)
}

/// The received bytes waiting to be framed, owned exclusively by the receive
/// pump, so it needs no lock.
private struct FrameBuffer {
  private var buffer = [UInt8]()
  // Index of the first unconsumed byte in `buffer`. Consuming a packet advances
  // this instead of shifting the array; the prefix is reclaimed in bulk by
  // `compactBuffer()`, keeping packet assembly O(1) amortized rather than O(n²).
  private var bufferStart = 0

  mutating func append(_ data: Data) {
    buffer.append(contentsOf: data)
  }

  /// Pull one complete 8370 packet from `buffer`, or nil if a whole packet isn't
  /// buffered yet. Advances `bufferStart` past consumed bytes.
  mutating func extractPacket() -> [UInt8]? {
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
  /// Advances `bufferStart` past consumed bytes.
  mutating func extractV2Packet() -> [UInt8]? {
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
  /// nil if none is buffered yet.
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
  /// O(n) shift is amortized away rather than paid per packet.
  private mutating func compactBuffer() {
    if bufferStart == buffer.count {
      buffer.removeAll(keepingCapacity: true)
      bufferStart = 0
    } else if bufferStart > 4096 {
      buffer.removeFirst(bufferStart)
      bufferStart = 0
    }
  }
}

/// TCP transport for the Midea LAN protocol. Version-3 devices use the "8370"
/// framing with the key handshake; version-2 devices use the unauthenticated
/// `0x5A5A` framing directly, with no handshake.
///
/// Not thread-safe: drive it from a single task, awaiting each call in turn.
/// `@unchecked Sendable` because the receive pump is the sole owner of its frame
/// buffer and hands finished packets over through an `AsyncStream`, while the
/// reader-side state (`events`, `terminalError`, `timeoutToken`, `packetId`,
/// `localKey`, `pumpTask`) is only touched by that single driving task.
public final class MideaConnection: @unchecked Sendable {
  private let connection: NetworkConnection<TCP>
  private let deviceId: UInt64
  private let version: Int

  private let eventContinuation: AsyncStream<Event>.Continuation
  private var events: AsyncStream<Event>.Iterator
  private var terminalError: (any Error)?
  private var timeoutToken: UInt64 = 0

  private var packetId: UInt16 = 0
  private var localKey: [UInt8]?

  private var pumpTask: Task<Void, Never>?

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
    self.connection = NetworkConnection(
      to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    ) {
      TCP()
    }
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
    self.events = stream.makeAsyncIterator()
    self.eventContinuation = continuation
  }

  deinit {
    pumpTask?.cancel()
  }

  /// Open the TCP socket, returning once the connection is ready.
  ///
  /// - Parameter timeout: How long, in seconds, to wait for the connection.
  /// - Throws: ``TimeoutError`` if the timeout elapses, or a network error if
  ///   the connection fails.
  public func connect(timeout: TimeInterval = 6) async throws {
    // A send never reports a failed connect and a receive only does so once the
    // endpoint has answered, so the state handler is the only timely signal that
    // the connect succeeded or failed. Installing it before reading `state`
    // leaves no gap for a `.ready` that lands between the check and the wait.
    let (states, stateContinuation) = AsyncStream.makeStream(
      of: NetworkConnection<TCP>.State.self)
    connection.onStateUpdate { _, state in
      stateContinuation.yield(state)
    }
    defer { stateContinuation.finish() }

    if connection.state == .ready {
      return
    } else if case .waiting(let error) = connection.state {
      throw error
    } else if case .failed(let error) = connection.state {
      throw error
    } else {
      // Nothing dials out until an operation asks for bytes, so the pump's first
      // receive is what actually opens the socket.
      startPump()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for await state in states {
            switch state {
            case .ready: return
            case .waiting(let error), .failed(let error): throw error
            default: continue
            }
          }
          throw CancellationError()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(timeout))
          throw TimeoutError()
        }
        // Cancelling these two is safe: neither is inside a send or a receive,
        // which is what would tear the whole connection down.
        defer { group.cancelAll() }
        _ = try await group.next()
      }
    }
  }

  /// Close the socket.
  public func disconnect() {
    pumpTask?.cancel()
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
  ///   stream ends or a frame can't be decoded. Cancelling the calling task
  ///   throws `CancellationError` and leaves the connection permanently
  ///   unusable, so discard it — as callers already do on any error.
  public func readApplicationFrame(timeout: TimeInterval = 8) async throws -> [UInt8] {
    let packet = try await readPacket(timeout: timeout)
    // V3 unwraps the 8370 layer around the 0x5A5A packet; V2 reads it bare.
    return try V2Packet.decode(version >= 3 ? try process(packet) : packet)
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

  /// Wait for the pump to deliver the next complete packet. `timeout` bounds only
  /// this wait: it arms a separate timer task that posts a token-tagged event,
  /// never a cancellation of the pump — cancelling a task inside `receive` tears
  /// the whole connection down. Every received byte therefore stays buffered
  /// across a timeout, so the stream stays in sync and a later read resumes
  /// cleanly, and a timer that fires just too late is ignored by every read but
  /// the one that armed it.
  private func readPacket(timeout: TimeInterval = 8) async throws -> [UInt8] {
    startPump()
    if let terminalError { throw terminalError }

    timeoutToken &+= 1
    let token = timeoutToken
    let timer = Task { [eventContinuation] in
      do {
        try await Task.sleep(for: .seconds(timeout))
      } catch {
        return
      }
      eventContinuation.yield(.timeout(token))
    }
    defer { timer.cancel() }

    while let event = await events.next() {
      switch event {
      case .packet(let packet):
        return packet
      case .timeout(let fired) where fired == token:
        throw TimeoutError()
      case .timeout:
        continue  // a stale timer armed by an earlier read
      case .ended(let error):
        terminalError = error
        throw error
      }
    }
    // `next()` only returns nil once this task has been cancelled, and that kills
    // the stream for good, so nothing can be read from this connection again.
    terminalError = CancellationError()
    throw CancellationError()
  }

  /// Start the single long-lived receive loop that feeds the event stream.
  /// Idempotent. Keeping one receive in flight — and never cancelling it when a
  /// reader times out — means bytes are never lost mid-stream, so the framing
  /// stays in sync across timeouts. Cancelling this task is also what closes the
  /// socket, so only ``disconnect()`` and `deinit` may do it. It holds the
  /// connection, not `self`, so a dropped ``MideaConnection`` can still deinit
  /// while a receive is pending.
  private func startPump() {
    guard pumpTask == nil else { return }
    pumpTask = Task { [connection, eventContinuation, version] in
      var frames = FrameBuffer()
      while true {
        do {
          let received = try await connection.receive(atLeast: 1, atMost: 65536)
          frames.append(received.content)
          while let packet = (version >= 3 ? frames.extractPacket() : frames.extractV2Packet()) {
            eventContinuation.yield(.packet(packet))
          }
          if received.metadata.endOfStream {
            // A clean EOF is the peer closing the socket, not a malformed frame.
            eventContinuation.yield(.ended(ProtocolError.connectionClosed))
            return
          }
        } catch {
          eventContinuation.yield(.ended(error))
          return
        }
      }
    }
  }

  private func writeRaw(_ data: [UInt8]) async throws {
    // A caller that skips connect() still needs the pump, both to open the socket
    // and to notice the peer closing it.
    startPump()
    try await connection.send(Data(data))
  }

  private func be16(_ value: UInt16) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
  }
}
