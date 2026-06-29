import Foundation

/// An error returned by the NetHome Plus cloud API.
public struct CloudError: Error, CustomStringConvertible {
  /// A human-readable description of the failure.
  public let message: String
  /// The cloud's numeric error code, if one was returned.
  public let code: Int?
  /// A textual representation combining the code and message.
  public var description: String { "CloudError(\(code.map(String.init) ?? "?")): \(message)" }
}

/// An authenticated NetHome Plus session, returned by ``NetHomePlusCloud/login()``
/// and passed to ``NetHomePlusCloud/getToken(_:udpid:)``. It is immutable, so a
/// single session can drive many concurrent token fetches.
public struct CloudSession: Sendable {
  let sessionId: String
}

/// Minimal NetHome Plus cloud client — just enough to fetch a device's token/key
/// using the built-in app account. Ported from msmart's NetHomePlusCloud.
///
/// Stateless after construction (the session lives in ``CloudSession``), so it is
/// `Sendable` and safe to share across concurrent ``getToken(_:udpid:)`` calls.
public final class NetHomePlusCloud: Sendable {
  private static let baseURL = "https://mapp.appsmb.com"
  private static let appId = "1017"
  private static let appKey = "3742e9e5842d4ad59c2db887e12449f9"
  private static let credentials: [String: (account: String, password: String)] = [
    "US": ("nethome+us@mailinator.com", "password1"),
    "DE": ("nethome+de@mailinator.com", "password1"),
    "KR": ("nethome+sea@mailinator.com", "password1"),
  ]

  private let account: String
  private let password: String
  private let deviceId: String

  /// Authenticate with your own NetHome Plus account (one you registered in the
  /// app) rather than the shared public defaults.
  ///
  /// - Parameters:
  ///   - account: Your NetHome Plus account email.
  ///   - password: Your NetHome Plus account password.
  public init(account: String, password: String) {
    self.account = account
    self.password = password
    self.deviceId = DeviceCredentials.bytesToHex((0..<8).map { _ in UInt8.random(in: 0...255) })
  }

  /// Authenticate with one of the shared public NetHome Plus accounts, selected
  /// by region. Convenient and zero-config, but the account is shared with every
  /// other user of these libraries — pass your own via ``init(account:password:)``
  /// if you'd rather not rely on it.
  ///
  /// - Parameter region: The shared account to use: `US`, `DE`, or `KR`. An
  ///   unknown region falls back to `US`.
  public convenience init(region: String = "US") {
    let creds = Self.credentials[region] ?? Self.credentials["US"]!
    self.init(account: creds.account, password: creds.password)
  }

  /// Authenticate and return a session to pass to ``getToken(_:udpid:)``.
  ///
  /// - Returns: An authenticated ``CloudSession``.
  /// - Throws: ``CloudError`` if authentication fails.
  public func login() async throws -> CloudSession {
    let loginId = try await getLoginId()
    let result = try await apiRequest(
      "/v1/user/login",
      [
        "loginAccount": account,
        "password": encryptPassword(loginId, password),
      ])
    guard let session = result["sessionId"] as? String else {
      throw CloudError(message: "No sessionId in login response", code: nil)
    }
    return CloudSession(sessionId: session)
  }

  /// Fetch the token/key pair for the device identified by `udpid`.
  ///
  /// - Parameters:
  ///   - session: A session from a prior ``login()``.
  ///   - udpid: The device's udpid, from ``UDPID/compute(deviceId:bigEndian:)``.
  /// - Returns: The device's `token` and `key`, both hex-encoded.
  /// - Throws: ``CloudError`` if the request fails or no keys are found.
  public func getToken(_ session: CloudSession, udpid: String) async throws -> (
    token: String, key: String
  ) {
    let result = try await apiRequest(
      "/v1/iot/secure/getToken", ["udpid": udpid], sessionId: session.sessionId)
    guard let list = result["tokenlist"] as? [[String: Any]] else {
      throw CloudError(message: "No tokenlist in response", code: nil)
    }
    for entry in list where (entry["udpId"] as? String) == udpid {
      if let token = entry["token"] as? String, let key = entry["key"] as? String {
        return (token, key)
      }
    }
    throw CloudError(message: "No token/key found for udpid \(udpid)", code: nil)
  }

  private func getLoginId() async throws -> String {
    let result = try await apiRequest("/v1/user/login/id/get", ["loginAccount": account])
    guard let id = result["loginId"] as? String else {
      throw CloudError(message: "No loginId in response", code: nil)
    }
    return id
  }

  private func apiRequest(
    _ endpoint: String, _ data: [String: String], sessionId: String = ""
  ) async throws -> [String: Any] {
    var body = baseBody(sessionId: sessionId)
    for (key, value) in data { body[key] = value }
    body["sign"] = sign(path: endpoint, body: body)

    var request = URLRequest(url: URL(string: Self.baseURL + endpoint)!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formEncode(body).data(using: .utf8)
    request.timeoutInterval = 10

    let (responseData, _) = try await URLSession.shared.data(for: request)
    guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    else {
      throw CloudError(message: "Invalid JSON response", code: nil)
    }
    let codeValue = json["errorCode"]
    let code = (codeValue as? String).flatMap { Int($0) } ?? (codeValue as? Int)
    if code == 0 {
      return (json["result"] as? [String: Any]) ?? [:]
    }
    throw CloudError(message: (json["msg"] as? String) ?? "Unknown cloud error", code: code)
  }

  private func baseBody(sessionId: String) -> [String: String] {
    [
      "appId": Self.appId,
      "src": Self.appId,
      "format": "2",
      "clientType": "1",
      "language": "en_US",
      "deviceId": deviceId,
      "stamp": timestamp(),
      "sessionId": sessionId,
    ]
  }

  // Built once and reused instead of per request.
  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter
  }()

  private func timestamp() -> String {
    Self.timestampFormatter.string(from: Date())
  }

  /// SHA256(path + sorted "k=v&…" raw query + appKey), matching msmart's sign.
  private func sign(path: String, body: [String: String]) -> String {
    let query = body.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "&")
    return hexSHA256(path + query + Self.appKey)
  }

  private func encryptPassword(_ loginId: String, _ password: String) -> String {
    hexSHA256(loginId + hexSHA256(password) + Self.appKey)
  }

  private func hexSHA256(_ string: String) -> String {
    DeviceCredentials.bytesToHex(Crypto.sha256(Array(string.utf8)))
  }

  private func formEncode(_ body: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return body.map { key, value in
      let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
  }
}

/// Compute the "udpid" the cloud uses to look up a device's token/key.
public enum UDPID {
  /// Derive the udpid for a device. The byte order isn't known in advance, so
  /// setup tries both values and keeps whichever authenticates.
  ///
  /// - Parameters:
  ///   - deviceId: The device's numeric id.
  ///   - bigEndian: Whether to encode `deviceId` big-endian before hashing.
  /// - Returns: The hex-encoded udpid used to look up the device's keys.
  public static func compute(deviceId: UInt64, bigEndian: Bool) -> String {
    var bytes = [UInt8]()
    var value = deviceId
    for _ in 0..<6 {
      bytes.append(UInt8(value & 0xFF))
      value >>= 8
    }
    if bigEndian { bytes.reverse() }
    let hash = Crypto.sha256(bytes)
    let folded = (0..<16).map { hash[$0] ^ hash[$0 + 16] }
    return DeviceCredentials.bytesToHex(folded)
  }
}
