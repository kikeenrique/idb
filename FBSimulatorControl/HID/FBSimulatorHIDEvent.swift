/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import Foundation

public let DEFAULT_SWIPE_DELTA: Double = 10.0

private let shakeDarwinNotification = "com.apple.UIKit.SimulatorShake"
private let inCallStatusBarNotification = "com.apple.iphonesimulator.toggleincallstatusbar"

// MARK: - FBSimulatorHIDEvent

/// A HID event that can be sent to a Simulator. A discriminated union of the primitive
/// payloads (touch, button, keyboard, two-finger touch, orientation, shake, lock, in-call
/// status bar, delay) plus a `composite` of ordered events.
///
/// Touch payloads take an optional `target` display (see `FBSimulatorHIDDisplayTarget`); it defaults
/// to `nil`, the main display, so `.touch(direction:x:y:)` keeps its meaning.
public indirect enum FBSimulatorHIDEvent: Equatable, Hashable {
  case touch(direction: FBSimulatorHIDDirection, x: Double, y: Double, target: FBSimulatorHIDDisplayTarget? = nil)
  case button(direction: FBSimulatorHIDDirection, button: FBSimulatorHIDButton)
  case keyboard(direction: FBSimulatorHIDDirection, keyCode: UInt32)
  case twoFingerTouch(
    direction: FBSimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint, target: FBSimulatorHIDDisplayTarget? = nil)
  case delay(TimeInterval)
  case deviceOrientation(FBSimulatorHIDDeviceOrientation)
  case shake
  case toggleInCallStatusBar
  case lockDevice
  case composite([FBSimulatorHIDEvent])

  /// For a `.composite` event, its ordered sub-events; otherwise `nil`.
  public var subEvents: [FBSimulatorHIDEvent]? {
    guard case let .composite(events) = self else {
      return nil
    }
    return events
  }
}

// MARK: - Dispatch

public extension FBSimulatorHIDEvent {

  /// Sends the event on the provided HID, completing when delivery is acknowledged.
  /// A `.composite` sends its sub-events in order; `.delay` suspends the task.
  func sendAsync(on hid: FBSimulatorHID) async throws {
    switch self {
    case let .touch(direction, x, y, target):
      try await hid.sendTouch(direction: direction, x: x, y: y, target: target)
    case let .button(direction, button):
      try await hid.sendButton(direction: direction, button: button)
    case let .keyboard(direction, keyCode):
      try await hid.sendKeyboard(direction: direction, keyCode: keyCode)
    case let .twoFingerTouch(direction, finger1, finger2, target):
      try await hid.sendTwoFingerTouch(direction: direction, finger1: finger1, finger2: finger2, target: target)
    case let .delay(duration):
      try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
    case let .deviceOrientation(orientation):
      try hid.sendPurpleEvent(hid.purple.orientationEvent(orientation))
    case .shake:
      try hid.postDarwinNotification(shakeDarwinNotification)
    case .toggleInCallStatusBar:
      try hid.postDarwinNotification(inCallStatusBarNotification)
    case .lockDevice:
      try hid.sendPurpleEvent(hid.purple.lockDeviceEvent())
    case let .composite(events):
      for event in events {
        try await event.sendAsync(on: hid)
      }
    }
  }
}

public extension FBSimulatorHID {

  /// Sends a (possibly composite) HID event, then drains the transport exactly once.
  ///
  /// A `.composite` is flattened to its ordered sub-events so each is logged individually, and a
  /// `.delay` suspends the task; the single drain (`flush()`) then runs after the whole event. So a
  /// tap (down + up) or a typed string settles once, not after every primitive — which keeps the
  /// gesture intact before the connection is torn down while avoiding a per-primitive stall (e.g.
  /// slow typing on the DTUHID transport).
  func send(event: FBSimulatorHIDEvent, logger: FBControlCoreLogger) async throws {
    let transportEvent = event.event(for: transportType)
    for subEvent in transportEvent.subEvents ?? [transportEvent] {
      switch subEvent {
      case let .delay(duration):
        logger.log("Delay \(duration)s")
        try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
      default:
        logger.log("Sending \(subEvent)")
        try await subEvent.sendAsync(on: self)
      }
    }
    try await flush()
  }

