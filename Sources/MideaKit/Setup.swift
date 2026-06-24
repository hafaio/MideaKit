import Foundation

/// Errors thrown by `Setup.run`.
public enum SetupError: Error {
  /// LAN discovery found no devices to set up.
  case noDevicesFound
  /// Devices were discovered, but none could be provisioned — every device
  /// needed a cloud key and all key fetches or local verifications failed. This
  /// usually means a cloud or credentials problem, not an empty network.
  case noCredentialsObtained
}

/// One-shot setup: discover devices on the LAN, fetch each V3 device's token/key
/// from the cloud, verify by authenticating locally, and return credentials
/// ready to store. This is the only step that contacts the cloud.
///
/// Run it once, persist the result (for example with ``CredentialStore``), and
/// from then on construct a ``MideaClient`` from the stored credentials without
/// touching the cloud again:
///
/// ```swift
/// let credentials = try await Setup.run()
/// try CredentialStore.save(credentials, to: storeURL)
/// ```
public enum Setup {
  /// Discover devices, fetch and verify their keys, and return credentials to
  /// store. Defaults to the shared public NetHome Plus account; to use your own,
  /// pass a configured client — `NetHomePlusCloud(account:password:)`, or
  /// `NetHomePlusCloud(region:)` for a different shared region.
  ///
  /// - Parameter cloud: The cloud client used to fetch device keys. Defaults to
  ///   the shared public NetHome Plus account.
  /// - Returns: Credentials for every device that could be set up, ready to
  ///   store. Best-effort: a device that needs a cloud key but fails to fetch or
  ///   verify it is omitted rather than failing the whole run.
  /// - Throws: ``SetupError/noDevicesFound`` if discovery finds no devices, or
  ///   ``SetupError/noCredentialsObtained`` if devices were found but none could
  ///   be provisioned.
  public static func run(cloud: NetHomePlusCloud = NetHomePlusCloud()) async throws
    -> [DeviceCredentials]
  {
    // Discovery is a blocking UDP listen loop; run it off the cooperative pool
    // so it doesn't stall a Swift concurrency thread for the whole timeout.
    let devices = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try Discovery.discover() })
      }
    }
    guard !devices.isEmpty else { throw SetupError.noDevicesFound }

    let session = try await cloud.login()

    // Each device's cloud lookup + local verification is independent, so
    // provision them concurrently: total latency is ~one device's worth rather
    // than the sum over all devices.
    let results = await withTaskGroup(of: DeviceCredentials?.self) { group in
      for device in devices {
        group.addTask { await provision(device, cloud: cloud, session: session) }
      }
      var collected: [DeviceCredentials] = []
      for await result in group {
        if let result { collected.append(result) }
      }
      return collected
    }

    // Discovery found devices but nothing could be provisioned (every device
    // needed a cloud key and all attempts failed) — surface that distinctly
    // rather than returning an empty array that looks like "nothing found".
    guard !results.isEmpty else { throw SetupError.noCredentialsObtained }
    return results
  }

  /// Provision one discovered device. V2 devices need no cloud key and pass
  /// straight through; for a V3 device, fetch its key (trying both udpid byte
  /// orders) and verify it by authenticating locally. Returns nil if a V3
  /// device's key can't be fetched or verified.
  private static func provision(
    _ device: DiscoveredDevice, cloud: NetHomePlusCloud, session: CloudSession
  ) async -> DeviceCredentials? {
    if device.version != 3 {
      return DeviceCredentials(
        name: device.name, id: device.id, ip: device.ip, port: device.port,
        version: device.version, token: "", key: "")
    }

    // The cloud key is looked up by a udpid derived from the device id; try both
    // byte orders and keep whichever authenticates.
    for bigEndian in [false, true] {
      let udpid = UDPID.compute(deviceId: device.id, bigEndian: bigEndian)
      guard let pair = try? await cloud.getToken(session, udpid: udpid) else { continue }
      let client = MideaClient(
        host: device.ip, port: device.port, deviceId: device.id,
        token: DeviceCredentials.hexToBytes(pair.token),
        key: DeviceCredentials.hexToBytes(pair.key))
      do {
        try await client.connect()
        client.disconnect()
        return DeviceCredentials(
          name: device.name, id: device.id, ip: device.ip, port: device.port,
          version: device.version, token: pair.token, key: pair.key)
      } catch {
        continue
      }
    }
    return nil
  }
}
