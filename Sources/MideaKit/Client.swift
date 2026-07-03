import Foundation
import Network

/// High-level local control of one air conditioner.
///
/// Holds a persistent authenticated connection and reuses it across calls, so
/// repeated ``refresh()`` polls are cheap (a single query/response, no
/// handshake). The connection is re-established lazily when absent, expired, or
/// after a failed call. Drive it from one task at a time — the connection is not
/// re-entrant, so callers must serialize their own access.
///
/// Construct it from the ``DeviceCredentials`` that ``Setup/run(cloud:)``
/// returns, then reuse the instance:
///
/// ```swift
/// import MideaKit
///
/// // One-time setup contacts the cloud to fetch each device's key:
/// let credentials = try await Setup.run().first!
///
/// // Everything after is local. Persist the credentials and reuse the client:
/// let client = MideaClient(credentials: credentials)
/// let state = try await client.refresh()
/// if let mode = OperationalMode(rawValue: state.mode) {
///   print(state.targetTemperature, mode)  // e.g. 22.0 cool
/// }
///
/// // Change only the fields you set; the rest carry over from current state:
/// _ = try await client.apply { set in
///   set.powerOn = true
///   set.targetTemperature = 22
///   set.mode = OperationalMode.cool.rawValue
/// }
/// ```
public final class MideaClient {
  private let host: String
  private let port: UInt16
  private let deviceId: UInt64
  private let token: [UInt8]
  private let key: [UInt8]

  private var connection: MideaConnection?
  private var authenticatedAt: Date?
  // Re-authenticate before the device's ~12h session key expires.
  private let sessionLifetime: TimeInterval = 11 * 3600

  // After auth the device needs a beat before it answers queries. Rather than a
  // flat wait, send one getState and proceed the instant its reply lands. A brief
  // floor avoids querying at the very instant auth completes.
  private let warmUpFloor: UInt64 = 200_000_000

  /// Create a client for a device, given the address and keys obtained during
  /// setup. Prefer ``init(credentials:)`` when you have stored
  /// ``DeviceCredentials``.
  ///
  /// - Parameters:
  ///   - host: The device's IP address or hostname.
  ///   - port: The device's control port.
  ///   - deviceId: The device's numeric id.
  ///   - token: The authentication token bytes.
  ///   - key: The session key bytes.
  public init(host: String, port: UInt16, deviceId: UInt64, token: [UInt8], key: [UInt8]) {
    self.host = host
    self.port = port
    self.deviceId = deviceId
    self.token = token
    self.key = key
  }

  /// Run `body` with a client built from `credentials`, disconnecting when it
  /// returns or throws — the scoped equivalent of pairing a client with a
  /// `defer { client.disconnect() }`.
  ///
  /// ```swift
  /// let state = try await MideaClient.withSession(credentials: creds) { client in
  ///   try await client.refresh()
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - credentials: The stored credentials for the device.
  ///   - body: A closure run with the client; it connects lazily on first use.
  /// - Returns: Whatever `body` returns.
  public static func withSession<T>(
    credentials: DeviceCredentials,
    _ body: (MideaClient) async throws -> T
  ) async rethrows -> T {
    let client = MideaClient(credentials: credentials)
    defer { client.disconnect() }
    return try await body(client)
  }

  /// Eagerly establish the connection (optional; calls connect lazily anyway).
  public func connect() async throws {
    try await ensureConnected()
  }

  /// Close the live connection and drop the cached session, if any. The next
  /// call reconnects lazily.
  public func disconnect() {
    connection?.disconnect()
    connection = nil
    authenticatedAt = nil
  }

  /// Query and return the device's current state.
  ///
  /// - Returns: The device's current state.
  /// - Throws: An error if the device can't be reached or the exchange fails.
  public func refresh() async throws -> ACState {
    try await withConnection { connection in
      try await connection.sendApplicationFrame(Command.getState())
      return try await self.readState(connection)
    }
  }

  /// Send a fully specified ``SetState`` to the device and return the resulting
  /// state. Use the closure form of `apply` to change only some fields.
  ///
  /// - Parameter set: The complete state to send to the device.
  /// - Returns: The device's state after applying the change.
  /// - Throws: An error if the device can't be reached or the exchange fails.
  public func apply(_ set: SetState) async throws -> ACState {
    try await withConnection { connection in
      try await connection.sendApplicationFrame(set.encode())
      return try await self.readState(connection)
    }
  }

