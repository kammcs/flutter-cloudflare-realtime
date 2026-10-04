import AVFoundation
import CallKit
import Flutter
import XCTest

@testable import cloudflare_realtime

// The iOS side of system calls (docs/design.md §4.8) without the system's
// UI: the contract's maps, VoIP push payloads, the call registry, the event
// buffer, error mapping, the method handler, and what CallKit does on the
// Simulator. The device checks are in the M11 device test plan.

private let callId = "0f8fad5b-d9cb-469f-a165-70867728950e"

private func dartCall(
  id: String = callId, handle: String = "ada", outgoing: Bool = false,
  extra: [String: Any] = [:]
) -> [String: Any] {
  var map: [String: Any] = [
    "id": id, "handle": handle, "handleType": "generic", "displayName": "Ada",
    "video": true, "outgoing": outgoing,
  ]
  map.merge(extra) { $1 }
  return map
}

final class SystemCallModelTests: XCTestCase {
  func testCallFromDart() throws {
    let call = try XCTUnwrap(SystemCallRecord.fromDart(dartCall()))
    XCTAssertEqual(call.id, callId)
    XCTAssertEqual(call.handle, "ada")
    XCTAssertEqual(call.handleType, "generic")
    XCTAssertEqual(call.displayName, "Ada")
    XCTAssertTrue(call.video)
    XCTAssertFalse(call.outgoing)
    XCTAssertEqual(call.state, .ringing)
    XCTAssertEqual(call.cxHandle.type, .generic)
  }

  func testOutgoingCallDials() throws {
    let call = try XCTUnwrap(SystemCallRecord.fromDart(dartCall(outgoing: true)))
    XCTAssertTrue(call.outgoing)
    XCTAssertEqual(call.state, .dialing)
  }

  func testHandleTypes() throws {
    let phone = try XCTUnwrap(
      SystemCallRecord.fromDart(dartCall(extra: ["handleType": "phoneNumber"])))
    XCTAssertEqual(phone.cxHandle.type, .phoneNumber)
    let email = try XCTUnwrap(
      SystemCallRecord.fromDart(dartCall(extra: ["handleType": "emailAddress"])))
    XCTAssertEqual(email.cxHandle.type, .emailAddress)
    let unknown = try XCTUnwrap(
      SystemCallRecord.fromDart(dartCall(extra: ["handleType": "pager"])))
    XCTAssertEqual(unknown.handleType, "generic")
  }

  func testUppercaseIdIsLowercased() throws {
    let call = try XCTUnwrap(SystemCallRecord.fromDart(dartCall(id: callId.uppercased())))
    XCTAssertEqual(call.id, callId)
  }

  func testMalformedCallsFromDart() {
    XCTAssertNil(SystemCallRecord.fromDart(nil))
    XCTAssertNil(SystemCallRecord.fromDart(["handle": "ada"]))
    XCTAssertNil(SystemCallRecord.fromDart(dartCall(id: "not-a-uuid")))
    XCTAssertNil(SystemCallRecord.fromDart(["id": callId]))
  }

  func testCallMap() throws {
    var call = try XCTUnwrap(SystemCallRecord.fromDart(dartCall(extra: ["displayName": NSNull()])))
    call.payload = ["room": "r1"]
    let map = call.map
    XCTAssertEqual(map["id"] as? String, callId)
    XCTAssertEqual(map["handle"] as? String, "ada")
    XCTAssertEqual(map["handleType"] as? String, "generic")
    XCTAssertTrue(map["displayName"] is NSNull)
    XCTAssertEqual(map["video"] as? Bool, true)
    XCTAssertEqual(map["outgoing"] as? Bool, false)
    XCTAssertEqual(map["state"] as? String, "ringing")
    XCTAssertEqual(map["muted"] as? Bool, false)
    XCTAssertEqual((map["payload"] as? [String: Any])?["room"] as? String, "r1")
    XCTAssertEqual(
      Set(map.keys),
      ["id", "handle", "handleType", "displayName", "video", "outgoing", "state", "muted", "payload"]
    )
  }

  func testEndReasons() {
    XCTAssertNil(SystemCallEndReason.local.callKitReason)
    XCTAssertNil(SystemCallEndReason.declined.callKitReason)
    XCTAssertEqual(SystemCallEndReason.remoteEnded.callKitReason, .remoteEnded)
    XCTAssertEqual(SystemCallEndReason.unanswered.callKitReason, .unanswered)
    XCTAssertEqual(SystemCallEndReason.failed.callKitReason, .failed)
    XCTAssertEqual(SystemCallEndReason.answeredElsewhere.callKitReason, .answeredElsewhere)
    XCTAssertEqual(SystemCallEndReason.declinedElsewhere.callKitReason, .declinedElsewhere)
    // The names are Dart's SystemCallEndReason names.
    XCTAssertEqual(
      SystemCallEndReason.allCases.map(\.rawValue),
      [
        "local", "declined", "remoteEnded", "unanswered", "failed", "answeredElsewhere",
        "declinedElsewhere",
      ])
  }

  func testErrorCodes() {
    func incoming(_ code: CXErrorCodeIncomingCallError.Code) -> SystemCallError {
      SystemCallError.incoming(NSError(domain: CXErrorDomainIncomingCall, code: code.rawValue))
    }
    XCTAssertEqual(incoming(.filteredByDoNotDisturb), .filtered)
    XCTAssertEqual(incoming(.filteredByBlockList), .filtered)
    XCTAssertEqual(incoming(.callUUIDAlreadyExists), .alreadyExists)
    XCTAssertEqual(incoming(.unentitled), .unavailable)
    XCTAssertEqual(incoming(.unknown), .failed)
    XCTAssertEqual(SystemCallError.incoming(NSError(domain: "other", code: 1)), .failed)

    func request(_ code: CXErrorCodeRequestTransactionError.Code) -> SystemCallError {
      SystemCallError.request(
        NSError(domain: CXErrorDomainRequestTransaction, code: code.rawValue))
    }
    XCTAssertEqual(request(.unknownCallUUID), .notFound)
    XCTAssertEqual(request(.callUUIDAlreadyExists), .alreadyExists)
    XCTAssertEqual(request(.unentitled), .unavailable)
    XCTAssertEqual(request(.unknownCallProvider), .unavailable)
    XCTAssertEqual(request(.maximumCallGroupsReached), .unavailable)
    XCTAssertEqual(request(.emptyTransaction), .failed)
    XCTAssertEqual(request(.invalidAction), .failed)

    let error = SystemCallError.notFound.flutterError("gone")
    XCTAssertEqual(error.code, "notFound")
    XCTAssertEqual(error.message, "gone")
  }
}