  /// Sends `event` with every touch that has no display target routed to `target` (see
  /// `FBSimulatorHIDEvent.targeting(_:)`), then drains once like `send(event:logger:)`. A `nil`
  /// `target` sends the event unchanged.
  func send(
    event: FBSimulatorHIDEvent, target: FBSimulatorHIDDisplayTarget?, logger: FBControlCoreLogger
  ) async throws {
    try await send(event: target.map { event.targeting($0) } ?? event, logger: logger)
  }
}

public extension FBSimulatorHIDEvent {

  /// A copy of the event whose touch and two-finger-touch payloads without a target are routed to
  /// `target`, recursing into composites. Payloads that already name a target, and non-touch
  /// events, are left as they are.
  func targeting(_ target: FBSimulatorHIDDisplayTarget) -> FBSimulatorHIDEvent {
    switch self {
    case let .touch(direction, x, y, nil):
      return .touch(direction: direction, x: x, y: y, target: target)
    case let .twoFingerTouch(direction, finger1, finger2, nil):
      return .twoFingerTouch(direction: direction, finger1: finger1, finger2: finger2, target: target)
    case let .composite(events):
      return .composite(events.map { $0.targeting(target) })
    default:
      return self
    }
  }
}

// MARK: - Transport adaptation

extension FBSimulatorHIDEvent {
  private static let dtuhidApplePayInterPressDelay: TimeInterval = 0.15
  private static let dtuhidKeyboardEventDelay: TimeInterval = 0.01
  private static let dtuhidKeyboardSettleDelay: TimeInterval = 0.05

  func event(for transportType: FBSimulatorHIDTransportType) -> FBSimulatorHIDEvent {
    guard transportType == .dtuhid else {
      return self
    }

    let transportEvent = addingDTUHIDKeyboardPacing(to: replacingApplePayPresses(in: self))
    guard containsKeyboardEvent(transportEvent) else {
      return transportEvent
    }

    return .composite([transportEvent, .delay(Self.dtuhidKeyboardSettleDelay)])
  }

  private func replacingApplePayPresses(in event: FBSimulatorHIDEvent) -> FBSimulatorHIDEvent {
    guard case let .composite(events) = event else {
      return event
    }

    var rewritten: [FBSimulatorHIDEvent] = []
    var index = events.startIndex

    while index < events.endIndex {
      guard case .button(direction: .down, button: .applePay) = events[index],
            let releaseIndex = events[index...].firstIndex(where: {
              if case .button(direction: .up, button: .applePay) = $0 {
                return true
              }
              return false
            }),
            events[events.index(after: index)..<releaseIndex].allSatisfy(isDurationOnly) else {
        rewritten.append(replacingApplePayPresses(in: events[index]))
        index = events.index(after: index)
        continue
      }

      // The caller's hold duration is one command-level invariant, so each physical side-button
      // press receives half of every duration-bearing delay instead of duplicating the duration.
      let press = events[index...releaseIndex].map { applePayPressEvent(from: $0) }
      rewritten.append(contentsOf: press)
      rewritten.append(.delay(Self.dtuhidApplePayInterPressDelay))
      rewritten.append(contentsOf: press)
      index = events.index(after: releaseIndex)
    }

    return .composite(rewritten)
  }

  private func applePayPressEvent(from event: FBSimulatorHIDEvent) -> FBSimulatorHIDEvent {
    switch event {
    case let .button(direction, button) where button == .applePay:
      return .button(direction: direction, button: .sideButton)
    case let .delay(duration):
      return .delay(duration / 2)
    case let .composite(events):
      return .composite(events.map { applePayPressEvent(from: $0) })
    default:
      return event
    }
  }

  private func containsKeyboardEvent(_ event: FBSimulatorHIDEvent) -> Bool {
    switch event {
    case .keyboard:
      return true
    case let .composite(events):
      return events.contains(where: containsKeyboardEvent)
    default:
      return false
    }
  }

