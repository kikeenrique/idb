/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
@testable import FBSimulatorControl
import XCTest
import XPC

final class FBSimulatorDTUHIDDisplayTargetTests: XCTestCase {

  private let mainScreenSize = CGSize(width: 1170, height: 2532) // pixels
  private let mainScreenScale: Float = 3.0
  private let innerPanel = FBSimulatorHIDDisplayTarget(displayID: 3, nativeSize: CGSize(width: 2007, height: 2853))

  // MARK: Wire encoding

  func testDefaultTargetEncodesMainDisplayAgainstMainScreenSize() throws {
    let event = FBSimulatorDTUHIDTransport.digitizerEvent(
      pointOne: CGPoint(x: 201, y: 482), eventType: .start, target: nil,
      mainScreenSize: mainScreenSize, mainScreenScale: mainScreenScale)
    let payload = try encodedPayload(event)

    XCTAssertEqual(xpc_get_type(xpc_dictionary_get_value(payload, "target")!), XPC_TYPE_UINT64)
    XCTAssertEqual(xpc_dictionary_get_uint64(payload, "target"), 0)
    let pointOne = xpc_dictionary_get_dictionary(payload, "pointOne")!
    XCTAssertEqual(xpc_dictionary_get_double(pointOne, "x"), 201.0 * 3.0 / 1170.0, accuracy: 1e-9)
    XCTAssertEqual(xpc_dictionary_get_double(pointOne, "y"), 482.0 * 3.0 / 2532.0, accuracy: 1e-9)
  }

  func testDisplayTargetEncodesDisplayIDAgainstNativeSize() throws {
    // The inner panel of a foldable: display 3, 2007x2853 native pixels, main scale (3x).
    let event = FBSimulatorDTUHIDTransport.digitizerEvent(
      pointOne: CGPoint(x: 380.33, y: 185.67), eventType: .start, target: innerPanel,
      mainScreenSize: mainScreenSize, mainScreenScale: mainScreenScale)
    let payload = try encodedPayload(event)

    XCTAssertEqual(xpc_get_type(xpc_dictionary_get_value(payload, "target")!), XPC_TYPE_UINT64)
    XCTAssertEqual(xpc_dictionary_get_uint64(payload, "target"), 3)
    let pointOne = xpc_dictionary_get_dictionary(payload, "pointOne")!
    XCTAssertEqual(xpc_dictionary_get_double(pointOne, "x"), 380.33 * 3.0 / 2007.0, accuracy: 1e-9)
    XCTAssertEqual(xpc_dictionary_get_double(pointOne, "y"), 185.67 * 3.0 / 2853.0, accuracy: 1e-9)
    XCTAssertNil(xpc_dictionary_get_dictionary(payload, "pointTwo"))
  }

  func testDisplayTargetScaleOverridesMainScreenScale() throws {
    let target = FBSimulatorHIDDisplayTarget(displayID: 5, nativeSize: CGSize(width: 1000, height: 2000), scale: 2)
    let event = FBSimulatorDTUHIDTransport.digitizerEvent(
      pointOne: CGPoint(x: 100, y: 500), eventType: .end, target: target,
      mainScreenSize: mainScreenSize, mainScreenScale: mainScreenScale)
    let payload = try encodedPayload(event)

    XCTAssertEqual(xpc_dictionary_get_uint64(payload, "target"), 5)
    XCTAssertEqual(xpc_dictionary_get_uint64(payload, "eventType"), 2)
    let pointOne = xpc_dictionary_get_dictionary(payload, "pointOne")!
    XCTAssertEqual(xpc_dictionary_get_double(pointOne, "x"), 0.2, accuracy: 1e-9)
    XCTAssertEqual(xpc_dictionary_get_double(pointOne, "y"), 0.5, accuracy: 1e-9)
  }

  func testTwoFingerDisplayTargetNormalisesBothContacts() throws {
    let event = FBSimulatorDTUHIDTransport.digitizerEvent(
      pointOne: CGPoint(x: 100, y: 200), pointTwo: CGPoint(x: 300, y: 400), eventType: .start, target: innerPanel,
      mainScreenSize: mainScreenSize, mainScreenScale: mainScreenScale)
    let payload = try encodedPayload(event)

    XCTAssertEqual(xpc_dictionary_get_uint64(payload, "target"), 3)
    let pointTwo = xpc_dictionary_get_dictionary(payload, "pointTwo")!
    XCTAssertEqual(xpc_dictionary_get_double(pointTwo, "x"), 300.0 * 3.0 / 2007.0, accuracy: 1e-9)
    XCTAssertEqual(xpc_dictionary_get_double(pointTwo, "y"), 400.0 * 3.0 / 2853.0, accuracy: 1e-9)
  }

