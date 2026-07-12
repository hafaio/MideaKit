import Foundation
import Testing

@testable import MideaKit

@Suite struct CredentialsTests {
  /// Credentials persisted before `serialNumber` existed must still decode, with the
  /// serial reported as absent rather than failing the whole load.
  @Test func decodesJSONPersistedWithoutSerialNumber() throws {
    let json = """
      {"name":"ac","id":1234,"ip":"10.0.0.7","port":6444,"version":3,
       "token":"aabb","key":"ccdd"}
      """
    let credentials = try JSONDecoder().decode(
      DeviceCredentials.self, from: Data(json.utf8))

    #expect(credentials.serialNumber == nil)
    #expect(credentials.name == "ac")
    #expect(credentials.tokenBytes == [0xAA, 0xBB])
  }

  /// An absent serial round-trips as absent — it must not come back as `""`.
  @Test func roundTripsAbsentSerialNumber() throws {
    let original = DeviceCredentials(
      name: "ac", id: 1234, ip: "10.0.0.7", port: 6444,
      version: 3, token: "aabb", key: "ccdd", serialNumber: nil)
    let decoded = try JSONDecoder().decode(
      DeviceCredentials.self, from: try JSONEncoder().encode(original))

    #expect(decoded.serialNumber == nil)
  }

  @Test func roundTripsPresentSerialNumber() throws {
    let original = DeviceCredentials(
      name: "ac", id: 1234, ip: "10.0.0.7", port: 6444,
      version: 3, token: "aabb", key: "ccdd", serialNumber: "ABC123")
    let decoded = try JSONDecoder().decode(
      DeviceCredentials.self, from: try JSONEncoder().encode(original))

    #expect(decoded.serialNumber == "ABC123")
  }
}
