import CallKit
import Flutter
import Foundation

// The plain parts of system calls on iOS (docs/design.md §4.8): the call
// records, the maps of the native contract (lib/src/calls/
// system_call_backend.dart), the VoIP push payload, and the event buffer.
// Nothing here talks to CallKit or PushKit, so RunnerTests covers it.

/// Where a call is, as the contract names it.
enum SystemCallState: String {
  case ringing, dialing, connecting, active, held, ended
}

/// Why a call ended, as the contract names it (`SystemCallEndReason`).
enum SystemCallEndReason: String, CaseIterable {
  case local, declined, remoteEnded, unanswered, failed, answeredElsewhere, declinedElsewhere

  /// The reason CallKit is told with `reportCall(with:endedAt:reason:)`, or
  /// `nil` for the reasons that end the call with a `CXEndCallAction`
  /// (ended on this device).
  var callKitReason: CXCallEndedReason? {
    switch self {
    case .local, .declined: return nil
    case .remoteEnded: return .remoteEnded
    case .unanswered: return .unanswered
    case .failed: return .failed
    case .answeredElsewhere: return .answeredElsewhere
    case .declinedElsewhere: return .declinedElsewhere
    }
  }
}

/// The error codes of the contract.
enum SystemCallError: String {
  case filtered, alreadyExists, notFound, unavailable, failed

  func flutterError(_ message: String? = nil) -> FlutterError {
    FlutterError(code: rawValue, message: message, details: nil)
  }

  /// The code for CallKit's error reporting an incoming call.
  static func incoming(_ error: Error) -> SystemCallError {
    let nsError = error as NSError
    guard nsError.domain == CXErrorDomainIncomingCall,
      let code = CXErrorCodeIncomingCallError.Code(rawValue: nsError.code)
    else { return .failed }
    switch code {
    case .filteredByDoNotDisturb, .filteredByBlockList: return .filtered
    case .callUUIDAlreadyExists: return .alreadyExists
    case .unentitled: return .unavailable
    case .unknown: return .failed
    default:
      // Newer codes (filtered during restricted sharing mode, iOS 17.4):
      // the system refused the call.
      return .filtered
    }
  }

  /// The code for CallKit's error requesting a transaction (an action the
  /// app asked for).
  static func request(_ error: Error) -> SystemCallError {
    let nsError = error as NSError
    guard nsError.domain == CXErrorDomainRequestTransaction,
      let code = CXErrorCodeRequestTransactionError.Code(rawValue: nsError.code)
    else { return .failed }
    switch code {
    case .unknownCallUUID: return .notFound
    case .callUUIDAlreadyExists: return .alreadyExists
    case .unentitled, .unknownCallProvider, .maximumCallGroupsReached: return .unavailable
    default: return .failed
    }
  }
}

/// One system call, as the package knows it.
struct SystemCallRecord: Equatable {
  let uuid: UUID
  var handle: String
  var handleType: String
  var displayName: String?
  var video: Bool
  let outgoing: Bool
  var state: SystemCallState
  var muted: Bool = false
  var payload: [String: Any] = [:]

  /// The contract's ID: the UUID, lowercase.
  var id: String { uuid.uuidString.lowercased() }

  var cxHandle: CXHandle { CXHandle(type: Self.cxHandleType(handleType), value: handle) }

  static let handleTypes = ["generic", "phoneNumber", "emailAddress"]

  static func cxHandleType(_ name: String) -> CXHandle.HandleType {
    switch name {
    case "phoneNumber": return .phoneNumber
    case "emailAddress": return .emailAddress
    default: return .generic
    }
  }

  /// The contract's call map.
  var map: [String: Any] {
    [
      "id": id,
      "handle": handle,
      "handleType": handleType,
      "displayName": displayName as Any? ?? NSNull(),
      "video": video,
      "outgoing": outgoing,
      "state": state.rawValue,
      "muted": muted,
      "payload": payload,
    ]
  }