final class VoipPushPayloadTests: XCTestCase {
  func testFullPayload() {
    let push = VoipPushCall(payload: [
      "aps": ["alert": "ignored"],
      "id": callId.uppercased(),
      "handle": "+15551234567",
      "handleType": "phoneNumber",
      "displayName": "Ada",
      "video": true,
      "room": "r1",
      "nested": ["a": 1],
    ])
    XCTAssertFalse(push.malformed)
    XCTAssertEqual(push.call.id, callId)
    XCTAssertEqual(push.call.handle, "+15551234567")
    XCTAssertEqual(push.call.handleType, "phoneNumber")
    XCTAssertEqual(push.call.displayName, "Ada")
    XCTAssertTrue(push.call.video)
    XCTAssertFalse(push.call.outgoing)
    XCTAssertEqual(push.call.state, .ringing)
    XCTAssertEqual(Set(push.call.payload.keys), ["room", "nested"])
    XCTAssertEqual(push.call.payload["room"] as? String, "r1")
  }

  func testMinimalPayload() {
    let push = VoipPushCall(payload: ["id": callId, "handle": "ada"])
    XCTAssertFalse(push.malformed)
    XCTAssertEqual(push.call.handleType, "generic")
    XCTAssertNil(push.call.displayName)
    XCTAssertFalse(push.call.video)
    XCTAssertTrue(push.call.payload.isEmpty)
  }

  func testVideoFlavours() {
    for value: Any in [true, 1, "true", "1", NSNumber(value: true)] {
      XCTAssertTrue(
        VoipPushCall(payload: ["id": callId, "handle": "a", "video": value]).call.video,
        "\(value)")
    }
    for value: Any in [false, 0, "false", "yes?"] {
      XCTAssertFalse(
        VoipPushCall(payload: ["id": callId, "handle": "a", "video": value]).call.video,
        "\(value)")
    }
  }

  func testMalformedPayloads() {
    let payloads: [[AnyHashable: Any]] = [
      [:],
      ["handle": "ada"],
      ["id": "nope", "handle": "ada"],
      ["id": callId],
      ["id": callId, "handle": ""],
      ["id": 42, "handle": "ada"],
    ]
    for payload in payloads {
      let push = VoipPushCall(payload: payload)
      XCTAssertTrue(push.malformed, "\(payload)")
      XCTAssertEqual(push.call.handle, "unknown")
      XCTAssertEqual(push.call.state, .ringing)
    }
    // A fresh UUID each time, never the malformed one.
    XCTAssertNotEqual(
      VoipPushCall(payload: [:]).call.uuid, VoipPushCall(payload: [:]).call.uuid)
  }

  func testARingingPushIsNoCancel() {
    let push = VoipPushCall(payload: ["id": callId, "handle": "ada", "ended": NSNull()])
    XCTAssertNil(push.endReason)
    XCTAssertNil(push.unknownEndReason)
    XCTAssertFalse(push.malformed)
    XCTAssertTrue(push.call.payload.isEmpty, "`ended` never leaks into the payload")
  }

  func testCancelPayload() {
    let push = VoipPushCall(payload: [
      "aps": [:], "id": callId.uppercased(), "ended": "answeredElsewhere", "room": "r1",
    ])
    XCTAssertEqual(push.endReason, .answeredElsewhere)
    XCTAssertNil(push.unknownEndReason)
    XCTAssertFalse(push.malformed, "a cancel needs no handle")
    XCTAssertEqual(push.call.id, callId)
    XCTAssertEqual(push.call.handle, "unknown")
    XCTAssertEqual(Set(push.call.payload.keys), ["room"])
    // With the call's fields, the placeholder looks like the call.
    let full = VoipPushCall(payload: [
      "id": callId, "handle": "ada", "displayName": "Ada", "ended": "unanswered",
    ])
    XCTAssertEqual(full.call.handle, "ada")
    XCTAssertEqual(full.call.displayName, "Ada")
    // Without an ID, a cancel names no call: a fresh UUID, never a real one.
    let anonymous = VoipPushCall(payload: ["ended": "remoteEnded"])
    XCTAssertFalse(anonymous.malformed)
    XCTAssertEqual(anonymous.endReason, .remoteEnded)
  }

  func testCancelReasons() {
    let reasons: [String: CXCallEndedReason] = [
      "remoteEnded": .remoteEnded, "unanswered": .unanswered, "failed": .failed,
      "answeredElsewhere": .answeredElsewhere, "declinedElsewhere": .declinedElsewhere,
    ]
    for (name, callKit) in reasons {
      let push = VoipPushCall(payload: ["id": callId, "ended": name])
      XCTAssertEqual(push.endReason?.rawValue, name)
      XCTAssertEqual(push.endReason?.callKitReason, callKit, name)
      XCTAssertNil(push.unknownEndReason, name)
    }
  }

  func testCancelWithAnUnknownReasonEndsAsRemoteEnded() {
    // `local` and `declined` happen on this device, not in a push.
    for value: Any in ["local", "declined", "hungUp", "", "REMOTEENDED", true, 3] {
      let push = VoipPushCall(payload: ["id": callId, "ended": value])
      XCTAssertEqual(push.endReason, .remoteEnded, "\(value)")
      XCTAssertNotNil(push.unknownEndReason, "\(value)")
      XCTAssertFalse(push.malformed)
    }
  }
}

final class SystemCallRegistryTests: XCTestCase {
  private func record(_ id: String = callId, outgoing: Bool = false) -> SystemCallRecord {
    SystemCallRecord.fromDart(dartCall(id: id, outgoing: outgoing))!
  }

  func testAddRemoveInOrder() {
    var registry = SystemCallRegistry()
    let second = "1f8fad5b-d9cb-469f-a165-70867728950e"
    XCTAssertTrue(registry.add(record()))
    XCTAssertFalse(registry.add(record()), "a duplicate UUID")
    XCTAssertTrue(registry.add(record(second)))
    XCTAssertEqual(registry.calls.map(\.id), [callId, second])
    XCTAssertEqual(registry.remove(UUID(uuidString: callId)!)?.id, callId)
    XCTAssertNil(registry.remove(UUID(uuidString: callId)!))
    XCTAssertEqual(registry.removeAll().map(\.id), [second])
    XCTAssertTrue(registry.isEmpty)
  }

  func testAnswerOncePerChange() {
    var registry = SystemCallRegistry()
    let uuid = UUID(uuidString: callId)!
    XCTAssertFalse(registry.answer(uuid), "no call")
    registry.add(record())
    XCTAssertTrue(registry.answer(uuid))
    XCTAssertEqual(registry[uuid]?.state, .active)
    XCTAssertFalse(registry.answer(uuid), "already answered")
  }

  func testOutgoingCannotBeAnswered() {
    var registry = SystemCallRegistry()
    registry.add(record(outgoing: true))
    XCTAssertFalse(registry.answer(UUID(uuidString: callId)!))
  }

