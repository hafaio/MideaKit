import Foundation
import Network

@testable import MideaKit

/// A loopback stand-in for a version-2 device: it listens on an ephemeral port and
/// runs `handler` once per inbound connection, closing that connection when the
/// handler returns.
struct FakeDevice {
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

enum FakeDeviceError: Error {
  case neverListened
}