  private func isDurationOnly(_ event: FBSimulatorHIDEvent) -> Bool {
    switch event {
    case .delay:
      return true
    case let .composite(events):
      return events.allSatisfy(isDurationOnly)
    default:
      return false
    }
  }

  private func addingDTUHIDKeyboardPacing(to event: FBSimulatorHIDEvent) -> FBSimulatorHIDEvent {
    if case .keyboard = event {
      return .composite([event, .delay(Self.dtuhidKeyboardEventDelay)])
    }
    guard case let .composite(events) = event else {
      return event
    }

    let pacedEvents = events.flatMap { event -> [FBSimulatorHIDEvent] in
      if case .keyboard = event {
        return [event, .delay(Self.dtuhidKeyboardEventDelay)]
      }
      return [addingDTUHIDKeyboardPacing(to: event)]
    }
    return .composite(pacedEvents)
  }
}

// MARK: - Factories

public extension FBSimulatorHIDEvent {

  // Single-payload events use the enum cases directly (`.touch(direction:x:y:)`,
  // `.button(direction:button:)`, `.keyboard(direction:keyCode:)`, `.delay(_:)`,
  // `.deviceOrientation(_:)`, `.shake`, `.lockDevice`, `.toggleInCallStatusBar`, `.composite(_:)`).
  // Only composites with real construction logic are wrapped here. The touch factories take an
  // optional display `target` (default `nil` = main display), applied to every touch they build.

  static func tapAt(x: Double, y: Double, target: FBSimulatorHIDDisplayTarget? = nil) -> FBSimulatorHIDEvent {
    .composite([
      .touch(direction: .down, x: x, y: y, target: target),
      .touch(direction: .up, x: x, y: y, target: target),
    ])
  }

  static func tapAt(
    x: Double, y: Double, duration: Double, target: FBSimulatorHIDDisplayTarget? = nil
  ) -> FBSimulatorHIDEvent {
    .composite([
      .touch(direction: .down, x: x, y: y, target: target),
      .delay(duration),
      .touch(direction: .up, x: x, y: y, target: target),
    ])
  }

  static func shortButtonPress(_ button: FBSimulatorHIDButton) -> FBSimulatorHIDEvent {
    .composite([
      .button(direction: .down, button: button),
      .button(direction: .up, button: button),
    ])
  }

  static func shortKeyPress(_ keyCode: UInt32) -> FBSimulatorHIDEvent {
    .composite([
      .keyboard(direction: .down, keyCode: keyCode),
      .keyboard(direction: .up, keyCode: keyCode),
    ])
  }

  static func shortKeyPressSequence(_ sequence: [NSNumber]) -> FBSimulatorHIDEvent {
    var events: [FBSimulatorHIDEvent] = []
    for keyCode in sequence {
      events.append(.keyboard(direction: .down, keyCode: keyCode.uint32Value))
      events.append(.keyboard(direction: .up, keyCode: keyCode.uint32Value))
    }
    return .composite(events)
  }

  static func swipe(
    _ xStart: Double, yStart: Double, xEnd: Double, yEnd: Double, delta: Double, duration: Double,
    target: FBSimulatorHIDDisplayTarget? = nil
  ) -> FBSimulatorHIDEvent {
    var events: [FBSimulatorHIDEvent] = []
    let distance = sqrt(pow(yEnd - yStart, 2) + pow(xEnd - xStart, 2))
    var effectiveDelta = delta
    if effectiveDelta <= 0.0 {
      effectiveDelta = DEFAULT_SWIPE_DELTA
    }
    let steps = Int(distance / effectiveDelta)

    let dx = (xEnd - xStart) / Double(steps)
    let dy = (yEnd - yStart) / Double(steps)

    let stepDelay = duration / Double(steps + 2)

    for i in 0...steps {
      events.append(
        .touch(direction: .down, x: xStart + dx * Double(i), y: yStart + dy * Double(i), target: target))
      events.append(.delay(stepDelay))
    }
    // Add an additional touch down event at the end of the swipe to avoid inertial scroll on arm simulators.
    events.append(
      .touch(direction: .down, x: xStart + dx * Double(steps), y: yStart + dy * Double(steps), target: target))
    events.append(.delay(stepDelay))

    events.append(.touch(direction: .up, x: xEnd, y: yEnd, target: target))

    return .composite(events)
  }