  func testHoldOncePerChange() {
    var registry = SystemCallRegistry()
    let uuid = UUID(uuidString: callId)!
    registry.add(record())
    XCTAssertFalse(registry.setHeld(uuid, true), "a ringing call")
    XCTAssertTrue(registry.answer(uuid))
    XCTAssertFalse(registry.setHeld(uuid, false), "not held")
    XCTAssertTrue(registry.setHeld(uuid, true))
    XCTAssertEqual(registry[uuid]?.state, .held)
    XCTAssertFalse(registry.setHeld(uuid, true), "already held")
    XCTAssertTrue(registry.setHeld(uuid, false))
    XCTAssertEqual(registry[uuid]?.state, .active)
  }

  func testMuteOncePerChange() {
    var registry = SystemCallRegistry()
    let uuid = UUID(uuidString: callId)!
    registry.add(record())
    XCTAssertFalse(registry.setMuted(uuid, false))
    XCTAssertTrue(registry.setMuted(uuid, true))
    XCTAssertTrue(registry[uuid]!.muted)
    XCTAssertFalse(registry.setMuted(uuid, true))
    XCTAssertTrue(registry.setMuted(uuid, false))
  }
}

final class SystemCallEventsTests: XCTestCase {
  func testBufferedUntilListenedInOrder() {
    let events = SystemCallEvents()
    events.send(["event": "answered", "id": "a"])
    events.send(["event": "muted", "id": "a", "muted": true])
    XCTAssertEqual(events.buffer.count, 2)
    var received: [String] = []
    let owner = NSObject()
    events.listen(owner) { received.append(($0 as! [String: Any])["event"] as! String) }
    XCTAssertEqual(received, ["answered", "muted"])
    XCTAssertTrue(events.buffer.isEmpty)
    events.send(["event": "ended", "id": "a", "reason": "local"])
    XCTAssertEqual(received, ["answered", "muted", "ended"])
  }

  func testEveryEngineGetsEveryEvent() {
    let events = SystemCallEvents()
    var first = 0
    var second = 0
    let a = NSObject()
    let b = NSObject()
    events.listen(a) { _ in first += 1 }
    events.listen(b) { _ in second += 1 }
    events.send(["event": "audioActivated"])
    XCTAssertEqual([first, second], [1, 1])
    events.cancel(a)
    events.send(["event": "audioDeactivated"])
    XCTAssertEqual([first, second], [1, 2])
    events.cancel(b)
    events.send(["event": "voipToken", "token": NSNull()])
    XCTAssertEqual(events.buffer.count, 1, "buffered again once nobody listens")
  }

  func testBufferIsBounded() {
    let events = SystemCallEvents()
    for i in 0..<(SystemCallEvents.bufferLimit + 10) {
      events.send(["event": "dtmf", "id": "a", "digits": "\(i)"])
    }
    XCTAssertEqual(events.buffer.count, SystemCallEvents.bufferLimit)
    XCTAssertEqual(events.buffer.first?["digits"] as? String, "10", "the oldest went first")
  }

  func testStreamHandler() {
    let events = SystemCallEvents()
    events.send(["event": "audioActivated"])
    let stream = SystemCallEventStream(events)
    var received = 0
    XCTAssertNil(stream.onListen(withArguments: nil) { _ in received += 1 })
    XCTAssertEqual(received, 1)
    XCTAssertNil(stream.onCancel(withArguments: nil))
    XCTAssertFalse(events.isListened)
  }
}

