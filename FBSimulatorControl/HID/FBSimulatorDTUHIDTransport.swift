/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@preconcurrency import CoreSimulator
import Darwin
@preconcurrency import FBControlCore
import Foundation
import XPC

/// Tracks the per-contact phase so that a stream of Indigo `.down`/`.up` events maps onto the
/// `dtuhidd` `start` / `position` / `end` model: the first `.down` is a `start`, subsequent `.down`s
/// (a drag/swipe) are `position`s, and `.up` is the `end`.
struct DigitizerContactTracker {
  private var active = false

  mutating func eventType(for direction: FBSimulatorHIDDirection) -> DigitizerEventType {
    switch direction {
    case .down:
      if active {
        return .position
      }
      active = true
      return .start
    case .up:
      active = false
      return .end
    }
  }
}

/// One `DigitizerContactTracker` per `dtuhidd` touchscreen service, so a gesture on one display
/// never continues (as `position`) a contact begun on another. Keyed by service, not by wire value:
/// `nil`, `0` and `1` all reach `mainTouchscreen(0x101)` and share one tracker.
struct DigitizerContactTrackers {
  private var trackers: [UInt64: DigitizerContactTracker] = [:]

  /// The tracker key for a target: `0` for the main touchscreen, otherwise the display id.
  static func serviceKey(for target: FBSimulatorHIDDisplayTarget?) -> UInt64 {
    guard let target, !target.isMainDisplay else {
      return 0
    }
    return UInt64(target.displayID)
  }

  mutating func eventType(
    for direction: FBSimulatorHIDDirection, target: FBSimulatorHIDDisplayTarget?
  ) -> DigitizerEventType {
    trackers[Self.serviceKey(for: target), default: DigitizerContactTracker()].eventType(for: direction)
  }
}

/**
 The DTUHID transport (Xcode 27 / macOS 26 / iOS 26+).

 Drives the modern `dtuhidd` daemon: events cross the host→guest boundary as plain-XPC dictionaries
 delivered to the `com.apple.coredevice.feature.remote.hid.digitizer` service. Each message is built
 as an `Encodable` model (e.g. `IndigoDigitizerEvent`) wrapped in a `DTUHIDMessage` envelope and
 serialized with `XPCEncoder`, rather than hand-rolled `xpc_dictionary_set_*` calls. The host XPC
 connection is built from the simulator's Mach port via the private `_4sim` endpoint symbols
 (resolved with `dlsym`) and must be marked simulator-to-host with `xpc_connection_enable_sim2host_4sim`
 before messages reach the service handler.

 Capabilities are added one per commit; not-yet-implemented primitives throw
 `notImplementedOnDTUHIDTransport` rather than silently falling back to Indigo.

 An `actor`: the mutable contact state is actor-isolated, so the type needs no `@unchecked Sendable`.
 The XPC connection handle is thread-safe, so `disconnect()` cancels it from a `nonisolated` context.
 */
