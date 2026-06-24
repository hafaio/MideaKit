# ``MideaKit``

Local control of Midea (and rebranded) WiFi air conditioners over the LAN — no
cloud after a one-time key fetch.

## Overview

MideaKit discovers air conditioners on the local network, fetches each device's
token/key from the NetHome Plus cloud once, and from then on controls them
entirely over the LAN. Run ``Setup/run(cloud:)`` once, persist the returned
``DeviceCredentials`` (for example with ``CredentialStore``), and reuse a
``MideaClient`` for all subsequent control.

```swift
import MideaKit

// One-time setup (touches the cloud once); persist the result and reuse it.
let credentials = try await Setup.run().first!

let client = MideaClient(credentials: credentials)
let state = try await client.refresh()

_ = try await client.apply { set in
  set.powerOn = true
  set.targetTemperature = 22
  set.mode = OperationalMode.cool.rawValue
}
```

Calls are `async`; drive one ``MideaClient`` from a single task at a time, as the
connection is not re-entrant.

## Topics

### Essentials

- ``MideaClient``
- ``Setup``
- ``DeviceCredentials``
- ``CredentialStore``

### Device state and commands

- ``ACState``
- ``SetState``
- ``OperationalMode``
- ``FanSpeed``
- ``Command``

### Discovery

- ``Discovery``
- ``DiscoveredDevice``

### Cloud key fetch

- ``NetHomePlusCloud``
- ``CloudSession``
- ``UDPID``

### Low-level transport

- ``MideaConnection``

### Errors

- ``SetupError``
- ``DiscoveryError``
- ``CloudError``
- ``TimeoutError``
