import Foundation
import Testing

@testable import MideaKit

/// Cross-validates MideaKit against `vectors.json`, captured from the canonical
/// Python reference (msmart).
@Suite struct VectorsTests {
  private func vectors() throws -> [String: Any] {
    let url = Bundle.module.url(forResource: "vectors", withExtension: "json")!
    let data = try Data(contentsOf: url)
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
  }

  private func hex(_ string: String) -> [UInt8] { DeviceCredentials.hexToBytes(string) }
  private func toHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Compare header+body, ignoring the trailing message-id/CRC/checksum (3
  /// bytes) which depend on a process-global message-id counter.
  private func expectBodyMatches(_ frame: [UInt8], _ expectedHex: String) {
    let expected = hex(expectedHex)
    #expect(Array(frame.dropLast(3)) == Array(expected.dropLast(3)))
  }

  @Test func encKey() throws {
    #expect(toHex(Security.encKey) == (try vectors()["enc_key"] as! String))
  }

  @Test func crc8() throws {
    let crc = try vectors()["crc8"] as! [String: Any]
    #expect(Int(CRC8.calculate(hex(crc["input"] as! String))) == crc["expected"] as! Int)
  }

  @Test func getStateFrame() throws {
    expectBodyMatches(Command.getState(), try vectors()["get_state_frame"] as! String)
  }

  @Test func toggleDisplayFrame() throws {
    expectBodyMatches(Command.toggleDisplay(), try vectors()["toggle_display_frame"] as! String)
  }

  @Test func setStateFrame() throws {
    let setState = try vectors()["set_state"] as! [String: Any]
    let params = setState["params"] as! [String: Any]
    let state = ACState(
      powerOn: params["power_on"] as! Bool,
      targetTemperature: params["target_temperature"] as! Double,
      mode: UInt8(params["operational_mode"] as! Int),
      fanSpeed: UInt8(params["fan_speed"] as! Int),
      indoorTemperature: nil, outdoorTemperature: nil,
      swingMode: UInt8(params["swing_mode"] as! Int),
      eco: params["eco"] as! Bool, turbo: params["turbo"] as! Bool,
      sleep: params["sleep"] as! Bool,
      fahrenheit: params["fahrenheit"] as! Bool, purifier: params["purifier"] as! Bool,
      displayOn: true, filterAlert: false,
      freezeProtection: params["freeze_protection"] as! Bool,
      targetHumidity: UInt8(params["target_humidity"] as! Int))
    var command = SetState(from: state)
    command.beep = params["beep"] as! Bool
    expectBodyMatches(command.encode(), setState["frame"] as! String)
  }

  @Test func udpid() throws {
    let udpid = try vectors()["udpid"] as! [String: Any]
    let deviceId = UInt64(udpid["device_id"] as! Int)
    #expect(UDPID.compute(deviceId: deviceId, bigEndian: false) == udpid["little"] as! String)
    #expect(UDPID.compute(deviceId: deviceId, bigEndian: true) == udpid["big"] as! String)
  }

  @Test func stateResponseParse() throws {
    let response = try vectors()["state_response"] as! [String: Any]
    let parsed = response["parsed"] as! [String: Any]
    let state = try ACState.parse(frame: hex(response["frame"] as! String))!
    #expect(state.powerOn == parsed["power_on"] as! Bool)
    #expect(state.targetTemperature == parsed["target_temperature"] as! Double)
    #expect(Int(state.mode) == parsed["operational_mode"] as! Int)
    #expect(Int(state.fanSpeed) == parsed["fan_speed"] as! Int)
    #expect(state.indoorTemperature == parsed["indoor_temperature"] as? Double)
    #expect(state.outdoorTemperature == parsed["outdoor_temperature"] as? Double)
    #expect(state.displayOn == parsed["display_on"] as! Bool)
  }
}
