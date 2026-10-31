/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation

/// The transport for `dtuhidd`'s scroll service, which turns the Digital Crown on watchOS. The service is
/// vended beside the digitizer, so this is a connection of its own, established on first use (most
/// simulators never turn a crown) and then kept. A runtime that does not vend the service fails the first
/// send with `SimulatorHIDError.dtuhidServiceNotVended`.
///
/// `dtuhidd` tears the crown's virtual HID service down, resetting its gesture state, when the connection
/// closes, so a rotation is sent and drained on one connection.
actor SimulatorScrollHIDTransport {
  typealias Connect = @Sendable () async throws -> SimulatorDTUHIDConnection

  static let serviceName = "com.apple.coredevice.feature.remote.hid.scroll"

  private let connection: SimulatorSharedConnection<SimulatorDTUHIDConnection>

  init(simulator: Simulator?) {
    self.init { [weak simulator] in
      guard let simulator else { throw WeakTargetError.simulator }
      return try await SimulatorDTUHIDConnection.connect(using: simulator.xpc, serviceName: Self.serviceName)
    }
  }

  init(connect: @escaping Connect) {
    connection = SimulatorSharedConnection(connect)
  }

  /// Sends `events` `interval` apart, then drains once, so the guest has acted on them when this returns.
  ///
  /// The interval is part of the input: the crown accelerates, so the same deltas sent faster scroll further,
  /// and deltas sent 100 ms or more apart barely scroll at all.
  func send(_ events: [IndigoScrollEvent], interval: Duration) async throws {
    let connection = try await self.connection.connection()
    for (index, event) in events.enumerated() {
      if index > 0 {
        try await Task.sleep(for: interval)
      }
      try await connection.send(messageType: "IndigoScrollEvent", payload: event)
    }
    try await connection.flush()
  }

  /// Tears down the connection, if one was ever established.
  func disconnect() async {
    (try? await connection.reset()?.value)?.disconnect()
  }
}