  static func pinchAt(
    x centerX: Double, y centerY: Double, scale: Double, duration: Double, radius: Double,
    target: FBSimulatorHIDDisplayTarget? = nil
  ) -> FBSimulatorHIDEvent {
    let startRadius = radius
    let endRadius = radius * scale
    let fingerDistance = abs(endRadius - startRadius)

    let delta = DEFAULT_SWIPE_DELTA
    var steps = Int(fingerDistance / delta)
    if steps < 2 { steps = 2 }
    let stepDelay = duration / Double(steps + 2)

    var events: [FBSimulatorHIDEvent] = []

    // Touch down at start positions (fingers on horizontal axis centered on target)
    let f1Start = CGPoint(x: centerX - startRadius, y: centerY)
    let f2Start = CGPoint(x: centerX + startRadius, y: centerY)
    events.append(.twoFingerTouch(direction: .down, finger1: f1Start, finger2: f2Start, target: target))
    events.append(.delay(stepDelay))

    // Interpolated moves — same pattern as swipe
    let dr = (endRadius - startRadius) / Double(steps)
    for i in 1...steps {
      let r = startRadius + dr * Double(i)
      let f1 = CGPoint(x: centerX - r, y: centerY)
      let f2 = CGPoint(x: centerX + r, y: centerY)
      events.append(.twoFingerTouch(direction: .down, finger1: f1, finger2: f2, target: target))
      events.append(.delay(stepDelay))
    }

    // Duplicate final touch-down to avoid inertial scroll on arm simulators
    let f1End = CGPoint(x: centerX - endRadius, y: centerY)
    let f2End = CGPoint(x: centerX + endRadius, y: centerY)
    events.append(.twoFingerTouch(direction: .down, finger1: f1End, finger2: f2End, target: target))
    events.append(.delay(stepDelay))

    // Touch up at end positions
    events.append(.twoFingerTouch(direction: .up, finger1: f1End, finger2: f2End, target: target))

    return .composite(events)
  }
}

// MARK: - CustomStringConvertible

extension FBSimulatorHIDEvent: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .touch(direction, x, y, target):
      guard shouldLogHIDEventDetails() else { return "Touch <hidden>" }
      return "Touch \(direction.name) at (\(UInt(x)),\(UInt(y)))\(targetSuffix(target))"
    case let .button(direction, button):
      guard shouldLogHIDEventDetails() else { return "Button <hidden>" }
      return "Button \(button.name) \(direction.name)"
    case let .keyboard(direction, keyCode):
      guard shouldLogHIDEventDetails() else { return "Key <hidden>" }
      return "Keyboard Code=\(keyCode) \(direction.name)"
    case let .twoFingerTouch(direction, finger1, finger2, target):
      guard shouldLogHIDEventDetails() else { return "TwoFingerTouch <hidden>" }
      let points = "(\(finger1.x),\(finger1.y)) (\(finger2.x),\(finger2.y))"
      return "TwoFingerTouch \(direction.name) at \(points)\(targetSuffix(target))"
    case let .delay(duration):
      return "Delay for \(duration)"
    case let .deviceOrientation(orientation):
      return "Set Orientation \(orientation.name)"
    case .shake:
      return "Shake"
    case .toggleInCallStatusBar:
      return "Toggle In-Call Status Bar"
    case .lockDevice:
      return "Lock Device"
    case let .composite(events):
      return "Composite [\(events.map { $0.description }.joined(separator: ", "))]"
    }
  }
}

// MARK: - Private helpers

private func targetSuffix(_ target: FBSimulatorHIDDisplayTarget?) -> String {
  target.map { " on \($0)" } ?? ""
}

private func shouldLogHIDEventDetails() -> Bool {
  ProcessInfo.processInfo.environment["FBSIMULATORCONTROL_LOG_HID_DETAILS"]?.boolValue ?? false
}

private extension String {
  var boolValue: Bool {
    (self as NSString).boolValue
  }
}
