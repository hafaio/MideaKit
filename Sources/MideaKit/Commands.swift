import Foundation

/// The air conditioner's operating mode.
public enum OperationalMode: UInt8, CaseIterable, Sendable {
  case auto = 1
  case cool = 2
  case dry = 3
  case heat = 4
  case fanOnly = 5
  case smartDry = 6
}

/// A fan-speed setting. `auto` lets the unit choose; `max` is full power.
public enum FanSpeed: UInt8, CaseIterable, Sendable {
  case silent = 20
  case low = 40
  case medium = 60
  case high = 80
  case auto = 102
  case max = 100
}

/// Global message-id counter, mirroring msmart's incrementing id.
/// Lock-guarded, so safe to share across tasks.
private final class MessageId: @unchecked Sendable {
  static let shared = MessageId()
  private var value: UInt8 = 0
  private let lock = NSLock()
  func next() -> UInt8 {
    lock.lock()
    defer { lock.unlock() }
    value = value &+ 1
    return value
  }
}

/// Wrap a command body in message-id + CRC, then the 0xAA frame.
private func buildCommand(frameType: Frame.FrameType, body: [UInt8]) -> [UInt8] {
  var payload = body
  payload.append(MessageId.shared.next())
  payload.append(CRC8.calculate(payload))
  return Frame.build(frameType: frameType, body: payload)
}

/// Builders for the fixed (non-`SetState`) device command frames.
public enum Command {
  /// Build the command that queries the device's current state.
  ///
  /// - Returns: The encoded query frame.
  public static func getState() -> [UInt8] {
    let body: [UInt8] = [
      0x41,
      0x81, 0x00, 0xFF, 0x03, 0xFF, 0x00,
      0x02,  // TemperatureType.INDOOR
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x03,
    ]
    return buildCommand(frameType: .query, body: body)
  }

  /// Build the command that toggles the unit's LED display on/off. This is a
  /// distinct command, not a ``SetState`` field.
  ///
  /// - Parameter beep: Whether the unit beeps to acknowledge the command.
  /// - Returns: The encoded command frame.
  public static func toggleDisplay(beep: Bool = true) -> [UInt8] {
    let body: [UInt8] = [
      0x41,
      0x02 | (beep ? 0x40 : 0),  // CONTROL_SOURCE | beep
      0x00, 0xFF, 0x02,
      0x00, 0x02, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
    ]
    return buildCommand(frameType: .query, body: body)
  }
}

/// The full settable state, used to build a control command. Start from
/// the current `ACState` and override the fields you want to change so the
/// device keeps everything else as-is.
public struct SetState: Sendable {
  /// Whether the unit beeps to acknowledge the command.
  public var beep: Bool = true
  /// Whether the unit is on.
  public var powerOn: Bool
  /// The target temperature in degrees Celsius, in 0.5° steps. Clamped to 17–30
  /// when sent.
  public var targetTemperature: Double
  /// The operating mode; set from an ``OperationalMode`` raw value, e.g.
  /// `OperationalMode.cool.rawValue`.
  public var mode: UInt8
  /// The fan speed; set from a ``FanSpeed`` raw value, e.g.
  /// `FanSpeed.auto.rawValue`. Other values 0–127 are accepted.
  public var fanSpeed: UInt8
  /// Whether energy-saving (eco) mode is on.
  public var eco: Bool
  /// The louver swing, as a bitmask: 0 = off, 3 = horizontal, 12 = vertical,
  /// 15 = both.
  public var swingMode: UInt8
  /// Whether turbo (boost) mode is on.
  public var turbo: Bool
  /// Whether sleep mode is on.
  public var sleep: Bool
  /// Whether the display reports temperatures in Fahrenheit.
  public var fahrenheit: Bool
  /// Whether the ion/purifier function is on.
  public var purifier: Bool
  /// The target relative humidity in percent (0–100), used by the dry/smart-dry
  /// modes.
  public var targetHumidity: UInt8
  /// Whether freeze (8°C heating) protection is on (only effective on units that
  /// support it).
  public var freezeProtection: Bool

  /// Seed a settable state from the device's current ``ACState``, so unset
  /// fields keep their current values.
  ///
  /// - Parameter state: The device's current state to copy.
  public init(from state: ACState) {
    self.powerOn = state.powerOn
    self.targetTemperature = state.targetTemperature
    self.mode = state.mode
    self.fanSpeed = state.fanSpeed
    self.eco = state.eco
    self.swingMode = state.swingMode
    self.turbo = state.turbo
    self.sleep = state.sleep
    self.fahrenheit = state.fahrenheit
    self.purifier = state.purifier
    self.targetHumidity = state.targetHumidity ?? 40
    self.freezeProtection = state.freezeProtection
  }