/// The method handler and CallKit on the Simulator, with a private
/// UserDefaults suite and without WebRTC's session.
final class SystemCallsHandlerTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!
  // CallKit remembers calls across providers in one process: a new call
  // for each test.
  private var id = ""
  private var made: [SystemCalls] = []

  override func setUp() {
    super.setUp()
    suite = "SystemCallsHandlerTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    id = UUID().uuidString.lowercased()
  }

  override func tearDown() {
    // A provider's calls outlive it until it is invalidated, and would
    // count against the next test's maximum.
    for calls in made { calls.provider?.invalidate() }
    made = []
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  private func make() -> SystemCalls {
    let calls = SystemCalls(defaults: defaults, audio: nil)
    made.append(calls)
    return calls
  }

  private func invoke(_ calls: SystemCalls, _ method: String, _ arguments: Any? = nil) -> Any? {
    let done = expectation(description: method)
    var value: Any?
    calls.handle(FlutterMethodCall(methodName: method, arguments: arguments)) {
      value = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return value
  }

  private func errorCode(_ value: Any?) -> String? { (value as? FlutterError)?.code }

  private let config: [String: Any] = [
    "supportsVideo": true, "maximumCalls": 1, "supportsHolding": true, "supportsDtmf": false,
    "includesCallsInRecents": false, "iconTemplateImageName": NSNull(),
    "ringtoneSound": NSNull(),
  ]

  func testUnknownMethod() {
    let calls = make()
    XCTAssertTrue(
      (invoke(calls, "nope") as AnyObject) === (FlutterMethodNotImplemented as AnyObject))
  }

  func testEndpointsAreAbsentOnIOS() {
    let calls = make()
    XCTAssertNil(invoke(calls, "endpoints", ["id": id]))
    XCTAssertEqual(invoke(calls, "selectEndpoint", ["id": id, "routeId": "x"]) as? Bool, false)
  }

  func testRequestsOnUnknownCalls() {
    let calls = make()
    XCTAssertEqual(errorCode(invoke(calls, "answer", ["id": id])), "notFound")
    XCTAssertEqual(
      errorCode(invoke(calls, "end", ["id": id, "reason": "local"])), "notFound")
    XCTAssertEqual(
      errorCode(invoke(calls, "setHeld", ["id": id, "onHold": true])), "notFound")
    XCTAssertEqual(
      errorCode(invoke(calls, "setMuted", ["id": id, "muted": true])), "notFound")
    XCTAssertEqual(errorCode(invoke(calls, "reportConnected", ["id": id])), "notFound")
    XCTAssertEqual(errorCode(invoke(calls, "update", ["id": id])), "notFound")
    XCTAssertEqual(errorCode(invoke(calls, "answer", [:])), "failed")
  }

  func testReportBeforeConfigure() {
    let calls = make()
    XCTAssertEqual(errorCode(invoke(calls, "reportIncomingCall", dartCall(id: id))), "unavailable")
    XCTAssertEqual(
      errorCode(invoke(calls, "startOutgoingCall", dartCall(id: id, outgoing: true))), "unavailable")
    XCTAssertEqual(errorCode(invoke(calls, "reportIncomingCall", ["id": "x"])), "failed")
    XCTAssertEqual((invoke(calls, "activeCalls") as? [Any])?.count, 0)
  }

  func testConfigurePersistsAndRestores() {
    let calls = make()
    XCTAssertNil(calls.provider)
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    XCTAssertNotNil(calls.provider)
    XCTAssertEqual(calls.provider?.configuration.includesCallsInRecents, false)
    XCTAssertEqual(calls.provider?.configuration.maximumCallsPerCallGroup, 1)
    let saved = defaults.dictionary(forKey: SystemCalls.configKey)
    XCTAssertEqual(saved?["includesCallsInRecents"] as? Bool, false)
    XCTAssertNil(saved?["ringtoneSound"], "Dart's nulls aren't persisted")

    // The next launch: the provider exists before Dart configures.
    let next = make()
    next.restore()
    XCTAssertEqual(next.provider?.configuration.includesCallsInRecents, false)
  }

  func testVoipOptInPersists() {
    let calls = make()
    _ = invoke(calls, "registerVoipPush")
    XCTAssertTrue(defaults.bool(forKey: SystemCalls.voipKey))
    XCTAssertNil(invoke(calls, "unregisterVoipPush"))
    XCTAssertFalse(defaults.bool(forKey: SystemCalls.voipKey))
  }

  func testTokenHex() {
    XCTAssertEqual(SystemCalls.hex(Data([0x00, 0x0f, 0xab, 0xff])), "000fabff")
  }

  /// CallKit has partial Simulator support: what works is recorded here,
  /// and the rest is the device plan's.
  func testIncomingCallFlowOnSimulator() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    var received: [[String: Any]] = []
    let owner = NSObject()
    calls.events.listen(owner) { received.append($0 as! [String: Any]) }
    defer { calls.events.cancel(owner) }

    let reported = invoke(calls, "reportIncomingCall", dartCall(id: id))
    if let error = reported as? FlutterError {
      throw XCTSkip("CallKit refused an incoming call here: \(error.code) \(error.message ?? "")")
    }
    XCTAssertNil(reported)
    XCTAssertEqual(
      errorCode(invoke(calls, "reportIncomingCall", dartCall(id: id))), "alreadyExists")
    let active = invoke(calls, "activeCalls") as? [[String: Any]]
    XCTAssertEqual(active?.count, 1)
    XCTAssertEqual(active?.first?["state"] as? String, "ringing")
    XCTAssertTrue(received.isEmpty, "the app's own report raises no event")

    // Already unmuted, already not held: accepted, no change, no event.
    XCTAssertEqual(invoke(calls, "setMuted", ["id": id, "muted": false]) as? Bool, true)
    XCTAssertEqual(invoke(calls, "setHeld", ["id": id, "onHold": false]) as? Bool, true)
    // A ringing call can't be held.
    XCTAssertEqual(invoke(calls, "setHeld", ["id": id, "onHold": true]) as? Bool, false)
    XCTAssertNil(invoke(calls, "update", ["id": id, "displayName": "Ada L."]))
    XCTAssertEqual(calls.registry.calls.first?.displayName, "Ada L.")

    // The other side gave up: told, not asked, so the event comes from here.
    XCTAssertEqual(
      invoke(calls, "end", ["id": id, "reason": "unanswered"]) as? Bool, true)
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first?["event"] as? String, "ended")
    XCTAssertEqual(received.first?["id"] as? String, id)
    XCTAssertEqual(received.first?["reason"] as? String, "unanswered")
    XCTAssertEqual((invoke(calls, "activeCalls") as? [Any])?.count, 0)
  }

  /// Answering and ending through `CXCallController`, which needs CallKit's
  /// daemon to perform the actions.
  func testAnswerAndEndThroughCallKitOnSimulator() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    var received: [[String: Any]] = []
    let owner = NSObject()
    calls.events.listen(owner) { received.append($0 as! [String: Any]) }
    defer { calls.events.cancel(owner) }
    if let error = invoke(calls, "reportIncomingCall", dartCall(id: id)) as? FlutterError {
      throw XCTSkip("CallKit refused an incoming call here: \(error.code)")
    }
    guard invoke(calls, "answer", ["id": id]) as? Bool == true else {
      _ = invoke(calls, "end", ["id": id, "reason": "failed"])
      throw XCTSkip("CallKit refused the answer action here")
    }
    try waitFor { received.contains { $0["event"] as? String == "answered" } }
    XCTAssertEqual(received.first?["event"] as? String, "answered")
    XCTAssertEqual(received.first?["id"] as? String, id)
    // Let CallKit settle (audio activation). The Simulator can't activate
    // call audio, and CallKit then ends the call itself with an end action:
    // that is the system's UI ending it, so the event says `local`.
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    print("SystemCallsTests: events after answering: \(received)")
    if calls.registry.isEmpty {
      XCTAssertEqual(received.count, 2)
      XCTAssertEqual(received.last?["event"] as? String, "ended")
      XCTAssertEqual(received.last?["reason"] as? String, "local")
      XCTAssertEqual(
        errorCode(invoke(calls, "setMuted", ["id": id, "muted": true])), "notFound")
      throw XCTSkip("CallKit ended the answered call itself here (no call audio): \(received)")
    }
    XCTAssertEqual(calls.registry.calls.first?.state, .active)

    XCTAssertEqual(invoke(calls, "setMuted", ["id": id, "muted": true]) as? Bool, true)
    try waitFor { received.contains { $0["event"] as? String == "muted" } }
    XCTAssertEqual(calls.registry.calls.first?.muted, true)

    XCTAssertEqual(invoke(calls, "end", ["id": id, "reason": "local"]) as? Bool, true)
    try waitFor { received.contains { $0["event"] as? String == "ended" } }
    let ended = received.first { $0["event"] as? String == "ended" }
    XCTAssertEqual(ended?["reason"] as? String, "local")
    XCTAssertEqual(
      received.filter { $0["event"] as? String == "answered" }.count, 1, "once per change")
    XCTAssertTrue(calls.registry.isEmpty)
  }

  func testOutgoingCallOnSimulator() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    var received: [[String: Any]] = []
    let owner = NSObject()
    calls.events.listen(owner) { received.append($0 as! [String: Any]) }
    defer { calls.events.cancel(owner) }
    if let error = invoke(calls, "startOutgoingCall", dartCall(id: id, outgoing: true)) as? FlutterError {
      XCTAssertTrue(calls.registry.isEmpty, "a refused start leaves no call")
      throw XCTSkip(
        "CallKit refused the start action here: \(error.code) \(error.message ?? "")")
    }
    XCTAssertEqual(calls.registry.calls.first?.state, .dialing)
    XCTAssertNil(invoke(calls, "reportConnecting", ["id": id]))
    XCTAssertEqual(calls.registry.calls.first?.state, .connecting)
    XCTAssertNil(invoke(calls, "reportConnected", ["id": id]))
    XCTAssertEqual(calls.registry.calls.first?.state, .active)
    XCTAssertEqual(invoke(calls, "end", ["id": id, "reason": "local"]) as? Bool, true)
    try waitFor { received.contains { $0["event"] as? String == "ended" } }
    XCTAssertTrue(calls.registry.isEmpty)
  }

  func testMalformedPushIsReportedAndEndedWithoutEvents() {
    let calls = make()
    let done = expectation(description: "push completion")
    calls.reportPush(["aps": [:], "room": "r1"]) { done.fulfill() }
    wait(for: [done], timeout: 10)
    XCTAssertNotNil(calls.provider, "a push before configure uses the defaults")
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertTrue(calls.events.buffer.isEmpty)
    XCTAssertEqual(calls.placeholdersReported, 1)
  }

  private func push(_ calls: SystemCalls, _ payload: [AnyHashable: Any]) {
    let done = expectation(description: "push completion")
    calls.reportPush(payload) { done.fulfill() }
    wait(for: [done], timeout: 10)
  }

  /// Reports an incoming call the way the app's signaling does, or skips
  /// where CallKit refuses one.
  private func reportRinging(_ calls: SystemCalls) throws {
    if let error = invoke(calls, "reportIncomingCall", dartCall(id: id)) as? FlutterError {
      throw XCTSkip("CallKit refused an incoming call here: \(error.code)")
    }
  }

  /// No call is left ringing or going in CallKit: the placeholders ended.
  private func waitForCallKitIdle() throws {
    let observer = CXCallObserver()
    try waitFor { observer.calls.allSatisfy { $0.hasEnded } }
  }

  func testCancelPushEndsAKnownCallWithItsReason() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    var received: [[String: Any]] = []
    let owner = NSObject()
    calls.events.listen(owner) { received.append($0 as! [String: Any]) }
    defer { calls.events.cancel(owner) }
    try reportRinging(calls)

    push(calls, ["id": id, "ended": "answeredElsewhere"])
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first?["event"] as? String, "ended")
    XCTAssertEqual(received.first?["id"] as? String, id)
    XCTAssertEqual(received.first?["reason"] as? String, "answeredElsewhere")
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertEqual(calls.placeholdersReported, 0, "the call itself was the report")
    XCTAssertEqual(calls.endedReason(UUID(uuidString: id)!), .answeredElsewhere)

    // The same cancel again: reported (iOS requires it) under the call's
    // own UUID, and ignored.
    push(calls, ["id": id, "ended": "answeredElsewhere"])
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(calls.repeatReports, 1)
    // The call's own push, late or pushed again: it doesn't ring.
    push(calls, ["id": id, "handle": "ada"])
    XCTAssertEqual(received.count, 1, "no `reported` event")
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertEqual(calls.repeatReports, 2)
    XCTAssertEqual(calls.placeholdersReported, 0, "no stand-in call")
    try waitForCallKitIdle()
  }

  func testCancelPushForAPushedCallBeforeDartListens() throws {
    let calls = make()
    push(calls, ["id": id, "handle": "ada", "room": "r1"])
    if calls.registry.isEmpty { throw XCTSkip("CallKit refused the pushed call here") }
    push(calls, ["id": id, "ended": "unanswered"])
    // Both wait for Dart, in order: the call arrives, then ends.
    XCTAssertEqual(calls.events.buffer.map { $0["event"] as? String }, ["reported", "ended"])
    XCTAssertEqual(calls.events.buffer.last?["id"] as? String, id)
    XCTAssertEqual(calls.events.buffer.last?["reason"] as? String, "unanswered")
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertEqual(calls.placeholdersReported, 0)
  }

  func testCancelPushForAnUnknownCallDoesNotRing() throws {
    // The cancel launched the app: before configure, with no call.
    let calls = make()
    push(calls, ["id": id, "handle": "ada", "ended": "remoteEnded", "room": "r1"])
    XCTAssertNotNil(calls.provider)
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertTrue(calls.events.buffer.isEmpty, "no `reported` event: nothing rings")
    XCTAssertEqual(calls.placeholdersReported, 1)
    XCTAssertEqual(calls.endedReason(UUID(uuidString: id)!), .remoteEnded)
    // An unknown reason, and a cancel without an ID: the same.
    push(calls, ["id": UUID().uuidString, "ended": "hungUp"])
    push(calls, ["ended": "remoteEnded"])
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertTrue(calls.events.buffer.isEmpty)
    XCTAssertEqual(calls.placeholdersReported, 3)
    try waitForCallKitIdle()
    // Dart then configures and finds no call.
    XCTAssertEqual((invoke(calls, "activeCalls") as? [Any])?.count, 0)
  }

  /// A call this device took (answered, or an outgoing call): a reason
  /// about the ring doesn't end it, the other side hanging up does.
  func testCancelPushForACallAlreadyTaken() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    var received: [[String: Any]] = []
    let owner = NSObject()
    calls.events.listen(owner) { received.append($0 as! [String: Any]) }
    defer { calls.events.cancel(owner) }
    if let error = invoke(calls, "startOutgoingCall", dartCall(id: id, outgoing: true))
      as? FlutterError
    {
      throw XCTSkip("CallKit refused the start action here: \(error.code)")
    }
    XCTAssertNil(invoke(calls, "reportConnected", ["id": id]))
    XCTAssertEqual(calls.registry.calls.first?.state, .active)

    for reason in ["answeredElsewhere", "declinedElsewhere", "unanswered"] {
      push(calls, ["id": id, "ended": reason])
    }
    XCTAssertEqual(calls.registry.calls.first?.state, .active, "still in the call")
    XCTAssertTrue(received.isEmpty)
    XCTAssertNil(calls.endedReason(UUID(uuidString: id)!))

    push(calls, ["id": id, "ended": "remoteEnded"])
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first?["event"] as? String, "ended")
    XCTAssertEqual(received.first?["reason"] as? String, "remoteEnded")
    XCTAssertEqual(calls.placeholdersReported, 0)
  }

  /// The app ended the ring itself (its own timeout), and the server's
  /// cancel came at once: reported again under the call's own UUID, which
  /// CallKit still refuses (`callUUIDAlreadyExists`), so nothing shows and
  /// no event follows.
  func testCancelPushRightAfterTheAppEndedTheRingIsRefused() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    var received: [[String: Any]] = []
    let owner = NSObject()
    calls.events.listen(owner) { received.append($0 as! [String: Any]) }
    defer { calls.events.cancel(owner) }
    try reportRinging(calls)
    XCTAssertEqual(invoke(calls, "end", ["id": id, "reason": "unanswered"]) as? Bool, true)
    XCTAssertEqual(received.map { $0["event"] as? String }, ["ended"])
    XCTAssertEqual(calls.endedReason(UUID(uuidString: id)!), .unanswered)

    push(calls, ["id": id, "ended": "unanswered"])
    XCTAssertEqual(received.count, 1, "no new call, no event")
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertEqual(calls.placeholdersReported, 0, "no stand-in call")
    XCTAssertEqual(calls.repeatReports, 1)
    XCTAssertEqual(calls.repeatReportsRefused, 1, "CallKit still remembers the UUID")
    try waitForCallKitIdle()
  }

  /// The field report's case: the cancel came seconds after the app's own
  /// timeout. CallKit has forgotten the UUID by then (on the Simulator it
  /// refuses a UUID it ended by `reportCall(endedAt:)` for under 2 s, and
  /// accepts one ended by an end action at once), so the repeat report is
  /// a call again, ended at once: no ring, no event, but it can show for
  /// an instant, as a stand-in would (docs/design.md §4.8, Pushes for
  /// calls that ended). This records that limit.
  func testCancelPushLongAfterTheAppEndedTheRingEndsAtOnce() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    var received: [[String: Any]] = []
    let owner = NSObject()
    calls.events.listen(owner) { received.append($0 as! [String: Any]) }
    defer { calls.events.cancel(owner) }
    try reportRinging(calls)
    XCTAssertEqual(invoke(calls, "end", ["id": id, "reason": "unanswered"]) as? Bool, true)
    RunLoop.main.run(until: Date().addingTimeInterval(3))

    push(calls, ["id": id, "ended": "unanswered"])
    XCTAssertEqual(received.count, 1, "no new call, no event")
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertEqual(calls.placeholdersReported, 0)
    XCTAssertEqual(calls.repeatReports, 1)
    XCTAssertEqual(calls.repeatReportsRefused, 0, "CallKit forgot the UUID (Simulator)")
    try waitForCallKitIdle()
  }

  /// Any end, whoever ended it: the app's `local` end (an end action) here.
  /// The call's push arriving afterwards doesn't ring again (reported and
  /// ended at once: CallKit accepts a UUID an end action ended).
  func testRingPushAfterALocalEndDoesNotRing() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    var received: [[String: Any]] = []
    let owner = NSObject()
    calls.events.listen(owner) { received.append($0 as! [String: Any]) }
    defer { calls.events.cancel(owner) }
    try reportRinging(calls)
    // `true`, or `false` when CallKit already ended it itself (the
    // Simulator has no UI to host a ringing call): ended either way.
    _ = invoke(calls, "end", ["id": id, "reason": "local"])
    try waitFor { calls.registry.isEmpty }
    XCTAssertNotNil(calls.endedReason(UUID(uuidString: id)!))
    let before = received.count

    push(calls, ["id": id, "handle": "ada", "displayName": "Ada", "room": "r1"])
    XCTAssertEqual(received.count, before, "no `reported` event: it doesn't ring")
    XCTAssertTrue(calls.registry.isEmpty)
    XCTAssertEqual(calls.placeholdersReported, 0)
    XCTAssertEqual(calls.repeatReports, 1)
    XCTAssertEqual((invoke(calls, "activeCalls") as? [Any])?.count, 0)
    try waitForCallKitIdle()
  }

  /// A pushed call CallKit ended for the app (any end raises `ended`) is
  /// remembered too, as is one ended because CallKit no longer had it.
  func testEveryEndIsRemembered() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    push(calls, ["id": id, "handle": "ada"])
    if !calls.registry.isEmpty {
      XCTAssertEqual(invoke(calls, "end", ["id": id, "reason": "remoteEnded"]) as? Bool, true)
    }
    XCTAssertNotNil(calls.endedReason(UUID(uuidString: id)!))
    calls.events.listen(self) { _ in }
    defer { calls.events.cancel(self) }
    push(calls, ["id": id, "handle": "ada"])
    XCTAssertTrue(calls.registry.isEmpty, "the second push doesn't ring")
    XCTAssertEqual(calls.placeholdersReported, 0)
    try waitForCallKitIdle()
  }

  func testPushedCallIsReportedAndBuffered() {
    let calls = make()
    let done = expectation(description: "push completion")
    calls.reportPush(["id": id, "handle": "ada", "displayName": "Ada", "room": "r1"]) {
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    // Dart isn't listening: the `reported` event waits for it.
    let first = calls.events.buffer.first
    XCTAssertEqual(first?["event"] as? String, "reported")
    let call = first?["call"] as? [String: Any]
    XCTAssertEqual(call?["id"] as? String, id)
    XCTAssertEqual(call?["state"] as? String, "ringing")
    XCTAssertEqual((call?["payload"] as? [String: Any])?["room"] as? String, "r1")
    if calls.registry.isEmpty {
      // CallKit refused it here: ended as failed.
      XCTAssertEqual(calls.events.buffer.last?["event"] as? String, "ended")
      XCTAssertEqual(calls.events.buffer.last?["reason"] as? String, "failed")
    } else {
      // A pushed call Dart reports again is a duplicate.
      XCTAssertEqual(errorCode(invoke(calls, "reportIncomingCall", dartCall(id: id))), "alreadyExists")
      XCTAssertEqual(invoke(calls, "end", ["id": id, "reason": "remoteEnded"]) as? Bool, true)
    }
  }

  /// CallKit ends a ringing call by itself on the Simulator (callservicesd:
  /// "Disconnecting call because there wont be a UI to host the call"),
  /// about a second after the report. It arrives as an ordinary
  /// `CXEndCallAction` the app didn't request, as the user's Decline does:
  /// CallKit's API doesn't say who asked, so the package can't tell them
  /// apart and reports `declined` (docs/design.md §4.8, Who ended a ringing
  /// call). This records that limit.
  func testCallKitEndingARingingCallItselfIsDeclinedOnSimulator() throws {
    let calls = make()
    XCTAssertEqual(invoke(calls, "configure", config) as? Bool, true)
    var received: [[String: Any]] = []
    let owner = NSObject()
    calls.events.listen(owner) { received.append($0 as! [String: Any]) }
    defer { calls.events.cancel(owner) }
    try reportRinging(calls)
    let deadline = Date().addingTimeInterval(5)
    while !calls.registry.isEmpty && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard calls.registry.isEmpty else {
      _ = invoke(calls, "end", ["id": id, "reason": "failed"])
      throw XCTSkip("CallKit kept the ringing call here (it has a UI to host it)")
    }
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first?["event"] as? String, "ended")
    XCTAssertEqual(received.first?["id"] as? String, id)
    XCTAssertEqual(received.first?["reason"] as? String, "declined")
  }

  private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertTrue(condition(), "timed out")
  }
}

