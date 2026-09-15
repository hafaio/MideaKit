import Foundation
import Network
import Testing

@testable import MideaKit

/// A loopback stand-in for a version-2 device: it listens on an ephemeral port and
/// runs `handler` once per inbound connection, closing that connection when the
/// handler returns.
private struct FakeDevice {
  let port: UInt16
  private let acceptLoop: Task<Void, Never>

  static func start(
    _ handler: @escaping @Sendable (NetworkConnection<TCP>) async throws -> Void
  ) async throws -> FakeDevice {
    let listener = try NetworkListener<TCP>(using: { TCP() })
    let acceptLoop = Task<Void, Never> {
      _ = try? await listener.run { connection in
        try await handler(connection)
      }
    }
    // The port is only assigned once `run` has brought the listener up.
    for _ in 0..<150 {
      if let port = listener.port, port.rawValue != 0 {
        return FakeDevice(port: port.rawValue, acceptLoop: acceptLoop)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    acceptLoop.cancel()
    throw FakeDeviceError.neverListened
  }

  func stop() {
    acceptLoop.cancel()
  }
}

private enum FakeDeviceError: Error {
  case neverListened
}

@Suite struct ConnectionTests {
  private let deviceId: UInt64 = 0x0000_0102_0304

  private func isConnectionClosed(_ error: any Error) -> Bool {
    if case ProtocolError.connectionClosed = error {
      return true
    } else {
      return false
    }
  }

  /// A frame sent by the client arrives intact, and the device's reply comes back
  /// as the application frame it wrapped.
  @Test(.timeLimit(.minutes(1))) func roundTripsApplicationFrame() async throws {
    let deviceId = self.deviceId
    let device = try await FakeDevice.start { connection in
      let request = try await connection.receive(atLeast: 1, atMost: 65536)
      #expect(try V2Packet.decode(Array(request.content)) == [0xAA, 0x01, 0x02])
      let reply = try V2Packet.encode(deviceId: deviceId, command: [0xBB, 0x03])
      try await connection.send(Data(reply))
      try await Task.sleep(for: .seconds(10))
    }
    defer { device.stop() }

    let connection = MideaConnection(
      host: "127.0.0.1", port: device.port, deviceId: deviceId, version: 2)
    defer { connection.disconnect() }

    try await connection.connect()
    try await connection.sendApplicationFrame([0xAA, 0x01, 0x02])
    #expect(try await connection.readApplicationFrame(timeout: 3) == [0xBB, 0x03])
  }

  /// A read that times out mid-packet must leave the bytes it already saw in the
  /// buffer, so the next read picks the packet up where the first one left off.
  @Test(.timeLimit(.minutes(1))) func timeoutKeepsBufferedBytes() async throws {
    let deviceId = self.deviceId
    let device = try await FakeDevice.start { connection in
      _ = try await connection.receive(atLeast: 1, atMost: 65536)
      let reply = try V2Packet.encode(deviceId: deviceId, command: [0xCC, 0x04])
      try await connection.send(Data(reply[0..<4]))
      try await Task.sleep(for: .milliseconds(500))
      try await connection.send(Data(reply[4...]))
      try await Task.sleep(for: .seconds(10))
    }
    defer { device.stop() }

    let connection = MideaConnection(
      host: "127.0.0.1", port: device.port, deviceId: deviceId, version: 2)
    defer { connection.disconnect() }

    try await connection.connect()
    try await connection.sendApplicationFrame([0xAA, 0x01, 0x02])

    do {
      _ = try await connection.readApplicationFrame(timeout: 0.1)
      Issue.record("the read should time out before the rest of the packet arrives")
    } catch {
      #expect(error is TimeoutError, "expected a timeout, got \(error)")
    }
    #expect(try await connection.readApplicationFrame(timeout: 3) == [0xCC, 0x04])
  }

  /// Two packets delivered in one write are handed back as two frames, in order.
  @Test(.timeLimit(.minutes(1))) func twoPacketsInOneWrite() async throws {
    let deviceId = self.deviceId
    let device = try await FakeDevice.start { connection in
      _ = try await connection.receive(atLeast: 1, atMost: 65536)
      let first = try V2Packet.encode(deviceId: deviceId, command: [0xBB, 0x01])
      let second = try V2Packet.encode(deviceId: deviceId, command: [0xBB, 0x02])
      try await connection.send(Data(first + second))
      try await Task.sleep(for: .seconds(10))
    }
    defer { device.stop() }

    let connection = MideaConnection(
      host: "127.0.0.1", port: device.port, deviceId: deviceId, version: 2)
    defer { connection.disconnect() }

    try await connection.connect()
    try await connection.sendApplicationFrame([0xAA, 0x01, 0x02])
    #expect(try await connection.readApplicationFrame(timeout: 3) == [0xBB, 0x01])
    #expect(try await connection.readApplicationFrame(timeout: 3) == [0xBB, 0x02])
  }

  /// A device that closes the socket ends the read with `connectionClosed`, which
  /// is what marks the failure as worth a reconnect.
  @Test(.timeLimit(.minutes(1))) func peerCloseThrowsConnectionClosed() async throws {
    let device = try await FakeDevice.start { _ in }
    defer { device.stop() }

    let connection = MideaConnection(
      host: "127.0.0.1", port: device.port, deviceId: deviceId, version: 2)
    defer { connection.disconnect() }

    try await connection.connect()
    do {
      _ = try await connection.readApplicationFrame(timeout: 3)
      Issue.record("the read should fail once the device closes the socket")
    } catch {
      #expect(isConnectionClosed(error), "expected connectionClosed, got \(error)")
    }
  }

  /// A refused connection surfaces the network error immediately rather than
  /// sitting until the timeout; the client's retry logic keys off that error.
  @Test(.timeLimit(.minutes(1))) func refusedConnectionFailsFast() async throws {
    let device = try await FakeDevice.start { _ in }
    let port = device.port
    device.stop()
    try await Task.sleep(for: .milliseconds(200))

    let connection = MideaConnection(host: "127.0.0.1", port: port, deviceId: deviceId, version: 2)
    defer { connection.disconnect() }

    let start = ContinuousClock.now
    do {
      try await connection.connect(timeout: 5)
      Issue.record("connecting to a closed port should fail")
    } catch {
      #expect(error is NWError, "expected a network error, got \(error)")
      #expect(!(error is TimeoutError))
    }
    #expect(start.duration(to: .now) < .seconds(3))
  }

  /// Disconnecting closes the socket, which the device sees as an end of stream.
  @Test(.timeLimit(.minutes(1))) func disconnectClosesSocket() async throws {
    let deviceId = self.deviceId
    let (endOfStream, report) = AsyncStream<Bool>.makeStream()
    let device = try await FakeDevice.start { connection in
      _ = try await connection.receive(atLeast: 1, atMost: 65536)
      let reply = try V2Packet.encode(deviceId: deviceId, command: [0xBB, 0x05])
      try await connection.send(Data(reply))
      let next = try await connection.receive(atLeast: 1, atMost: 65536)
      report.yield(next.metadata.endOfStream)
      report.finish()
    }
    defer { device.stop() }

    let connection = MideaConnection(
      host: "127.0.0.1", port: device.port, deviceId: deviceId, version: 2)
    try await connection.connect()
    try await connection.sendApplicationFrame([0xAA, 0x01, 0x02])
    #expect(try await connection.readApplicationFrame(timeout: 3) == [0xBB, 0x05])

    connection.disconnect()
    var observed: Bool?
    for await value in endOfStream {
      observed = value
      break
    }
    #expect(observed == true)
  }

  /// A read whose timer fires at the instant its reply lands must not carry that
  /// expiry into the next read. Every request draws two sequence-tagged replies,
  /// so whichever read the short timeout straddles, the one after it is a 3 s read
  /// with a reply already on the way: it can only time out spuriously. The
  /// sequence tags also catch a reply matched to the wrong request.
  @Test(.timeLimit(.minutes(2))) func staleTimerDoesNotTimeOutLaterRead() async throws {
    let deviceId = self.deviceId
    let device = try await FakeDevice.start { connection in
      var pending = [UInt8]()
      while true {
        let received = try await connection.receive(atLeast: 1, atMost: 65536)
        pending.append(contentsOf: received.content)
        while pending.count >= 6 {
          let total = Int(pending[4]) | (Int(pending[5]) << 8)
          guard total >= 6, pending.count >= total else { break }
          let command = try V2Packet.decode(Array(pending[0..<total]))
          pending.removeFirst(total)
          let sequence = command[1]
          // Sweep the delay across the reader's 50 ms deadline so replies land on
          // both sides of it, and sometimes right on top of it.
          try await Task.sleep(for: .microseconds(43_000 + Int(sequence) % 9 * 500))
          for tag in UInt8(1)...UInt8(2) {
            let reply = try V2Packet.encode(deviceId: deviceId, command: [0xBB, sequence, tag])
            try await connection.send(Data(reply))
          }
        }
        if received.metadata.endOfStream { return }
      }
    }
    defer { device.stop() }

    let connection = MideaConnection(
      host: "127.0.0.1", port: device.port, deviceId: deviceId, version: 2)
    defer { connection.disconnect() }

    try await connection.connect()
    for sequence in 0..<45 {
      let tagged = UInt8(sequence % 9)
      try await connection.sendApplicationFrame([0xAA, tagged, 0x02])
      var first: [UInt8]
      do {
        first = try await connection.readApplicationFrame(timeout: 0.05)
      } catch is TimeoutError {
        first = try await connection.readApplicationFrame(timeout: 3)
      }
      #expect(first == [0xBB, tagged, 0x01])
      #expect(try await connection.readApplicationFrame(timeout: 3) == [0xBB, tagged, 0x02])
    }
  }

  /// Cancelling the task inside a read tears the connection down for good, so the
  /// read and every later one must fail promptly with `CancellationError` rather
  /// than hang.
  @Test(.timeLimit(.minutes(1))) func cancelledReadThrowsCancellationError() async throws {
    let device = try await FakeDevice.start { connection in
      _ = try await connection.receive(atLeast: 1, atMost: 65536)
      try await Task.sleep(for: .seconds(30))
    }
    defer { device.stop() }

    let connection = MideaConnection(
      host: "127.0.0.1", port: device.port, deviceId: deviceId, version: 2)
    defer { connection.disconnect() }

    try await connection.connect()
    try await connection.sendApplicationFrame([0xAA, 0x01, 0x02])

    let reader = Task { try await connection.readApplicationFrame(timeout: 30) }
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    reader.cancel()
    let result = await reader.result
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(throws: CancellationError.self) { try result.get() }

    await #expect(throws: CancellationError.self) {
      try await connection.readApplicationFrame(timeout: 30)
    }
  }
}