  /// A call from Dart's call map (`reportIncomingCall`, `startOutgoingCall`),
  /// or `nil` when malformed.
  static func fromDart(_ arguments: Any?) -> SystemCallRecord? {
    guard let map = arguments as? [String: Any],
      let id = map["id"] as? String, let uuid = UUID(uuidString: id),
      let handle = map["handle"] as? String
    else { return nil }
    let outgoing = map["outgoing"] as? Bool ?? false
    return SystemCallRecord(
      uuid: uuid,
      handle: handle,
      handleType: handleTypes.contains(map["handleType"] as? String ?? "")
        ? map["handleType"] as! String : "generic",
      displayName: map["displayName"] as? String,
      video: map["video"] as? Bool ?? false,
      outgoing: outgoing,
      state: outgoing ? .dialing : .ringing)
  }

  static func ==(a: SystemCallRecord, b: SystemCallRecord) -> Bool {
    a.uuid == b.uuid && a.handle == b.handle && a.handleType == b.handleType
      && a.displayName == b.displayName && a.video == b.video && a.outgoing == b.outgoing
      && a.state == b.state && a.muted == b.muted
      && NSDictionary(dictionary: a.payload).isEqual(to: b.payload)
  }
}

/// A VoIP push's payload, read as a call (docs/design.md §4.8): the keys
/// `id` (a UUID), `handle`, and optionally `handleType`, `displayName` and
/// `video`; every other key except `aps` becomes the call's `payload`.
///
/// A push with the key `ended` is a **cancel**: it stops the call `id`
/// (the caller hung up, another device answered...), and needs no
/// `handle`. Its value is a `SystemCallEndReason` name that CallKit can be
/// told (`remoteEnded`, `unanswered`, `failed`, `answeredElsewhere`,
/// `declinedElsewhere`); anything else ends the call as `remoteEnded`.
struct VoipPushCall {
  /// The call to report. For a malformed payload, a placeholder (a new
  /// UUID, the handle "unknown") that is reported and ended at once.
  let call: SystemCallRecord
  /// Whether the payload lacked a call: the placeholder is ended as `failed`.
  /// Never for a cancel.
  let malformed: Bool
  /// For a cancel (the `ended` key), why the call ended; `nil` for a push
  /// that rings.
  let endReason: SystemCallEndReason?
  /// For a cancel, the `ended` value when it isn't a reason a push can
  /// carry (`endReason` is then `remoteEnded`).
  let unknownEndReason: Any?

  static let callKeys: Set<String> = [
    "id", "handle", "handleType", "displayName", "video", "ended",
  ]

  /// The reasons a cancel can carry: those CallKit is told (ended
  /// elsewhere), not `local` or `declined` (ended on this device).
  static func pushEndReason(_ value: Any?) -> SystemCallEndReason? {
    guard let name = value as? String, let reason = SystemCallEndReason(rawValue: name),
      reason.callKitReason != nil
    else { return nil }
    return reason
  }

  init(payload: [AnyHashable: Any]) {
    var rest: [String: Any] = [:]
    for (key, value) in payload {
      guard let key = key as? String, key != "aps", !Self.callKeys.contains(key) else { continue }
      rest[key] = value
    }
    let id = (payload["id"] as? String).flatMap(UUID.init(uuidString:))
    let handle = payload["handle"] as? String
    let handleType = payload["handleType"] as? String ?? "generic"
    let displayName = payload["displayName"] as? String
    if let ended = payload["ended"], !(ended is NSNull) {
      let known = Self.pushEndReason(ended)
      endReason = known ?? .remoteEnded
      unknownEndReason = known == nil ? ended : nil
    } else {
      endReason = nil
      unknownEndReason = nil
    }
    let validHandle = handle.flatMap { $0.isEmpty ? nil : $0 }
    malformed = endReason == nil && (id == nil || validHandle == nil)
    call = SystemCallRecord(
      uuid: id ?? UUID(),
      handle: malformed ? "unknown" : validHandle ?? "unknown",
      handleType: SystemCallRecord.handleTypes.contains(handleType) ? handleType : "generic",
      displayName: displayName,
      video: Self.bool(payload["video"]),
      outgoing: false,
      state: .ringing,
      payload: rest)
  }