/// A binary messenger that keeps the handlers set on it and what is sent,
/// standing in for an engine's (plugin registration without an engine).
private final class RecordingMessenger: NSObject, FlutterBinaryMessenger {
  var handlers: [String: FlutterBinaryMessageHandler] = [:]
  var sent: [(channel: String, message: Data?)] = []

  func send(onChannel channel: String, message: Data?) {
    sent.append((channel, message))
  }

  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?)
  {
    sent.append((channel, message))
    callback?(nil)
  }

  func setMessageHandlerOnChannel(
    _ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?
  ) -> FlutterBinaryMessengerConnection {
    handlers[channel] = handler
    return FlutterBinaryMessengerConnection(handlers.count)
  }

  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}

/// The launch hook (`CloudflareRealtimePlugin.handleLaunch()`, docs/design.md
/// §4.8, Launch): the provider and the PushKit registry exist from
/// `didFinishLaunching`, before any engine registers the plugin. On a
/// private UserDefaults suite, as the handler tests.
final class LaunchHookTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!
  private var made: [SystemCalls] = []
  private let eventsChannel = "dev.kammcs.cloudflare_realtime/system_calls_events"

  override func setUp() {
    super.setUp()
    suite = "LaunchHookTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    for calls in made {
      calls.provider?.invalidate()
      calls.pushRegistry?.desiredPushTypes = []
    }
    made = []
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  private func make() -> SystemCalls {
    let calls = SystemCalls(defaults: defaults, audio: nil)
    made.append(calls)
    return calls
  }

  /// What an earlier launch left: `configure` and `VoipPush.register()`.
  private func persist(config: Bool = true, voip: Bool = true) {
    if config {
      defaults.set(["supportsVideo": true, "maximumCalls": 1], forKey: SystemCalls.configKey)
    }
    if voip { defaults.set(true, forKey: SystemCalls.voipKey) }
  }

  func testLaunchRestoresBeforeAnyEngine() {
    persist()
    let calls = make()
    XCTAssertNil(calls.provider)
    XCTAssertNil(calls.pushRegistry)
    CloudflareRealtimePlugin.launch(calls)
    XCTAssertNotNil(calls.provider)
    XCTAssertEqual(calls.provider?.configuration.maximumCallsPerCallGroup, 1)
    XCTAssertNotNil(calls.pushRegistry)
    XCTAssertEqual(calls.pushRegistry?.desiredPushTypes, [.voIP])
  }

  func testLaunchTwiceThenRegistrationCreatesOneOfEach() throws {
    persist()
    let calls = make()
    CloudflareRealtimePlugin.launch(calls)
    let provider = try XCTUnwrap(calls.provider)
    let registry = try XCTUnwrap(calls.pushRegistry)
    CloudflareRealtimePlugin.launch(calls)
    // Two engines register the plugin later.
    CloudflareRealtimePlugin.registerSystemCalls(calls, messenger: RecordingMessenger())
    CloudflareRealtimePlugin.registerSystemCalls(calls, messenger: RecordingMessenger())
    XCTAssertTrue(calls.provider === provider)
    XCTAssertTrue(calls.pushRegistry === registry)
  }

  func testLaunchWithoutPersistedStateDoesNothing() {
    let calls = make()
    CloudflareRealtimePlugin.launch(calls)
    XCTAssertNil(calls.provider)
    XCTAssertNil(calls.pushRegistry)
    CloudflareRealtimePlugin.registerSystemCalls(calls, messenger: RecordingMessenger())
    XCTAssertNil(calls.provider, "registration doesn't configure either")
    XCTAssertNil(calls.pushRegistry)
  }

  /// Registered for pushes, never configured: the registry, and the
  /// provider only with the first push (the defaults).
  func testOptInWithoutConfiguration() {
    persist(config: false)
    let calls = make()
    CloudflareRealtimePlugin.launch(calls)
    XCTAssertNil(calls.provider)
    XCTAssertNotNil(calls.pushRegistry)
  }

  /// A push handled at launch, before any engine: its events wait for
  /// the first engine that registers the plugin and listens.
  func testPushBeforeAnyEngineReachesTheFirstEngine() throws {
    persist()
    let calls = make()
    CloudflareRealtimePlugin.launch(calls)
    let id = UUID().uuidString.lowercased()
    let done = expectation(description: "push completion")
    calls.reportPush(["id": id, "handle": "ada", "room": "r1"]) { done.fulfill() }
    wait(for: [done], timeout: 10)
    XCTAssertEqual(calls.events.buffer.first?["event"] as? String, "reported")

    let messenger = RecordingMessenger()
    CloudflareRealtimePlugin.registerSystemCalls(calls, messenger: messenger)
    let codec = FlutterStandardMethodCodec.sharedInstance()
    let listen = try XCTUnwrap(messenger.handlers[eventsChannel])
    listen(codec.encode(FlutterMethodCall(methodName: "listen", arguments: nil))) { _ in }
    let events = messenger.sent.filter { $0.channel == eventsChannel }.compactMap {
      $0.message.flatMap { codec.decodeEnvelope($0) as? [String: Any] }
    }
    XCTAssertEqual(events.first?["event"] as? String, "reported")
    XCTAssertEqual((events.first?["call"] as? [String: Any])?["id"] as? String, id)
    XCTAssertTrue(calls.events.buffer.isEmpty, "delivered, not kept")
    listen(codec.encode(FlutterMethodCall(methodName: "cancel", arguments: nil))) { _ in }
    if !calls.registry.isEmpty {
      let end = FlutterMethodCall(methodName: "end", arguments: ["id": id, "reason": "failed"])
      calls.handle(end, result: { _ in })
    }
  }

  /// The public hook on the process's `SystemCalls`: the example's
  /// AppDelegate already called it, and plugin registration followed, so
  /// calling it again changes nothing, from any thread.
  func testHandleLaunchIsIdempotentOnTheSharedInstance() {
    let shared = SystemCalls.shared
    let provider = shared.provider
    let registry = shared.pushRegistry
    CloudflareRealtimePlugin.handleLaunch()
    let done = expectation(description: "from another thread")
    DispatchQueue.global().async {
      CloudflareRealtimePlugin.handleLaunch()
      // Queued after the hook's own block on the main queue.
      DispatchQueue.main.async { done.fulfill() }
    }
    wait(for: [done], timeout: 10)
    XCTAssertTrue(shared.provider === provider)
    XCTAssertTrue(shared.pushRegistry === registry)
  }
}