  /// Encode this state into a control command for the device.
  ///
  /// - Returns: The encoded command frame.
  public func encode() -> [UInt8] {
    let controlSource: UInt8 = 0x02
    let beepByte: UInt8 = beep ? 0x40 : 0
    let powerByte: UInt8 = powerOn ? 0x01 : 0

    // Clamp to 17–30°C so an out-of-range setpoint snaps to a valid value
    // instead of silently wrapping through the byte masking below.
    let clamped = min(max(targetTemperature, 17), 30)
    let integral = Int(clamped.rounded(.down))
    let hasHalf = clamped - Double(integral) > 0
    var temperature: UInt8
    var temperatureAlt: UInt8
    if (17...30).contains(integral) {
      temperature = UInt8((integral - 16) & 0xF)
      temperatureAlt = 0
    } else {
      temperature = 0
      temperatureAlt = UInt8((integral - 12) & 0x1F)
    }
    if hasHalf { temperature |= 0x10 }

    let modeByte: UInt8 = (mode & 0x7) << 5
    let swingByte: UInt8 = 0x30 | (swingMode & 0x3F)
    let ecoByte: UInt8 = eco ? 0x80 : 0
    let purifierByte: UInt8 = purifier ? 0x20 : 0
    let sleepByte: UInt8 = sleep ? 0x01 : 0
    let turboByte: UInt8 = turbo ? 0x02 : 0
    let fahrenheitByte: UInt8 = fahrenheit ? 0x04 : 0
    let turboAlt: UInt8 = turbo ? 0x20 : 0
    let humidityByte: UInt8 = targetHumidity & 0x7F
    let freezeByte: UInt8 = freezeProtection ? 0x80 : 0

    let body: [UInt8] = [
      0x40,
      controlSource | beepByte | powerByte,
      temperature | modeByte,
      fanSpeed,
      0x7F, 0x7F, 0x00,
      swingByte,
      turboAlt,
      ecoByte | purifierByte,
      sleepByte | turboByte | fahrenheitByte,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00,
      temperatureAlt,
      humidityByte,
      0x00,
      freezeByte,
      0x00,
      0x00,
    ]
    return buildCommand(frameType: .control, body: body)
  }
}

/// A snapshot of the device's current state.
public struct ACState: Sendable {
  /// Whether the unit is on.
  public var powerOn: Bool
  /// The target temperature in degrees Celsius.
  public var targetTemperature: Double
  /// The operating mode, as an `OperationalMode` raw value.
  public var mode: UInt8
  /// The fan speed, as a `FanSpeed` raw value.
  public var fanSpeed: UInt8
  /// The measured indoor temperature, or nil if unavailable.
  public var indoorTemperature: Double?
  /// The measured outdoor temperature, or nil if unavailable.
  public var outdoorTemperature: Double?
  /// The louver swing, as a bitmask: 0 = off, 3 = horizontal, 12 = vertical,
  /// 15 = both.
  public var swingMode: UInt8
  /// Whether energy-saving (eco) mode is on.
  public var eco: Bool
  /// Whether turbo (boost) mode is on.
  public var turbo: Bool
  /// Whether sleep mode is on.
  public var sleep: Bool
  /// Whether the display reports temperatures in Fahrenheit.
  public var fahrenheit: Bool
  /// Whether the ion/purifier function is on.
  public var purifier: Bool
  /// Whether the LED display is on.
  public var displayOn: Bool
  /// Whether the unit is signalling a filter-cleaning alert.
  public var filterAlert: Bool
  /// Whether freeze (8°C heating) protection is on.
  public var freezeProtection: Bool
  /// The target relative humidity (percent), or nil if unsupported.
  public var targetHumidity: UInt8?

  /// Parse a device response frame into state.
  ///
  /// - Parameter frame: A response frame received from the device.
  /// - Returns: The parsed state, or nil if the frame is not a state report.
  /// - Throws: An error if the frame is malformed or fails its checksum.
  public static func parse(frame: [UInt8]) throws -> ACState? {
    guard frame.count >= Frame.headerLength + 2 else { throw ProtocolError.shortPacket }
    guard frame[0] == 0xAA, frame[2] == Frame.deviceTypeAirConditioner else {
      throw ProtocolError.badStartOfPacket
    }
    let expected = Frame.checksum(frame[1..<(frame.count - 1)])
    guard expected == frame[frame.count - 1] else { throw ProtocolError.checksumMismatch }

    let responseId = frame[10]
    guard responseId == 0xC0 else { return nil }

    let payload = Array(frame[10..<(frame.count - 2)])
    // Fixed-offset reads below go up to index 15.
    guard payload.count >= 16 else { return nil }

    let fahrenheit = (payload[10] & 0x4) != 0
    var target = Double(payload[2] & 0xF) + 16.0
    if payload[2] & 0x10 != 0 { target += 0.5 }
    let altTarget = payload[13] & 0x1F
    if altTarget != 0 {
      target = Double(altTarget) + 12.0
      if payload[2] & 0x10 != 0 { target += 0.5 }
    }

    var state = ACState(
      powerOn: (payload[1] & 0x1) != 0,
      targetTemperature: target,
      mode: (payload[2] >> 5) & 0x7,
      fanSpeed: payload[3] & 0x7F,
      indoorTemperature: parseTemperature(
        payload[11], decimals: Double(payload[15] & 0xF) / 10, fahrenheit: fahrenheit),
      outdoorTemperature: parseTemperature(
        payload[12], decimals: Double(payload[15] >> 4) / 10, fahrenheit: fahrenheit),
      swingMode: payload[7] & 0xF,
      eco: (payload[9] & 0x10) != 0,
      turbo: (payload[8] & 0x20) != 0 || (payload[10] & 0x2) != 0,
      sleep: (payload[10] & 0x1) != 0,
      fahrenheit: fahrenheit,
      purifier: (payload[9] & 0x20) != 0,
      displayOn: payload[14] != 0x70,
      filterAlert: (payload[13] & 0x20) != 0,
      freezeProtection: false,
      targetHumidity: nil
    )

    if payload.count >= 20 { state.targetHumidity = payload[19] & 0x7F }
    if payload.count >= 22 { state.freezeProtection = (payload[21] & 0x80) != 0 }
    return state
  }

  private static func parseTemperature(
    _ raw: UInt8, decimals: Double, fahrenheit: Bool
  ) -> Double? {
    if raw == 0xFF { return nil }
    let temperature = (Double(raw) - 50) / 2
    if !fahrenheit && decimals != 0 {
      return Double(Int(temperature)) + (temperature >= 0 ? decimals : -decimals)
    }
    if decimals >= 0.5 {
      return Double(Int(temperature)) + (temperature >= 0 ? 0.5 : -0.5)
    }
    return temperature
  }
}
