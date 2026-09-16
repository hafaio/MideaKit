import Foundation
import Network
import Testing

@testable import MideaKit

/// What the fake device saw: how many connections it accepted, how many requests
/// it answered, and whether a request's bytes ever arrived while an earlier
/// request on the same connection was still unanswered.
private actor RequestLog {
  private(set) var connections = 0
  private(set) var requests = 0
  private(set) var pipelined = false

  func connectionOpened() {
    connections += 1
  }

  func requestReceived(bytesLeftOver: Bool) {
    requests += 1
    if bytesLeftOver { pipelined = true }
  }
}

@Suite struct ClientTests {
  private let deviceId: UInt64 = 0x0000_0102_0304

  /// Captured from a real unit; parses as a 0xC0 state response at 22 °C.
  private static let stateResponse = DeviceCredentials.hexToBytes(
    "aa23ac00000000000303c00146507f7f000000000064580000000000000000000000001a")

  /// A version-2 device that answers every request with `stateResponse` after
  /// `replyDelay`, recording what it saw in `log`.
  private func startDevice(
    log: RequestLog, replyDelay: Duration
  ) async throws -> FakeDevice {
    let deviceId = self.deviceId
    return try await FakeDevice.start { connection in
      await log.connectionOpened()
      var pending = [UInt8]()
      while true {
        let received = try await connection.receive(atLeast: 1, atMost: 65536)
        pending.append(contentsOf: received.content)
        while pending.count >= 6 {
          let total = Int(pending[4]) | (Int(pending[5]) << 8)
          guard total >= 6, pending.count >= total else { break }
          _ = try V2Packet.decode(Array(pending[0..<total]))
          pending.removeFirst(total)
          await log.requestReceived(bytesLeftOver: !pending.isEmpty)
          try await Task.sleep(for: replyDelay)
          let reply = try V2Packet.encode(deviceId: deviceId, command: Self.stateResponse)
          try await connection.send(Data(reply))
        }
        if received.metadata.endOfStream { return }
      }
    }
  }

  private func client(port: UInt16) -> MideaClient {
    MideaClient(host: "127.0.0.1", port: port, deviceId: deviceId, version: 2, token: [], key: [])
  }

  /// Five refreshes fired at once all come back, and the device sees a single
  /// connection carrying one request at a time: none of them raced ahead to open
  /// its own socket or to send while an answer was still outstanding.
  @Test(.timeLimit(.minutes(1))) func overlappingCallsAreSerialized() async throws {
    let log = RequestLog()
    let device = try await startDevice(log: log, replyDelay: .milliseconds(50))
    defer { device.stop() }

    let client = client(port: device.port)
    let states = try await withThrowingTaskGroup(of: ACState.self) { group in
      for _ in 0..<5 {
        group.addTask { try await client.refresh() }
      }
      return try await group.reduce(into: [ACState]()) { $0.append($1) }
    }
    await client.disconnect()

    #expect(states.count == 5)
    #expect(states.allSatisfy { $0.targetTemperature == 22.0 })
    #expect(await log.connections == 1)
    #expect(await log.requests == 5)
    #expect(await log.pipelined == false)
  }

  /// A call cancelled while it waits its turn throws without reaching the device,
  /// and the call it was queued behind still finishes.
  @Test(.timeLimit(.minutes(1))) func cancelledQueuedCallDoesNotRun() async throws {
    let log = RequestLog()
    let device = try await startDevice(log: log, replyDelay: .seconds(1))
    defer { device.stop() }

    let client = client(port: device.port)
    async let slow = client.refresh()
    // Let the slow refresh take its turn before the second one queues behind it.
    try await Task.sleep(for: .milliseconds(200))

    let queued = Task { try await client.refresh() }
    queued.cancel()
    let result = await queued.result

    #expect(throws: CancellationError.self) { try result.get() }
    #expect(try await slow.targetTemperature == 22.0)
    #expect(await log.requests == 1)
    await client.disconnect()
  }
}