/// An `RTCAudioSession` delegate that records the interruptions WebRTC's
/// audio device module is told about.
private final class InterruptionRecorder: NSObject {
  var events: [String] = []

  @objc(audioSessionDidBeginInterruption:)
  func didBegin(_ session: NSObject) { events.append("began") }

  @objc(audioSessionDidEndInterruption:shouldResumeSession:)
  func didEnd(_ session: NSObject, shouldResumeSession: Bool) {
    events.append(shouldResumeSession ? "ended(resume)" : "ended")
  }
}

/// WebRTC's `RTCAudioSession`, reached through the Objective-C runtime in
/// the app (flutter_webrtc links WebRTC).
final class SystemCallAudioTests: XCTestCase {
  // CallKit deactivating the session (a hold) stops the app's audio I/O
  // without an AVAudioSession interruption; WebRTC's AVAudioEngine module
  // restarts its engine only when an interruption ends. So didDeactivate
  // begins one, and didActivate (audioSessionDidActivate:) ends it.
  func testDeactivationBeginsAnInterruptionThatActivationEnds() throws {
    let audio = SystemCallAudio.shared
    let session = try XCTUnwrap(
      (NSClassFromString("RTCAudioSession") as? NSObject.Type)?
        .perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject)
    guard audio.isAvailable,
      session.responds(to: NSSelectorFromString("notifyDidBeginInterruption"))
    else {
      throw XCTSkip("WebRTC's RTCAudioSession (with its private selectors) isn't loaded here")
    }
    let recorder = InterruptionRecorder()
    session.perform(NSSelectorFromString("addDelegate:"), with: recorder)
    defer {
      session.perform(NSSelectorFromString("removeDelegate:"), with: recorder)
      session.setValue(false, forKey: "isInterrupted")
    }
    let avSession = AVAudioSession.sharedInstance()
    XCTAssertFalse(audio.isInterrupted)

    audio.didActivate(avSession)  // CallKit activated the call's audio.
    XCTAssertEqual(recorder.events, ["ended(resume)"])
    audio.didDeactivate(avSession)  // A hold.
    XCTAssertTrue(audio.isInterrupted)
    XCTAssertEqual(session.value(forKey: "isActive") as? Bool, false)
    XCTAssertEqual(recorder.events, ["ended(resume)", "began"])
    audio.didDeactivate(avSession)  // Already interrupted: not begun twice.
    XCTAssertEqual(recorder.events, ["ended(resume)", "began"])
    audio.didActivate(avSession)  // The unhold.
    XCTAssertFalse(audio.isInterrupted)
    XCTAssertEqual(session.value(forKey: "isActive") as? Bool, true)
    XCTAssertEqual(recorder.events, ["ended(resume)", "began", "ended(resume)"])
    audio.didDeactivate(avSession)
    audio.didActivate(avSession)
    XCTAssertEqual(
      recorder.events, ["ended(resume)", "began", "ended(resume)", "began", "ended(resume)"],
      "every hold restarts the audio")
    // Three activations and three deactivations: the count is balanced.
  }

