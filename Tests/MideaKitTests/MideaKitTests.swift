import Testing

@testable import MideaKit

@Suite struct MideaKitTests {
  // Test vector generated from the Python reference (msmart).
  // GetState frame for message id 1:
  //   aa21ac00000000000003418100ff03ff0002000000000000000000000000030169fe
  @Test func getStateBodyCRC() {
    let bodyWithMessageId: [UInt8] = [
      0x41, 0x81, 0x00, 0xFF, 0x03, 0xFF, 0x00, 0x02,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x03,
      0x01,  // message id
    ]
    #expect(CRC8.calculate(bodyWithMessageId) == 0x69)
  }

  @Test func frameChecksum() {
    // Whole GetState frame minus its trailing checksum byte.
    let frameWithoutChecksum: [UInt8] = [
      0xAA, 0x21, 0xAC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
      0x41, 0x81, 0x00, 0xFF, 0x03, 0xFF, 0x00, 0x02,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x69,
    ]
    #expect(Frame.checksum(frameWithoutChecksum[1...]) == 0xFE)
  }

  @Test func aesECBRoundTrip() throws {
    let key = Security.encKey
    let plaintext: [UInt8] = Array("the quick brown fox".utf8)
    let encrypted = try Crypto.encryptECB(key: key, plaintext)
    let decrypted = try Crypto.decryptECB(key: key, encrypted)
    #expect(decrypted == plaintext)
  }

  @Test func aesCBCRoundTrip() throws {
    let key = [UInt8](repeating: 0xAB, count: 32)
    let plaintext = [UInt8](repeating: 0x11, count: 32)  // block-aligned
    let encrypted = try Crypto.encryptCBC(key: key, plaintext)
    let decrypted = try Crypto.decryptCBC(key: key, encrypted)
    #expect(decrypted == plaintext)
  }

  @Test func v2PacketRoundTrip() throws {
    let deviceId: UInt64 = 187_723_572_702_975
    let command = Command.getState()
    let packet = try V2Packet.encode(deviceId: deviceId, command: command)
    let decoded = try V2Packet.decode(packet)
    #expect(decoded == command)
  }

  @Test func targetTemperatureClampsToSupportedRange() {
    let base = ACState(
      powerOn: true, targetTemperature: 22, mode: 0, fanSpeed: 0,
      indoorTemperature: nil, outdoorTemperature: nil, swingMode: 0,
      eco: false, turbo: false, sleep: false, fahrenheit: false, purifier: false,
      displayOn: true, filterAlert: false, freezeProtection: false, targetHumidity: nil)

    // Drop the trailing message id, body CRC, and frame checksum — only those
    // vary between calls (the message id is a global counter).
    func temperatureBytes(_ value: Double) -> [UInt8] {
      var set = SetState(from: base)
      set.targetTemperature = value
      return Array(set.encode().dropLast(3))
    }

    // Out-of-range setpoints snap to the 17–30°C bounds instead of wrapping.
    #expect(temperatureBytes(60) == temperatureBytes(30))
    #expect(temperatureBytes(-5) == temperatureBytes(17))
    // Sanity: an in-range value still encodes distinctly from the clamp target.
    #expect(temperatureBytes(22) != temperatureBytes(30))
  }
}