  func testWireTarget() {
    XCTAssertEqual(FBSimulatorDTUHIDTransport.wireTarget(for: nil), 0)
    XCTAssertEqual(FBSimulatorDTUHIDTransport.wireTarget(for: innerPanel), 3)
  }

  // MARK: Event model

  func testTouchWithoutTargetDefaultsToNil() {
    XCTAssertEqual(
      FBSimulatorHIDEvent.touch(direction: .down, x: 1, y: 2),
      .touch(direction: .down, x: 1, y: 2, target: nil))
    XCTAssertNotEqual(
      FBSimulatorHIDEvent.touch(direction: .down, x: 1, y: 2),
      .touch(direction: .down, x: 1, y: 2, target: innerPanel))
  }

  func testTapAtCarriesTarget() {
    XCTAssertEqual(
      FBSimulatorHIDEvent.tapAt(x: 10, y: 20, target: innerPanel),
      .composite([
        .touch(direction: .down, x: 10, y: 20, target: innerPanel),
        .touch(direction: .up, x: 10, y: 20, target: innerPanel),
      ]))
    XCTAssertEqual(
      FBSimulatorHIDEvent.tapAt(x: 10, y: 20, target: innerPanel).event(for: .dtuhid),
      FBSimulatorHIDEvent.tapAt(x: 10, y: 20, target: innerPanel))
  }

