import Foundation

/// Credentials and addressing for one device.
///
/// During setup the app discovers these and fetches the token/key from the
/// cloud, then persists them (Keychain, or a JSON file via `CredentialStore`)
/// and reuses them for all subsequent local control.
public struct DeviceCredentials: Codable, Sendable {
  /// The device's advertised name.
  public let name: String
  /// The device's numeric id.
  public let id: UInt64
  /// The device's IPv4 address.
  public let ip: String
  /// The device's control port.
  public let port: UInt16
  /// The LAN protocol version (2 or 3).
  public let version: Int
  /// The authentication token, hex-encoded (empty for V2 devices).
  public let token: String
  /// The session key, hex-encoded (empty for V2 devices).
  public let key: String

  /// The token decoded to raw bytes.
  public var tokenBytes: [UInt8] { Self.hexToBytes(token) }
  /// The key decoded to raw bytes.
  public var keyBytes: [UInt8] { Self.hexToBytes(key) }

  /// Create credentials from their stored fields.
  ///
  /// - Parameters:
  ///   - name: The device's advertised name.
  ///   - id: The device's numeric id.
  ///   - ip: The device's IPv4 address.
  ///   - port: The device's control port.
  ///   - version: The LAN protocol version (2 or 3).
  ///   - token: The authentication token, hex-encoded.
  ///   - key: The session key, hex-encoded.
  public init(
    name: String, id: UInt64, ip: String, port: UInt16,
    version: Int, token: String, key: String
  ) {
    self.name = name
    self.id = id
    self.ip = ip
    self.port = port
    self.version = version
    self.token = token
    self.key = key
  }

  /// Decode a hex string into bytes, ignoring a trailing odd nibble.
  ///
  /// - Parameter string: A hex-encoded string (two characters per byte).
  /// - Returns: The decoded bytes.
  public static func hexToBytes(_ string: String) -> [UInt8] {
    var bytes = [UInt8]()
    var index = string.startIndex
    while index < string.endIndex,
      string.index(index, offsetBy: 2, limitedBy: string.endIndex) != nil
    {
      let next = string.index(index, offsetBy: 2)
      bytes.append(UInt8(string[index..<next], radix: 16) ?? 0)
      index = next
    }
    return bytes
  }

  /// Encode bytes as a lowercase hex string (two characters per byte).
  ///
  /// - Parameter bytes: The bytes to encode.
  /// - Returns: The hex-encoded string.
  public static func bytesToHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}

/// Persists `DeviceCredentials` to and from a JSON file as `{"devices": [...]}`.
public enum CredentialStore {
  private struct Cache: Codable { let devices: [DeviceCredentials] }

  /// Load devices from a JSON file written by ``save(_:to:)``.
  ///
  /// - Parameter url: The file to read.
  /// - Returns: The stored device credentials.
  /// - Throws: An error if the file can't be read or decoded.
  public static func load(from url: URL) throws -> [DeviceCredentials] {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Cache.self, from: data).devices
  }

  /// Write devices to a JSON file in the shape ``load(from:)`` expects.
  ///
  /// - Parameters:
  ///   - devices: The device credentials to persist.
  ///   - url: The file to write.
  /// - Throws: An error if the file can't be written.
  public static func save(_ devices: [DeviceCredentials], to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Cache(devices: devices)).write(to: url)
  }
}

extension MideaClient {
  /// Create a client from stored ``DeviceCredentials``.
  ///
  /// - Parameter credentials: The stored credentials for one device.
  public convenience init(credentials: DeviceCredentials) {
    self.init(
      host: credentials.ip, port: credentials.port, deviceId: credentials.id,
      token: credentials.tokenBytes, key: credentials.keyBytes
    )
  }
}
