/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Owns the simulator's HID connections: made on first use, shared by every caller, and dropped
/// when the simulator changes state.
public actor SimulatorHIDCommands {

  private let input: SimulatorSharedConnection<SimulatorHID>
  /// The hinge, and rotation on a runtime that reports device motion.
  let vendorDefined: SimulatorVendorHIDTransport
  /// The Digital Crown on watchOS.
  let scroll: SimulatorScrollHIDTransport

  public init(simulator: Simulator) {
    self.init(simulator: simulator, vendorDefined: nil)
  }

  init(simulator: Simulator?, vendorDefined: SimulatorVendorHIDTransport?, scroll: SimulatorScrollHIDTransport? = nil) {
    input = SimulatorSharedConnection { [weak simulator] in
      guard let simulator else { throw WeakTargetError.simulator }
      return try await SimulatorHID(for: simulator)
    }
    self.vendorDefined = vendorDefined ?? SimulatorVendorHIDTransport(simulator: simulator)
    self.scroll = scroll ?? SimulatorScrollHIDTransport(simulator: simulator)
  }

  /// The connected HID, connecting on first use and shared with every other caller.
  public func connect() async throws -> SimulatorHID {
    try await input.connection()
  }

  /// Turns the Digital Crown of a watchOS simulator by `delta`, in `steps` equal reports `interval` apart.
  /// Positive scrolls content toward its end, negative toward its start.
  ///
  /// `delta` is in the crown service's own units, and the guest accelerates: on watchOS 27.2 a delta of 50 in
  /// 10 steps 16 ms apart scrolls a Settings list by about one and a half rows, and the same delta in fewer,
  /// larger or faster steps scrolls further. Throws `SimulatorHIDError.dtuhidServiceNotVended` on a runtime
  /// without the scroll service.
  public func rotateDigitalCrown(by delta: Double, steps: Int = 10, interval: Duration = .milliseconds(16)) async throws {
    precondition(steps > 0, "a rotation takes at least one step")
    let step = IndigoScrollEvent.digitalCrown(delta: delta / Double(steps))
    try await scroll.send(Array(repeating: step, count: steps), interval: interval)
  }

  /// Closes the connections, flushing what the input connection still has queued, so the next
  /// `connect()` or vendor-defined send starts afresh.
  public func disconnect() async {
    let closing = await input.reset()
    await vendorDefined.disconnect()
    await scroll.disconnect()
    if let hid = try? await closing?.value {
      await hid.close()
    }
  }
}