  // A real interruption WebRTC already handled isn't begun again.
  func testDeactivationDuringARealInterruptionDoesNotBeginAnother() throws {
    let audio = SystemCallAudio.shared
    let session = try XCTUnwrap(
      (NSClassFromString("RTCAudioSession") as? NSObject.Type)?
        .perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject)
    guard audio.isAvailable,
      session.responds(to: NSSelectorFromString("notifyDidBeginInterruption"))
    else {
      throw XCTSkip("WebRTC's RTCAudioSession (with its private selectors) isn't loaded here")
    }
    let recorder = InterruptionRecorder()
    session.perform(NSSelectorFromString("addDelegate:"), with: recorder)
    defer {
      session.perform(NSSelectorFromString("removeDelegate:"), with: recorder)
      session.setValue(false, forKey: "isInterrupted")
    }
    let avSession = AVAudioSession.sharedInstance()
    audio.didActivate(avSession)
    session.setValue(true, forKey: "isInterrupted")  // iOS posted one.
    audio.didDeactivate(avSession)
    XCTAssertEqual(recorder.events, ["ended(resume)"])
    audio.didActivate(avSession)
    XCTAssertFalse(audio.isInterrupted)
    XCTAssertEqual(recorder.events, ["ended(resume)", "ended(resume)"])
    session.perform(NSSelectorFromString("audioSessionDidDeactivate:"), with: avSession)
  }