  // JSON gives a Bool (an NSNumber); a server may also send "true" or 1.
  private static func bool(_ value: Any?) -> Bool {
    switch value {
    case let b as Bool: return b
    case let n as NSNumber: return n.boolValue
    case let s as String: return s == "true" || s == "1"
    default: return false
    }
  }
}

/// The calls that exist now, oldest first. Process-wide (one per app, as
/// CallKit's provider): every engine sees the same calls.
struct SystemCallRegistry {
  private(set) var calls: [SystemCallRecord] = []

  var isEmpty: Bool { calls.isEmpty }

  subscript(uuid: UUID) -> SystemCallRecord? {
    calls.first { $0.uuid == uuid }
  }

  func contains(_ uuid: UUID) -> Bool { self[uuid] != nil }

  /// Adds [call]; `false` when one with its UUID exists.
  @discardableResult
  mutating func add(_ call: SystemCallRecord) -> Bool {
    guard !contains(call.uuid) else { return false }
    calls.append(call)
    return true
  }

  @discardableResult
  mutating func remove(_ uuid: UUID) -> SystemCallRecord? {
    guard let index = calls.firstIndex(where: { $0.uuid == uuid }) else { return nil }
    return calls.remove(at: index)
  }

  mutating func removeAll() -> [SystemCallRecord] {
    defer { calls = [] }
    return calls
  }

  /// Changes the call [uuid]; the result is the call after the change, or
  /// `nil` without one.
  @discardableResult
  mutating func update(_ uuid: UUID, _ change: (inout SystemCallRecord) -> Void)
    -> SystemCallRecord?
  {
    guard let index = calls.firstIndex(where: { $0.uuid == uuid }) else { return nil }
    change(&calls[index])
    return calls[index]
  }

  /// Answers the ringing incoming call [uuid]: `true` when that is a change.
  mutating func answer(_ uuid: UUID) -> Bool {
    guard let call = self[uuid], !call.outgoing, call.state == .ringing else { return false }
    update(uuid) { $0.state = .active }
    return true
  }

  /// Puts the call [uuid] on hold or takes it off: `true` when that is a
  /// change. A ringing or dialing call can't be held.
  mutating func setHeld(_ uuid: UUID, _ onHold: Bool) -> Bool {
    guard let call = self[uuid] else { return false }
    if onHold {
      guard call.state == .active || call.state == .connecting else { return false }
      update(uuid) { $0.state = .held }
    } else {
      guard call.state == .held else { return false }
      update(uuid) { $0.state = .active }
    }
    return true
  }

  /// Mutes or unmutes the call [uuid]: `true` when that is a change.
  mutating func setMuted(_ uuid: UUID, _ muted: Bool) -> Bool {
    guard let call = self[uuid], call.muted != muted else { return false }
    update(uuid) { $0.muted = muted }
    return true
  }
}

/// The contract's events, sent to every listening engine, and buffered in
/// order while none listens.
final class SystemCallEvents {
  private var sinks: [ObjectIdentifier: FlutterEventSink] = [:]
  private(set) var buffer: [[String: Any]] = []
  /// Events kept while nobody listens; the oldest go first beyond it.
  static let bufferLimit = 256

  var isListened: Bool { !sinks.isEmpty }

  func send(_ event: [String: Any]) {
    if sinks.isEmpty {
      buffer.append(event)
      if buffer.count > Self.bufferLimit { buffer.removeFirst(buffer.count - Self.bufferLimit) }
      return
    }
    for sink in sinks.values { sink(event) }
  }

  func listen(_ owner: AnyObject, _ sink: @escaping FlutterEventSink) {
    sinks[ObjectIdentifier(owner)] = sink
    let pending = buffer
    buffer = []
    for event in pending { sink(event) }
  }

  func cancel(_ owner: AnyObject) {
    sinks[ObjectIdentifier(owner)] = nil
  }
}

/// One engine's end of the events channel.
final class SystemCallEventStream: NSObject, FlutterStreamHandler {
  private let events: SystemCallEvents

  init(_ events: SystemCallEvents) {
    self.events = events
  }

  func onListen(withArguments arguments: Any?, eventSink sink: @escaping FlutterEventSink)
    -> FlutterError?
  {
    events.listen(self, sink)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    events.cancel(self)
    return nil
  }
}
