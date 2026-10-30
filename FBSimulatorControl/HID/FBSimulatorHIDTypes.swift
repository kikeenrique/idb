/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics

/// The core, transport-agnostic HID value types. Every transport (Indigo, DTUHID) and the
/// `FBSimulatorHIDEvent` dispatch share these; they are intentionally independent of any one
/// transport's wire format. Each carries a single canonical `name` — the source of truth for the
/// string forms used in event descriptions and (upper-cased) in CLI arguments.

/**
 The display a touch is delivered to, for simulators with more than one touchscreen (e.g. a
 foldable's cover and inner panels).

 `displayID` is the simulator display id (`SimDeviceScreen` / devicectl `displayId`): `0` or `1` is
 the main display, other ids address that display's own touchscreen. `nativeSize` is the display's
 native **portrait** size in pixels; touch points (in points, in that display's native portrait
 space) are normalised against it, after multiplying by `scale`. When `scale` is `nil`, the
 device's main screen scale is used.

 Only the DTUHID transport can address a display other than the main one (the id travels as
 `IndigoDigitizerEvent.target`, 8 bits on the wire). Transports validate a target before sending and
 throw `FBSimulatorHIDError.invalidDisplayTarget` rather than misroute the touch: for a non-positive
 or non-finite `nativeSize` or `scale`, for an id above 255 on DTUHID, and for any id other than
 `0`/`1` on the legacy Indigo transport. A `nil` target means the main display normalised against
 the device's main screen size — the behaviour before targets existed.
 */
public struct FBSimulatorHIDDisplayTarget: Equatable, Hashable, Sendable, CustomStringConvertible {
  /// The simulator display id the touch is routed to.
  public let displayID: UInt32
  /// The display's native portrait size, in pixels.
  public let nativeSize: CGSize
  /// The display's points-to-pixels scale; `nil` uses the device's main screen scale.
  public let scale: Float?

  public init(displayID: UInt32, nativeSize: CGSize, scale: Float? = nil) {
    self.displayID = displayID
    self.nativeSize = nativeSize
    self.scale = scale
  }

  /// Whether the target addresses the main display (ids `0` and `1` reach the same touchscreen).
  public var isMainDisplay: Bool {
    displayID <= 1
  }

  public var description: String {
    "display \(displayID) (\(nativeSize.width)x\(nativeSize.height) px)"
  }

  /// Why the target's geometry cannot normalise a point, or `nil` when it can: `nativeSize` must be
  /// finite and positive, and `scale`, when given, finite and positive.
  var geometryFailureReason: String? {
    let width = Double(nativeSize.width)
    let height = Double(nativeSize.height)
    guard width.isFinite, height.isFinite, width > 0, height > 0 else {
      return "native size \(nativeSize.width)x\(nativeSize.height) must be finite and positive"
    }
    if let scale, !(scale.isFinite && scale > 0) {
      return "scale \(scale) must be finite and positive"
    }
    return nil
  }
}

/// The direction of a HID event.
public enum FBSimulatorHIDDirection: Int32, Sendable, CaseIterable {
  case down = 1
  case up = 2

  /// The canonical lower-snake-case name for this direction.
  public var name: String {
    switch self {
    case .down: return "down"
    case .up: return "up"
    }
  }
}

/// A hardware button press.
public enum FBSimulatorHIDButton: Int32, Sendable, CaseIterable {
  case applePay = 1
  case homeButton = 2
  case lock = 3
  case sideButton = 4
  case siri = 5

  /// The canonical lower-snake-case name for this button.
  public var name: String {
    switch self {
    case .applePay: return "apple_pay"
    case .homeButton: return "home"
    case .lock: return "lock"
    case .sideButton: return "side_button"
    case .siri: return "siri"
    }
  }
}

/// Device orientation. Values match UIDeviceOrientation (1-4, excluding faceUp/faceDown).
public enum FBSimulatorHIDDeviceOrientation: Int32, Sendable, CaseIterable {
  case portrait = 1
  case portraitUpsideDown = 2
  case landscapeRight = 3
  case landscapeLeft = 4

  /// The canonical lower-snake-case name for this orientation.
  public var name: String {
    switch self {
    case .portrait: return "portrait"
    case .portraitUpsideDown: return "portrait_upside_down"
    case .landscapeRight: return "landscape_right"
    case .landscapeLeft: return "landscape_left"
    }
  }
}
