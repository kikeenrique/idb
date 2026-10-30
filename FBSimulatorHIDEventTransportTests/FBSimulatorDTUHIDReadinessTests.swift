/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBSimulatorControl
import XCTest
import XPC

final class FBSimulatorDTUHIDReadinessTests: XCTestCase {

  private let ms: UInt64 = 1_000_000

  // MARK: Readiness wait

  func testDrainIsEightyMilliseconds() {
    XCTAssertEqual(FBSimulatorDTUHIDTransport.drainNanos, 80 * ms)
  }

  func testFreshConnectionWaitsOutTheReadinessInterval() {
    XCTAssertEqual(wait(elapsed: 0, readiness: 400 * ms), 400 * ms)
    XCTAssertEqual(wait(elapsed: 25 * ms, readiness: 400 * ms), 375 * ms)
    XCTAssertEqual(wait(elapsed: 399 * ms, readiness: 400 * ms), 1 * ms)
  }

  func testNoWaitOnceTheReadinessIntervalHasPassed() {
    XCTAssertEqual(wait(elapsed: 400 * ms, readiness: 400 * ms), 0)
    XCTAssertEqual(wait(elapsed: 5_000 * ms, readiness: 400 * ms), 0)
    // Readiness disabled.
    XCTAssertEqual(wait(elapsed: 0, readiness: 0), 0)
  }

  // MARK: Environment override

  func testReadinessDefaultsTo400Milliseconds() {
    XCTAssertEqual(FBSimulatorDTUHIDTransport.readinessNanos(environment: [:]), 400 * ms)
  }

  func testReadinessEnvironmentOverride() {
    XCTAssertEqual(readiness("250"), 250 * ms)
    XCTAssertEqual(readiness("+250"), 250 * ms)
    XCTAssertEqual(readiness("0"), 0)
  }

  func testReadinessEnvironmentOverrideTrimsWhitespaceAndNewlines() {
    XCTAssertEqual(readiness(" 600 "), 600 * ms)
    XCTAssertEqual(readiness("500\n"), 500 * ms)
    XCTAssertEqual(readiness("\t300\r\n"), 300 * ms)
  }

  func testReadinessEnvironmentOverrideIsClamped() {
    XCTAssertEqual(readiness("-5"), 0)
    XCTAssertEqual(readiness("2000"), 2_000 * ms)
    XCTAssertEqual(readiness("2001"), 2_000 * ms)
    XCTAssertEqual(readiness("99999999"), 2_000 * ms)
    // Beyond Int range: still an integer, so it clamps instead of falling back.
    XCTAssertEqual(readiness("99999999999999999999"), 2_000 * ms)
    XCTAssertEqual(readiness("-99999999999999999999"), 0)
  }

  func testInvalidReadinessEnvironmentFallsBackToDefault() {
    XCTAssertEqual(readiness(""), 400 * ms)
    XCTAssertEqual(readiness("  \n"), 400 * ms)
    XCTAssertEqual(readiness("abc"), 400 * ms)
    XCTAssertEqual(readiness("1.5"), 400 * ms)
    XCTAssertEqual(readiness("-"), 400 * ms)
    XCTAssertEqual(readiness("12ms"), 400 * ms)
  }

  // MARK: Send and flush timing

  func testFirstSendWaitsForReadinessThenLaterSendsDoNot() async throws {
    let transport = makeTransport(readinessNanos: 250 * ms)
    defer { transport.disconnect() }

    let first = try await measure { try await transport.sendKeyboard(direction: .down, keyCode: 4) }
    XCTAssertGreaterThanOrEqual(first, 0.25 - 0.005)

    let second = try await measure { try await transport.sendKeyboard(direction: .up, keyCode: 4) }
    XCTAssertLessThan(second, 0.2)
  }

  func testSendOnAnAgedConnectionDoesNotWait() async throws {
    let now = DispatchTime.now().uptimeNanoseconds
    let transport = makeTransport(readinessNanos: 400 * ms, connectedAtNanos: now - 1_000 * ms)
    defer { transport.disconnect() }

    let elapsed = try await measure { try await transport.sendKeyboard(direction: .down, keyCode: 4) }
    XCTAssertLessThan(elapsed, 0.3)
  }

  func testFlushOnlyDrainsEvenOnAFreshConnection() async throws {
    let transport = makeTransport(readinessNanos: 1_000 * ms)
    defer { transport.disconnect() }

    let elapsed = try await measure { try await transport.flush() }
    XCTAssertGreaterThanOrEqual(elapsed, 0.08 - 0.005)
    XCTAssertLessThan(elapsed, 0.8)
  }

  // MARK: Warm-up

  func testWarmUpIsADigitizerEndOnTheMainTouchscreen() throws {
    let transport = makeTransport(readinessNanos: 0)
    defer { transport.disconnect() }

    let message = try transport.encode(
      messageType: "IndigoDigitizerEvent", payload: FBSimulatorDTUHIDTransport.warmUpEvent())
    XCTAssertEqual(String(cString: xpc_dictionary_get_string(message, "messageType")!), "IndigoDigitizerEvent")
    let payload = try XCTUnwrap(xpc_dictionary_get_dictionary(message, "payload"))
    XCTAssertEqual(xpc_dictionary_get_uint64(payload, "eventType"), DigitizerEventType.end.rawValue)
    XCTAssertEqual(xpc_dictionary_get_uint64(payload, "target"), 0)
    XCTAssertNil(xpc_dictionary_get_dictionary(payload, "pointTwo"))

    // Sending it on a connection with no peer must not trap.
    transport.sendWarmUp()
  }

  // MARK: Helpers

  private func wait(elapsed: UInt64, readiness: UInt64) -> UInt64 {
    FBSimulatorDTUHIDTransport.readinessWaitNanos(elapsedSinceConnect: elapsed, readinessNanos: readiness)
  }

  private func readiness(_ value: String) -> UInt64 {
    FBSimulatorDTUHIDTransport.readinessNanos(
      environment: [FBSimulatorDTUHIDTransport.readinessEnvironmentKey: value])
  }

  private func makeTransport(
    readinessNanos: UInt64, connectedAtNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) -> FBSimulatorDTUHIDTransport {
    let connection = xpc_connection_create("com.facebook.fbsimulatorcontrol.test.dtuhid", nil)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    return FBSimulatorDTUHIDTransport(
      connection: connection, mainScreenSize: CGSize(width: 100, height: 200), mainScreenScale: 2.0,
      readinessNanos: readinessNanos, connectedAtNanos: connectedAtNanos)
  }

  private func measure(_ block: () async throws -> Void) async throws -> TimeInterval {
    let start = DispatchTime.now().uptimeNanoseconds
    try await block()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }
}
