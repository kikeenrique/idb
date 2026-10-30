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
  static let drainNanos: UInt64 = 80_000_000 // 80ms

  /// How long after connecting the first event send is held back. `dtuhidd` builds a fresh set of
  /// virtual HID services for every peer connection (measured 175-250 ms) and only then handles the
  /// queued events; `backboardd` needs a further ~35-65 ms to attach them. A short-lived host process
  /// that disconnects before that cancels the services with its touch still queued, so the touch is
  /// silently lost; and events queued during setup are replayed as one burst, distorting a gesture's
  /// timing. Holding the first send until the session is up fixes both, and the gesture then runs
  /// with its real timing. `dtuhidd` never replies, so this is a bounded wait rather than a
  /// handshake. Override with `FB_DTUHID_READINESS_MS` (clamped to 0...2000).
  static let defaultReadinessMillis = 400
  static let maximumReadinessMillis = 2000
  static let readinessEnvironmentKey = "FB_DTUHID_READINESS_MS"

  /// The host→guest XPC connection to `dtuhidd`. XPC connections are thread-safe, so it is marked
  /// `nonisolated(unsafe)` to be read from the `nonisolated` `disconnect()` as well as the
  /// actor-isolated send path.
  nonisolated(unsafe) private let connection: xpc_connection_t
  private let mainScreenSize: CGSize
  private let mainScreenScale: Float
  /// When the connection was established (`DispatchTime` uptime nanoseconds); sends measure the
  /// readiness interval from here. Immutable, so it needs no isolation.
  ///
  /// It is not re-armed if the XPC connection is interrupted (e.g. `dtuhidd` restarts while a
  /// long-lived caller holds the transport): the next message then starts a new peer session that
  /// is not waited for. Re-arming needs a mutable, synchronised anchor and a fresh warm-up on
  /// `XPC_ERROR_CONNECTION_INTERRUPTED`; it is left as a follow-up.
  private let connectedAtNanos: UInt64
  /// The readiness interval for this connection (see `defaultReadinessMillis`).
  private let readinessNanos: UInt64
  /// Per-touchscreen contact state for single- and two-finger touches.
  private var contacts = DigitizerContactTrackers()
  private var twoFingerContacts = DigitizerContactTrackers()

  // MARK: Initializers

  /// Builds a DTUHID transport for the provided Simulator, establishing the host XPC connection to
  /// `dtuhidd` and sending the warm-up message. Setup returns at once; the first event sent waits
  /// until the `dtuhidd` session is ready (see `defaultReadinessMillis`).
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

    let transport = FBSimulatorDTUHIDTransport(
      connection: connection,
      mainScreenSize: simulator.device.deviceType.mainScreenSize,
      mainScreenScale: simulator.device.deviceType.mainScreenScale)
    // XPC connects lazily, on the first message: send a no-op now so `dtuhidd` starts building this
    // peer's services immediately, in parallel with whatever the caller does before its first event.
    transport.sendWarmUp()
    return transport
  }

  init(
    connection: xpc_connection_t,
    mainScreenSize: CGSize,
    mainScreenScale: Float,
    readinessNanos: UInt64 = FBSimulatorDTUHIDTransport.readinessNanos(),
    connectedAtNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    self.connection = connection
    self.mainScreenSize = mainScreenSize
    self.mainScreenScale = mainScreenScale
    self.readinessNanos = readinessNanos
    self.connectedAtNanos = connectedAtNanos
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
  /// The actor serializes calls, so per-gesture state stays consistent. On a fresh connection the
  /// send is first held until the `dtuhidd` session is ready (see `readinessWaitNanos`), so the
  /// first gesture reaches `backboardd` with its real timing; once the interval has passed, sends
  /// go out at once. Does not wait for the daemon to consume the event — that is `flush()`'s job,
  /// run once per gesture rather than per primitive.
  func send(messageType: String, payload: some Encodable) async throws {
    let object = try encode(messageType: messageType, payload: payload)
    await waitForSessionReadiness()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      xpc_connection_send_message(connection, object)
      xpc_connection_send_barrier(connection) {
        continuation.resume()
      }
    }
  }

  /// Sleeps until the readiness interval has passed since connecting; returns at once afterwards.
  /// Deadline-based, so concurrent or later sends need no extra state.
  private func waitForSessionReadiness() async {
    let elapsed = DispatchTime.now().uptimeNanoseconds &- connectedAtNanos
    let wait = Self.readinessWaitNanos(elapsedSinceConnect: elapsed, readinessNanos: readinessNanos)
    if wait > 0 {
      try? await Task.sleep(nanoseconds: wait)
    }
  }

  /// Drains the connection once a gesture's events have all been sent: waits `drainNanos` so
  /// `dtuhidd` consumes them before the connection is torn down. Run once per gesture (see
  /// `drainNanos`), not after every primitive.
  func flush() async throws {
    try? await Task.sleep(nanoseconds: Self.drainNanos)
  }

  /// Sends the connection's warm-up message: an `IndigoDigitizerEvent` `end` with no active
  /// contact, which `dtuhidd` accepts without producing a touch, but which makes it begin the
  /// peer session (create its virtual services). Does not touch the contact state.
  nonisolated func sendWarmUp() {
    guard let object = try? encode(messageType: "IndigoDigitizerEvent", payload: Self.warmUpEvent()) else {
      return
    }
    xpc_connection_send_message(connection, object)
  }

  // MARK: Session readiness

  /// The warm-up payload: an `end` on the main touchscreen with no contact in progress.
  static func warmUpEvent() -> IndigoDigitizerEvent {
    IndigoDigitizerEvent(pointOne: DigitizerPoint(x: 0, y: 0), eventType: .end)
  }

  /// How long a send is held: the part of the readiness interval not yet elapsed since connecting,
  /// or `0` once it has passed. So the first event on a fresh connection waits out `dtuhidd`'s
  /// session setup, and every later one goes out at once.
  static func readinessWaitNanos(elapsedSinceConnect: UInt64, readinessNanos: UInt64) -> UInt64 {
    readinessNanos > elapsedSinceConnect ? readinessNanos - elapsedSinceConnect : 0
  }

  /// The readiness interval from `FB_DTUHID_READINESS_MS`, trimmed of whitespace and newlines: an
  /// integer is clamped to `0...maximumReadinessMillis` (an all-digit value too large for `Int`
  /// clamps the same way); anything else, or no value, gives `defaultReadinessMillis`.
  static func readinessNanos(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt64 {
    UInt64(readinessMillis(environment[readinessEnvironmentKey])) * 1_000_000
  }

  private static func readinessMillis(_ raw: String?) -> Int {
    guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return defaultReadinessMillis
    }
    if let value = Int(text) {
      return min(max(value, 0), maximumReadinessMillis)
    }
    let digits = text.first == "-" || text.first == "+" ? text.dropFirst() : Substring(text)
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      return defaultReadinessMillis
    }
    return text.first == "-" ? 0 : maximumReadinessMillis
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
