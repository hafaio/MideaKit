import Testing

@testable import MideaKit

@Suite struct DiscoveryTests {
  // Build a V2-framed (0x5A5A) discovery reply the way a device does: a 40-byte header
  // carrying the device id, then the AES-ECB encrypted body holding port, serial, and
  // name. `serialField` is the raw 32-byte serial field, exactly as it sits on the wire.
  private func reply(
    serialField: [UInt8], deviceId: UInt64 = 0x0000_0102_0304, name: String = "ac"
  ) throws -> [UInt8] {
    #expect(serialField.count == 32)
    let nameBytes = Array(name.utf8)

    var body = [UInt8](repeating: 0, count: 8)
    body[4] = 0x2C  // port 6444, little-endian
    body[5] = 0x19
    body += serialField
    body.append(UInt8(nameBytes.count))
    body += nameBytes

    var header = [UInt8](repeating: 0, count: 40)
    header[0] = 0x5A
    header[1] = 0x5A
    for offset in 0..<6 {
      header[20 + offset] = UInt8((deviceId >> (8 * UInt64(offset))) & 0xFF)
    }

    // parse() strips a trailing 16 bytes before decrypting, so carry that much filler.
    let encrypted = try Crypto.encryptECB(key: Security.encKey, body)
    return header + encrypted + [UInt8](repeating: 0, count: 16)
  }

  /// A full-width serial survives the round trip untouched.
  @Test func parsesFullWidthSerial() throws {
    let serial = "000000P0000000Q1B88C29C3E4E00000"  // exactly 32 bytes: no padding
    let device = Discovery.parse(data: try reply(serialField: Array(serial.utf8)), ip: "10.0.0.7")

    #expect(device?.serialNumber == serial)
    #expect(device?.id == 0x0000_0102_0304)
    #expect(device?.name == "ac")
    #expect(device?.port == 6444)
    #expect(device?.version == 2)
  }

  /// A short serial is NUL-padded on the wire; the padding must not leak into the
  /// value, or it won't compare equal to the serial printed on the unit.
  @Test func trimsPaddingFromShortSerial() throws {
    var field = Array("ABC123".utf8)
    field += [UInt8](repeating: 0, count: 32 - field.count)

    let device = Discovery.parse(data: try reply(serialField: field), ip: "10.0.0.7")

    #expect(device?.serialNumber == "ABC123")
  }

  /// A device that reports no serial sends an all-NUL field. That's absence, not a
  /// 32-character serial made of NULs.
  @Test func reportsMissingSerialAsNil() throws {
    let field = [UInt8](repeating: 0, count: 32)

    let device = Discovery.parse(data: try reply(serialField: field), ip: "10.0.0.7")

    #expect(device != nil)
    #expect(device?.serialNumber == nil)
  }

  /// A space-padded field is empty too.
  @Test func reportsBlankSerialAsNil() throws {
    let field = [UInt8](repeating: 0x20, count: 32)

    let device = Discovery.parse(data: try reply(serialField: field), ip: "10.0.0.7")

    #expect(device?.serialNumber == nil)
  }

  /// A reply that isn't Midea framing is ignored rather than parsed as garbage.
  @Test func rejectsUnknownFraming() throws {
    var data = try reply(serialField: [UInt8](repeating: 0x41, count: 32))
    data[0] = 0x00
    data[1] = 0x00

    #expect(Discovery.parse(data: data, ip: "10.0.0.7") == nil)
  }
}