  func testSwipeTargetsEveryTouch() {
    let swipe = FBSimulatorHIDEvent.swipe(
      0, yStart: 0, xEnd: 0, yEnd: 100, delta: 10, duration: 0.5, target: innerPanel)
    let touches = touchTargets(in: swipe)
    XCTAssertFalse(touches.isEmpty)
    XCTAssertTrue(touches.allSatisfy { $0 == innerPanel })

    let untargeted = FBSimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 0, yEnd: 100, delta: 10, duration: 0.5)
    XCTAssertTrue(touchTargets(in: untargeted).allSatisfy { $0 == nil })
  }

  func testPinchTargetsEveryTouch() {
    let pinch = FBSimulatorHIDEvent.pinchAt(x: 100, y: 100, scale: 2, duration: 0.2, radius: 20, target: innerPanel)
    let touches = touchTargets(in: pinch)
    XCTAssertFalse(touches.isEmpty)
    XCTAssertTrue(touches.allSatisfy { $0 == innerPanel })
  }

  func testTargetingFillsOnlyUntargetedTouches() {
    let cover = FBSimulatorHIDDisplayTarget(displayID: 1, nativeSize: CGSize(width: 1000, height: 2000))
    let event = FBSimulatorHIDEvent.composite([
      .touch(direction: .down, x: 1, y: 2),
      .touch(direction: .up, x: 1, y: 2, target: cover),
      .button(direction: .down, button: .homeButton),
      .composite([
        .twoFingerTouch(direction: .down, finger1: .zero, finger2: CGPoint(x: 1, y: 1)),
        .twoFingerTouch(direction: .up, finger1: .zero, finger2: CGPoint(x: 1, y: 1), target: cover),
      ]),
    ])

    XCTAssertEqual(
      event.targeting(innerPanel),
      .composite([
        .touch(direction: .down, x: 1, y: 2, target: innerPanel),
        .touch(direction: .up, x: 1, y: 2, target: cover),
        .button(direction: .down, button: .homeButton),
        .composite([
          .twoFingerTouch(direction: .down, finger1: .zero, finger2: CGPoint(x: 1, y: 1), target: innerPanel),
          .twoFingerTouch(direction: .up, finger1: .zero, finger2: CGPoint(x: 1, y: 1), target: cover),
        ]),
      ]))
  }

  func testExplicitMainTargetMatchesDefaultOutput() throws {
    let main = FBSimulatorHIDDisplayTarget(displayID: 0, nativeSize: mainScreenSize)
    let point = CGPoint(x: 201, y: 482)
    let explicit = FBSimulatorDTUHIDTransport.digitizerEvent(
      pointOne: point, eventType: .start, target: main,
      mainScreenSize: mainScreenSize, mainScreenScale: mainScreenScale)
    let implicit = FBSimulatorDTUHIDTransport.digitizerEvent(
      pointOne: point, eventType: .start, target: nil,
      mainScreenSize: mainScreenSize, mainScreenScale: mainScreenScale)
    let lhs = try encodedPayload(explicit)
    let rhs = try encodedPayload(implicit)
    XCTAssertTrue(xpc_equal(lhs, rhs))
  }

  // MARK: Per-touchscreen contact tracking

  func testContactTrackersAreIndependentPerDisplay() {
    var trackers = DigitizerContactTrackers()
    XCTAssertEqual(trackers.eventType(for: .down, target: innerPanel), .start)
    XCTAssertEqual(trackers.eventType(for: .down, target: nil), .start)
    XCTAssertEqual(trackers.eventType(for: .down, target: innerPanel), .position)
    XCTAssertEqual(trackers.eventType(for: .up, target: innerPanel), .end)
    XCTAssertEqual(trackers.eventType(for: .down, target: nil), .position)
    XCTAssertEqual(trackers.eventType(for: .up, target: nil), .end)
  }

  func testMainDisplayIDsShareOneTracker() {
    let explicitCover = FBSimulatorHIDDisplayTarget(displayID: 1, nativeSize: mainScreenSize)
    let explicitZero = FBSimulatorHIDDisplayTarget(displayID: 0, nativeSize: mainScreenSize)
    var trackers = DigitizerContactTrackers()
    XCTAssertEqual(trackers.eventType(for: .down, target: nil), .start)
    XCTAssertEqual(trackers.eventType(for: .down, target: explicitCover), .position)
    XCTAssertEqual(trackers.eventType(for: .down, target: explicitZero), .position)
    XCTAssertEqual(trackers.eventType(for: .up, target: explicitCover), .end)
    XCTAssertEqual(DigitizerContactTrackers.serviceKey(for: nil), 0)
    XCTAssertEqual(DigitizerContactTrackers.serviceKey(for: explicitCover), 0)
    XCTAssertEqual(DigitizerContactTrackers.serviceKey(for: innerPanel), 3)
  }

  // MARK: Validation

  func testDTUHIDAcceptsValidTargets() throws {
    try FBSimulatorDTUHIDTransport.validate(target: nil)
    try FBSimulatorDTUHIDTransport.validate(target: innerPanel)
    try FBSimulatorDTUHIDTransport.validate(
      target: FBSimulatorHIDDisplayTarget(displayID: 255, nativeSize: CGSize(width: 10, height: 10), scale: 1))
  }

  func testDTUHIDRejectsDisplayIDAbove255() {
    assertInvalidTarget(displayID: 256) {
      try FBSimulatorDTUHIDTransport.validate(
        target: FBSimulatorHIDDisplayTarget(displayID: 256, nativeSize: CGSize(width: 10, height: 10)))
    }
  }

  func testDTUHIDRejectsDegenerateGeometry() {
    let sizes = [
      CGSize(width: 0, height: 2853),
      CGSize(width: 2007, height: 0),
      CGSize(width: -1, height: 10),
      CGSize(width: CGFloat.nan, height: 10),
      CGSize(width: CGFloat.infinity, height: 10),
    ]
    for size in sizes {
      assertInvalidTarget(displayID: 3) {
        try FBSimulatorDTUHIDTransport.validate(target: FBSimulatorHIDDisplayTarget(displayID: 3, nativeSize: size))
      }
    }
    for scale: Float in [0, -2, .nan, .infinity] {
      assertInvalidTarget(displayID: 3) {
        try FBSimulatorDTUHIDTransport.validate(
          target: FBSimulatorHIDDisplayTarget(displayID: 3, nativeSize: CGSize(width: 10, height: 10), scale: scale))
      }
    }
  }

  func testDTUHIDSendThrowsBeforeSendingForInvalidTarget() async {
    let connection = xpc_connection_create("com.facebook.fbsimulatorcontrol.test.dtuhid", nil)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    let transport = FBSimulatorDTUHIDTransport(
      connection: connection, mainScreenSize: mainScreenSize, mainScreenScale: mainScreenScale)
    defer { transport.disconnect() }

    let tooHigh = FBSimulatorHIDDisplayTarget(displayID: 300, nativeSize: CGSize(width: 10, height: 10))
    let zeroSize = FBSimulatorHIDDisplayTarget(displayID: 3, nativeSize: .zero)
    await assertInvalidTargetAsync(displayID: 300) {
      try await transport.sendTouch(direction: .down, x: 1, y: 1, target: tooHigh)
    }
    await assertInvalidTargetAsync(displayID: 3) {
      try await transport.sendTwoFingerTouch(direction: .down, finger1: .zero, finger2: .zero, target: zeroSize)
    }
  }

  func testIndigoAcceptsOnlyTheMainDisplay() throws {
    try FBSimulatorIndigoHIDTransport.validate(target: nil)
    try FBSimulatorIndigoHIDTransport.validate(
      target: FBSimulatorHIDDisplayTarget(displayID: 0, nativeSize: mainScreenSize))
    try FBSimulatorIndigoHIDTransport.validate(
      target: FBSimulatorHIDDisplayTarget(displayID: 1, nativeSize: mainScreenSize))
    assertInvalidTarget(displayID: 3) { try FBSimulatorIndigoHIDTransport.validate(target: innerPanel) }
    assertInvalidTarget(displayID: 5) {
      try FBSimulatorIndigoHIDTransport.validate(
        target: FBSimulatorHIDDisplayTarget(displayID: 5, nativeSize: mainScreenSize))
    }
  }

  func testDescriptionToleratesNonFiniteSizes() {
    let target = FBSimulatorHIDDisplayTarget(displayID: 3, nativeSize: CGSize(width: CGFloat.nan, height: .infinity))
    XCTAssertTrue(target.description.hasPrefix("display 3 ("))
    XCTAssertEqual(innerPanel.description, "display 3 (2007.0x2853.0 px)")
  }

  // MARK: FBSimulatorHID dispatch

  func testSendWithTargetRoutesUntargetedTouches() async throws {
    let transport = RecordingTransport()
    let hid = FBSimulatorHID(
      transport: transport, transportType: .dtuhid, purple: FBSimulatorPurpleHID(), simulator: nil)
    let cover = FBSimulatorHIDDisplayTarget(displayID: 1, nativeSize: mainScreenSize)
    let event = FBSimulatorHIDEvent.composite([
      .touch(direction: .down, x: 1, y: 2),
      .touch(direction: .up, x: 1, y: 2, target: cover),
      .twoFingerTouch(direction: .down, finger1: .zero, finger2: .zero),
    ])

    try await hid.send(event: event, target: innerPanel, logger: FBControlCoreGlobalConfiguration.defaultLogger)
    let targets = await transport.targets
    XCTAssertEqual(targets, [innerPanel, cover, innerPanel])
    let flushes = await transport.flushes
    XCTAssertEqual(flushes, 1)

    let untargeted = RecordingTransport()
    let plainHID = FBSimulatorHID(
      transport: untargeted, transportType: .dtuhid, purple: FBSimulatorPurpleHID(), simulator: nil)
    try await plainHID.send(
      event: .tapAt(x: 1, y: 2), target: nil, logger: FBControlCoreGlobalConfiguration.defaultLogger)
    let plainTargets = await untargeted.targets
    XCTAssertEqual(plainTargets, [nil, nil])
  }

  // MARK: Helpers

  private func assertInvalidTarget(
    displayID: UInt32, file: StaticString = #filePath, line: UInt = #line, _ block: () throws -> Void
  ) {
    XCTAssertThrowsError(try block(), file: file, line: line) { error in
      guard case let .invalidDisplayTarget(thrownID, _)? = error as? FBSimulatorHIDError else {
        return XCTFail("unexpected error: \(error)", file: file, line: line)
      }
      XCTAssertEqual(thrownID, displayID, file: file, line: line)
    }
  }

  private func assertInvalidTargetAsync(
    displayID: UInt32, file: StaticString = #filePath, line: UInt = #line, _ block: () async throws -> Void
  ) async {
    do {
      try await block()
      XCTFail("expected invalidDisplayTarget", file: file, line: line)
    } catch let FBSimulatorHIDError.invalidDisplayTarget(thrownID, _) {
      XCTAssertEqual(thrownID, displayID, file: file, line: line)
    } catch {
      XCTFail("unexpected error: \(error)", file: file, line: line)
    }
  }

  private func encodedPayload(_ event: IndigoDigitizerEvent) throws -> xpc_object_t {
    let message = try XPCEncoder().encode(
      DTUHIDMessage(
        messageType: "IndigoDigitizerEvent",
        featureIdentifier: FBSimulatorDTUHIDTransport.digitizerServiceName,
        payload: event))
    return try XCTUnwrap(xpc_dictionary_get_dictionary(message, "payload"))
  }

  private func touchTargets(in event: FBSimulatorHIDEvent) -> [FBSimulatorHIDDisplayTarget?] {
    switch event {
    case let .touch(_, _, _, target), let .twoFingerTouch(_, _, _, target):
      return [target]
    case let .composite(events):
      return events.flatMap { touchTargets(in: $0) }
    default:
      return []
    }
  }
}

/// Records the display target of every touch it is asked to send, and counts flushes.
private actor RecordingTransport: FBSimulatorHIDTransport {
  private(set) var targets: [FBSimulatorHIDDisplayTarget?] = []
  private(set) var flushes = 0

  nonisolated func disconnect() {}

  func sendTouch(
    direction: FBSimulatorHIDDirection, x: Double, y: Double, target: FBSimulatorHIDDisplayTarget?
  ) async throws {
    targets.append(target)
  }

  func sendTwoFingerTouch(
    direction: FBSimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint, target: FBSimulatorHIDDisplayTarget?
  ) async throws {
    targets.append(target)
  }

  func sendButton(direction: FBSimulatorHIDDirection, button: FBSimulatorHIDButton) async throws {}

  func sendKeyboard(direction: FBSimulatorHIDDirection, keyCode: UInt32) async throws {}

  func flush() async throws {
    flushes += 1
  }
}