actor FBSimulatorDTUHIDTransport: FBSimulatorHIDTransport {

  static let digitizerServiceName = "com.apple.coredevice.feature.remote.hid.digitizer"

  // Private XPC endpoint functions, resolved at runtime (not in the XPC module headers).
  private typealias EndpointFromMachPortFn = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
  private typealias ConnectionFromEndpointFn = @convention(c) (xpc_object_t) -> xpc_connection_t?
  private typealias EnableSim2HostFn = @convention(c) (xpc_connection_t) -> Void

  /// Time `flush()` keeps the connection alive after a gesture's events are sent, so `dtuhidd`
  /// consumes them before the connection is torn down. `dtuhidd` resets its virtual services
  /// (dropping any in-flight gesture) the instant the host peer disconnects — which, for a one-shot
  /// gesture from a short-lived host process, is the moment that process exits right after the send.
  /// The XPC send barrier only confirms the bytes reached the connection, not that the daemon
  /// consumed them, and `dtuhidd` does not reply to events or barriers — so a bounded wait is the
  /// only signal available. It runs once per gesture (in `flush()`), not after every primitive.
  private static let drainNanos: UInt64 = 80_000_000 // 80ms

  /// The host→guest XPC connection to `dtuhidd`. XPC connections are thread-safe, so it is marked
  /// `nonisolated(unsafe)` to be read from the `nonisolated` `disconnect()` as well as the
  /// actor-isolated send path.
  nonisolated(unsafe) private let connection: xpc_connection_t
  private let mainScreenSize: CGSize
  private let mainScreenScale: Float
  /// Per-touchscreen contact state for single- and two-finger touches.
  private var contacts = DigitizerContactTrackers()
  private var twoFingerContacts = DigitizerContactTrackers()

  // MARK: Initializers

  /// Builds a DTUHID transport for the provided Simulator, establishing the host XPC connection to
  /// `dtuhidd`. All setup is synchronous, so the returned transport is ready to send.
  static func dtuhid(for simulator: FBSimulator) throws -> FBSimulatorDTUHIDTransport {
    guard let handle = dlopen(nil, RTLD_NOW) else {
      throw FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable
    }
    guard
      let endpointFromPort = symbol(handle, "xpc_endpoint_create_mach_port_4sim", as: EndpointFromMachPortFn.self),
      let connectionFromEndpoint = symbol(handle, "xpc_connection_create_from_endpoint", as: ConnectionFromEndpointFn.self),
      let enableSim2Host = symbol(handle, "xpc_connection_enable_sim2host_4sim", as: EnableSim2HostFn.self)
    else {
      throw FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable
    }

    var lookupError: NSError?
    let servicePort = simulator.device.lookup(digitizerServiceName, error: &lookupError)
    if servicePort == 0 {
      throw FBSimulatorHIDError.dtuhidDigitizerServiceUnavailable(underlying: lookupError)
    }

    guard
      let endpoint = endpointFromPort(servicePort, 0, 0),
      let connection = connectionFromEndpoint(endpoint)
    else {
      throw FBSimulatorHIDError.dtuhidConnectionFailed
    }

    // The load-bearing step: without this the daemon observes the peer but never the payload.
    enableSim2Host(connection)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)

    return FBSimulatorDTUHIDTransport(
      connection: connection,
      mainScreenSize: simulator.device.deviceType.mainScreenSize,
      mainScreenScale: simulator.device.deviceType.mainScreenScale)
  }

  init(connection: xpc_connection_t, mainScreenSize: CGSize, mainScreenScale: Float) {
    self.connection = connection
    self.mainScreenSize = mainScreenSize
    self.mainScreenScale = mainScreenScale
  }

  private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let sym = dlsym(handle, name) else {
      return nil
    }
    return unsafeBitCast(sym, to: type)
  }

  // MARK: FBSimulatorHIDTransport

  nonisolated func disconnect() {
    xpc_connection_cancel(connection)
  }

  func sendTouch(
    direction: FBSimulatorHIDDirection, x: Double, y: Double, target: FBSimulatorHIDDisplayTarget?
  ) async throws {
    try Self.validate(target: target)
    let eventType = contacts.eventType(for: direction, target: target)
    let event = Self.digitizerEvent(
      pointOne: CGPoint(x: x, y: y), eventType: eventType, target: target,
      mainScreenSize: mainScreenSize, mainScreenScale: mainScreenScale)
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  func sendTwoFingerTouch(
    direction: FBSimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint, target: FBSimulatorHIDDisplayTarget?
  ) async throws {
    try Self.validate(target: target)
    let eventType = twoFingerContacts.eventType(for: direction, target: target)
    let event = Self.digitizerEvent(
      pointOne: finger1, pointTwo: finger2, eventType: eventType, target: target,
      mainScreenSize: mainScreenSize, mainScreenScale: mainScreenScale)
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  // MARK: Display targeting

  /// The `IndigoDigitizerEvent.target` for a display target: its display id, or `0` (the main
  /// touchscreen) when there is none. `dtuhidd` routes the event to service `0x100 | target`.
  static func wireTarget(for target: FBSimulatorHIDDisplayTarget?) -> UInt64 {
    UInt64(target?.displayID ?? 0)
  }

  /// Throws `invalidDisplayTarget` for a target `dtuhidd` cannot deliver to, before anything is
  /// sent: an id that does not fit the 8-bit wire `target` (dtuhidd fails the decode and, since it
  /// never replies, the touch would be lost silently), or a size or scale that cannot normalise a
  /// point. Ids with no touchscreen (e.g. 2, 4) are only detectable inside the guest.
  static func validate(target: FBSimulatorHIDDisplayTarget?) throws {
    guard let target else {
      return
    }
    if target.displayID > UInt32(UInt8.max) {
      throw FBSimulatorHIDError.invalidDisplayTarget(
        displayID: target.displayID, reason: "dtuhidd display targets are 8-bit (0...255)")
    }
    if let reason = target.geometryFailureReason {
      throw FBSimulatorHIDError.invalidDisplayTarget(displayID: target.displayID, reason: reason)
    }
  }

  /// Builds the digitizer payload for one or two contacts (in points) on `target`. Points are
  /// normalised against the target display's native pixel size and scale, or against the device's
  /// main screen when `target` is `nil` (the pre-target behaviour). Pure, so it is unit-testable.
  static func digitizerEvent(
    pointOne: CGPoint,
    pointTwo: CGPoint? = nil,
    eventType: DigitizerEventType,
    target: FBSimulatorHIDDisplayTarget?,
    mainScreenSize: CGSize,
    mainScreenScale: Float
  ) -> IndigoDigitizerEvent {
    let screenSize = target?.nativeSize ?? mainScreenSize
    let screenScale = target?.scale ?? mainScreenScale
    func normalised(_ point: CGPoint) -> DigitizerPoint {
      let ratio = FBSimulatorIndigoHID.screenRatio(from: point, screenSize: screenSize, screenScale: screenScale)
      return DigitizerPoint(x: Double(ratio.x), y: Double(ratio.y))
    }
    return IndigoDigitizerEvent(
      pointOne: normalised(pointOne),
      pointTwo: pointTwo.map(normalised),
      eventType: eventType,
      target: wireTarget(for: target))
  }

  func sendButton(direction: FBSimulatorHIDDirection, button: FBSimulatorHIDButton) async throws {
    guard let usage = button.dtuhidUsage else {
      throw FBSimulatorHIDError.notImplementedOnDTUHIDTransport(
        operation: "sendButton(.applePay) — Apple Pay is a double side-button press, not a single HID usage; send two .sideButton presses instead")
    }
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoButtonEvent",
      payload: IndigoButtonEvent(usagePage: UInt64(usage.page), usageCode: UInt64(usage.code), state: state))
  }

  func sendKeyboard(direction: FBSimulatorHIDDirection, keyCode: UInt32) async throws {
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoKeyboardButtonEvent",
      payload: IndigoKeyboardButtonEvent(usageCode: UInt64(keyCode), state: state))
  }

  // MARK: Sending

  /// Wraps `payload` in a `DTUHIDMessage` and serializes it to the `xpc_object_t` `dtuhidd` decodes.
  /// Pure and stateless, so the envelope shape is unit-testable without a live daemon connection.
  nonisolated func encode(messageType: String, payload: some Encodable) throws -> xpc_object_t {
    let message = DTUHIDMessage(
      messageType: messageType, featureIdentifier: Self.digitizerServiceName, payload: payload)
    return try XPCEncoder().encode(message)
  }

  /// Encodes `payload`, sends it over the connection, and resolves when the XPC send barrier fires.
  /// The actor serializes calls, so per-gesture state stays consistent. Does not wait for the daemon
  /// to consume the event — that is `flush()`'s job, run once per gesture rather than per primitive.
  func send(messageType: String, payload: some Encodable) async throws {
    let object = try encode(messageType: messageType, payload: payload)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      xpc_connection_send_message(connection, object)
      xpc_connection_send_barrier(connection) {
        continuation.resume()
      }
    }
  }

  /// Drains the connection once a gesture's events have all been sent: waits `drainNanos` so
  /// `dtuhidd` consumes them before the connection is torn down. Run once per gesture (see
  /// `drainNanos`), not after every primitive.
  func flush() async throws {
    try? await Task.sleep(nanoseconds: Self.drainNanos)
  }

}

// MARK: - Button usage mapping

extension FBSimulatorHIDButton {

  /// The HID usage (page, code) that drives this hardware button via `dtuhidd`'s `mainScreenButtons`
  /// service. All live-confirmed against a booted Xcode 27 / iOS 26 simulator (Consumer page 0x0C).
  /// Apple Pay has no single usage — it is a double-press of the side button — so it is nil.
  var dtuhidUsage: (page: UInt16, code: UInt16)? {
    switch self {
    case .homeButton:
      return (0x0C, 0x40) // Consumer: Menu
    case .lock:
      return (0x0C, 0x30) // Consumer: Power
    case .sideButton:
      return (0x0C, 0x30) // the side button is the power/lock button
    case .siri:
      return (0x0C, 0xCF) // Consumer: Voice Command
    case .applePay:
      return nil // double-press of the side button; not a single HID usage
    }
  }
}