  /// Toggle the LED display and return the resulting state.
  ///
  /// - Parameter beep: Whether the unit beeps to acknowledge the command.
  /// - Returns: The device's state after toggling the display.
  /// - Throws: An error if the device can't be reached or the exchange fails.
  public func toggleDisplay(beep: Bool = true) async throws -> ACState {
    // Relative command: don't retry, or a lost response double-toggles.
    try await withConnection(retry: false) { connection in
      try await connection.sendApplicationFrame(Command.toggleDisplay(beep: beep))
      return try await self.readState(connection)
    }
  }

  /// Read the current state, apply a change on top of it, and send it back —
  /// all on the live connection. Only the fields you set in `change` differ from
  /// the device's current state; everything else carries over.
  ///
  /// ```swift
  /// let state = try await client.apply { set in
  ///   set.powerOn = true
  ///   set.targetTemperature = 21.5
  ///   set.fanSpeed = FanSpeed.auto.rawValue
  /// }
  /// ```
  ///
  /// - Parameter change: A closure that mutates a ``SetState`` seeded from the
  ///   device's current state.
  /// - Returns: The device's state after applying the change.
  /// - Throws: An error if the device can't be reached or the exchange fails.
  public func apply(_ change: @escaping (inout SetState) -> Void) async throws -> ACState {
    try await withConnection { connection in
      try await connection.sendApplicationFrame(Command.getState())
      let current = try await self.readState(connection)
      var set = SetState(from: current)
      change(&set)
      try await connection.sendApplicationFrame(set.encode())
      return try await self.readState(connection)
    }
  }

  private func ensureConnected() async throws {
    if connection != nil, let authenticatedAt,
      Date().timeIntervalSince(authenticatedAt) < sessionLifetime
    {
      return
    }
    disconnect()
    let connection = MideaConnection(host: host, port: port, deviceId: deviceId)
    do {
      try await connection.connect()
      try await connection.authenticate(token: token, key: key)
      await warmUp(connection)
    } catch {
      connection.disconnect()  // don't leak the half-open socket
      throw error
    }
    self.connection = connection
    self.authenticatedAt = Date()
  }

  /// Wait until the freshly authenticated device will answer queries: send one
  /// getState and consume its reply, returning the moment it lands. getState is
  /// idempotent, so the lone probe is harmless. The reply is read with the normal
  /// timeout and fully consumed here — not read with a short ceiling and abandoned
  /// — so a slow unit's late answer can't linger in the buffer and desync every
  /// later request from its response. If the device never answers, the read times
  /// out and the first real call surfaces the failure.
  private func warmUp(_ connection: MideaConnection) async {
    try? await Task.sleep(nanoseconds: warmUpFloor)
    do {
      try await connection.sendApplicationFrame(Command.getState())
    } catch {
      return
    }
    _ = try? await connection.readApplicationFrame()
  }

  /// Run an operation on the live connection, reconnecting and retrying once if
  /// it fails with a transport error (e.g. the device dropped an idle
  /// connection). `retry` should be false for non-idempotent commands (e.g. a
  /// relative toggle) so a lost response doesn't double-apply. Protocol, auth,
  /// and timeout errors are surfaced immediately rather than retried.
  private func withConnection<T>(
    retry: Bool = true, _ operation: (MideaConnection) async throws -> T
  ) async throws -> T {
    try await ensureConnected()
    guard let connection else { throw ProtocolError.notAuthenticated }
    do {
      return try await operation(connection)
    } catch {
      disconnect()
      guard retry, Self.isRetryable(error) else { throw error }
      try await ensureConnected()
      guard let fresh = self.connection else { throw error }
      return try await operation(fresh)
    }
  }

  /// Whether `error` is a transport-level failure worth one reconnect-and-retry:
  /// the peer closed the socket, or the network layer faulted. Protocol/auth
  /// errors and timeouts are not retried — a retry wouldn't change the outcome.
  private static func isRetryable(_ error: Error) -> Bool {
    if case ProtocolError.connectionClosed = error { return true }
    return error is NWError
  }

  private func readState(_ connection: MideaConnection) async throws -> ACState {
    // Skip any unsolicited non-state frames until a 0xC0 state response.
    for _ in 0..<4 {
      let frame = try await connection.readApplicationFrame()
      if let state = try ACState.parse(frame: frame) { return state }
    }
    throw ProtocolError.unexpectedPacketType(0)
  }
}
