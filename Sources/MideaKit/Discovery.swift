import Darwin
import Foundation

/// A device found on the LAN by `Discovery.discover`.
public struct DiscoveredDevice: Sendable {
  /// The device's numeric id.
  public let id: UInt64
  /// The device's IPv4 address.
  public let ip: String
  /// The device's control port.
  public let port: UInt16
  /// The LAN protocol version (2 or 3); V3 devices need a cloud token/key.
  public let version: Int
  /// The device's advertised name.
  public let name: String
  /// The device's serial number, or `nil` if it didn't report one.
  public let serialNumber: String?
}

/// Errors thrown by `Discovery.discover`.
public enum DiscoveryError: Error {
  /// The UDP broadcast socket could not be created.
  case socketCreationFailed
}

/// LAN discovery: broadcast the Midea probe and parse V2/V3 replies.
///
/// `discover()` blocks the calling thread for up to `timeout` while it listens
/// for replies, so call it off the main thread (or any cooperative-pool thread).
/// `Setup.run` already dispatches it to a background queue.
public enum Discovery {
  // The fixed Midea discovery probe (msmart DISCOVERY_MSG).
  private static let probeHex =
    "5a5a01114800920000000000000000000000000000000000000000000000000000000000000000"
    + "007f75bd6b3e4f8b762e849c6e578d6590036e9d4342a50f1f569eb8ec918e92e5"
  private static let ports: [UInt16] = [6445, 20086]

  /// Broadcast the discovery probe and collect replying devices, listening for
  /// up to `timeout` seconds. Blocks the calling thread; see the type's note.
  ///
  /// - Parameter timeout: How long, in seconds, to listen for replies.
  /// - Returns: One entry per device that replied, de-duplicated by id.
  /// - Throws: ``DiscoveryError/socketCreationFailed`` if the socket can't open.
  public static func discover(timeout: TimeInterval = 4) throws -> [DiscoveredDevice] {
    let probe = DeviceCredentials.hexToBytes(probeHex)

    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw DiscoveryError.socketCreationFailed }
    defer { close(fd) }

    var enable: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))
    var receiveTimeout = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(
      fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

    var targets = Set(broadcastAddresses())
    targets.insert("255.255.255.255")
    for target in targets {
      for port in ports {
        send(probe, to: target, port: port, fd: fd)
      }
    }

    var found: [UInt64: DiscoveredDevice] = [:]
    var buffer = [UInt8](repeating: 0, count: 8192)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      var from = sockaddr_in()
      var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let count = withUnsafeMutablePointer(to: &from) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
          recvfrom(fd, &buffer, buffer.count, 0, sockaddrPointer, &fromLength)
        }
      }
      guard count > 0 else { continue }
      let data = Array(buffer[0..<count])
      let ip = ipString(from)
      if let device = parse(data: data, ip: ip), found[device.id] == nil {
        found[device.id] = device
      }
    }
    return Array(found.values)
  }

  static func parse(data: [UInt8], ip: String) -> DiscoveredDevice? {
    guard data.count >= 42 else { return nil }
    let version: Int
    var body = data
    if data[0] == 0x83, data[1] == 0x70 {
      version = 3
      guard data.count > 24 else { return nil }
      body = Array(data[8..<(data.count - 16)])
    } else if data[0] == 0x5A, data[1] == 0x5A {
      version = 2
    } else {
      return nil
    }

    guard body.count >= 56 else { return nil }
    let deviceId = leInt(body[20..<26])
    let encrypted = Array(body[40..<(body.count - 16)])
    guard let decrypted = try? Crypto.decryptECB(key: Security.encKey, encrypted),
      decrypted.count >= 41
    else { return nil }

    let port = UInt16(leInt(decrypted[4..<6]))
    // The serial sits in a fixed 32-byte field, NUL- or space-padded on the wire.
    let serial = String(bytes: decrypted[8..<40], encoding: .ascii)?
      .trimmingCharacters(in: Self.serialPadding)
    let nameLength = Int(decrypted[40])
    let nameEnd = min(41 + nameLength, decrypted.count)
    let name = String(bytes: decrypted[41..<nameEnd], encoding: .utf8) ?? "air-conditioner"

    return DiscoveredDevice(
      id: deviceId, ip: ip, port: port, version: version,
      name: name, serialNumber: serial.flatMap { $0.isEmpty ? nil : $0 }
    )
  }

  private static let serialPadding = CharacterSet(charactersIn: "\0").union(.whitespaces)

  private static func send(_ data: [UInt8], to ip: String, port: UInt16, fd: Int32) {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
    _ = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        sendto(
          fd, data, data.count, 0, sockaddrPointer,
          socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  }

  /// Subnet-directed broadcast addresses of all up IPv4 interfaces.
  private static func broadcastAddresses() -> [String] {
    var addresses: [String] = []
    var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPointer) == 0 else { return addresses }
    defer { freeifaddrs(ifaddrPointer) }

    var current = ifaddrPointer
    while let interface = current {
      let flags = Int32(interface.pointee.ifa_flags)
      // ifa_addr can be nil for some interfaces (e.g. certain tunnels), so guard
      // it rather than force-dereferencing, just as ifa_dstaddr is guarded below.
      if let address = interface.pointee.ifa_addr,
        address.pointee.sa_family == sa_family_t(AF_INET),
        flags & IFF_BROADCAST != 0, flags & IFF_UP != 0,
        let broadcast = interface.pointee.ifa_dstaddr
      {
        var addr = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          $0.pointee
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if let presentation = inet_ntop(
          AF_INET, &addr.sin_addr, &host, socklen_t(INET_ADDRSTRLEN))
        {
          addresses.append(String(cString: presentation))
        }
      }
      current = interface.pointee.ifa_next
    }
    return addresses
  }

  private static func ipString(_ addr: sockaddr_in) -> String {
    var mutable = addr
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard
      let presentation = inet_ntop(
        AF_INET, &mutable.sin_addr, &host, socklen_t(INET_ADDRSTRLEN))
    else {
      return ""
    }
    return String(cString: presentation)
  }

  private static func leInt(_ bytes: ArraySlice<UInt8>) -> UInt64 {
    bytes.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
  }
}