  func testRTCAudioSessionHandOff() throws {
    let audio = SystemCallAudio.shared
    guard audio.isAvailable else {
      throw XCTSkip("WebRTC's RTCAudioSession isn't loaded in this host")
    }
    let before = audio.useManualAudio
    audio.enableManualAudio()
    XCTAssertTrue(audio.useManualAudio)

    audio.update(hasCalls: true, activated: false)
    XCTAssertFalse(audio.isAudioEnabled, "from a report until didActivate")
    XCTAssertTrue(audio.callKitOwnsSession)
    audio.update(hasCalls: true, activated: true)
    XCTAssertTrue(audio.isAudioEnabled)
    audio.update(hasCalls: true, activated: false)
    XCTAssertFalse(audio.isAudioEnabled, "after didDeactivate")
    audio.update(hasCalls: false, activated: false)
    XCTAssertTrue(audio.isAudioEnabled, "no CallKit call")
    XCTAssertFalse(audio.callKitOwnsSession)

    // The category is configurable before activation, without errors.
    audio.configureCategory(video: false)
    XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)

    let session = try XCTUnwrap(
      (NSClassFromString("RTCAudioSession") as? NSObject.Type)?
        .perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject)
    session.setValue(before, forKey: "useManualAudio")
  }

  func testDeactivationGuardSkipsWhileCallKitOwnsTheSession() throws {
    let audio = SystemCallAudio.shared
    guard let utils = NSClassFromString("AudioUtils") as? NSObject.Type else {
      throw XCTSkip("flutter_webrtc's AudioUtils isn't in this host")
    }
    audio.enableManualAudio()
    let session = try XCTUnwrap(
      (NSClassFromString("RTCAudioSession") as? NSObject.Type)?
        .perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject)
    let count = { (session.value(forKey: "activationCount") as? NSNumber)?.intValue ?? -1 }
    // A session WebRTC believes is active (CallKit activated it).
    session.perform(NSSelectorFromString("audioSessionDidActivate:"), with: AVAudioSession.sharedInstance())
    let activated = count()
    audio.update(hasCalls: true, activated: true)
    utils.perform(NSSelectorFromString("deactiveRtcAudioSession"))
    XCTAssertEqual(count(), activated, "skipped while a CallKit call exists")
    XCTAssertEqual(session.value(forKey: "isActive") as? Bool, true)

    audio.update(hasCalls: false, activated: false)
    session.perform(
      NSSelectorFromString("audioSessionDidDeactivate:"), with: AVAudioSession.sharedInstance())
  }
}

/// The call audio channel's `AVAudioSession` interruptions (§4.7), and
/// CallKit's ownership of them (§4.8).
final class AudioInterruptionEventTests: XCTestCase {
  private func info(_ type: AVAudioSession.InterruptionType) -> [AnyHashable: Any] {
    [AVAudioSessionInterruptionTypeKey: type.rawValue]
  }

  func testForwardedWithoutACallKitCall() {
    let began = CloudflareRealtimePlugin.interruptionEvent(info(.began), callKitOwnsSession: false)
    XCTAssertEqual(began?["event"] as? String, "interruption")
    XCTAssertEqual(began?["type"] as? String, "began")
    XCTAssertEqual(began?["reason"] as? String, "unknown")
    let ended = CloudflareRealtimePlugin.interruptionEvent(info(.ended), callKitOwnsSession: false)
    XCTAssertEqual(ended?["type"] as? String, "ended")
    XCTAssertNil(CloudflareRealtimePlugin.interruptionEvent([:], callKitOwnsSession: false))
  }

  // While a CallKit call exists its hold and its audio deactivation are the
  // interruptions; a notification iOS posts for them (even one arriving
  // after the unhold) doesn't reach Dart.
  func testLeftToCallKitWhileACallExists() {
    XCTAssertNil(CloudflareRealtimePlugin.interruptionEvent(info(.began), callKitOwnsSession: true))
    XCTAssertNil(CloudflareRealtimePlugin.interruptionEvent(info(.ended), callKitOwnsSession: true))
  }
}
