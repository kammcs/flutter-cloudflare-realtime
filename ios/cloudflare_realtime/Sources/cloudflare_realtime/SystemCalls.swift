import AVFoundation
import CallKit
import Flutter
import PushKit
import UIKit

/// System calls on iOS: CallKit and PushKit (docs/design.md §4.8).
///
/// The native side of `SystemCallBackend`, over the channels in the
/// contract at the top of `lib/src/calls/system_call_backend.dart`. It
/// decides nothing: it reports the app's calls to CallKit, relays what
/// CallKit's UI does as events, hands call audio to CallKit, and reports
/// VoIP pushes natively.
///
/// - **One per process** (`shared`), like CallKit's provider: every engine's
///   method channel talks to it, and every listening engine gets every
///   event. Events raised while no engine listens are buffered.
/// - **Requests confirmed by events.** `answer`, `end`, `setHeld` and
///   `setMuted` request a `CXAction`; the event comes from the provider's
///   `perform`, whoever asked (the app or the system's UI), and only when
///   the call really changed.
/// - **Audio:** `SystemCallAudio` (WebRTC's manual audio, enabled from the
///   report until `didActivate`).
/// - **VoIP pushes** are reported to CallKit before the PushKit delegate's
///   completion runs, as iOS requires; a malformed push is reported and
///   ended at once as `failed`.
/// - **Persisted:** the last configuration (so the provider exists at
///   launch, before Dart) and the VoIP opt-in (so pushes are handled from
///   launch).
final class SystemCalls: NSObject {
  static let shared = SystemCalls(defaults: .standard, audio: .shared)

  static let configKey = "dev.kammcs.cloudflare_realtime.systemCalls.config"
  static let voipKey = "dev.kammcs.cloudflare_realtime.systemCalls.voipPush"

  let events = SystemCallEvents()
  private(set) var registry = SystemCallRegistry()
  private let defaults: UserDefaults
  private let audio: SystemCallAudio?
  private(set) var provider: CXProvider?
  private let controller = CXCallController()
  private var supportsHolding = true
  private var supportsDtmf = false
  private var pushRegistry: PKPushRegistry?
  /// Whether CallKit activated the audio session (between `didActivate`
  /// and `didDeactivate`).
  private(set) var audioActivated = false
  /// End reasons the app asked for, until the end action is performed.
  private var endReasons: [UUID: SystemCallEndReason] = [:]

  /// `audio` is `nil` in tests that must not touch WebRTC's session.
  init(defaults: UserDefaults, audio: SystemCallAudio?) {
    self.defaults = defaults
    self.audio = audio
    super.init()
  }

  /// At plugin registration: restores the provider and the VoIP registry
  /// from the last launch, so a push that launched the app is handled
  /// before Dart runs.
  func restore() {
    if provider == nil, let config = defaults.dictionary(forKey: Self.configKey) {
      configure(config)
    }
    if pushRegistry == nil, defaults.bool(forKey: Self.voipKey) {
      startVoipRegistry()
    }
  }

  // MARK: Methods

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "configure":
      result(configure(args))
      return
    case "reportIncomingCall":
      reportIncomingCall(call.arguments, result: result)
      return
    case "startOutgoingCall":
      startOutgoingCall(call.arguments, result: result)
      return
    case "activeCalls":
      result(registry.calls.map { $0.map })
      return
    case "registerVoipPush":
      defaults.set(true, forKey: Self.voipKey)
      startVoipRegistry()
      result(pushRegistry?.pushToken(for: .voIP).map(Self.hex))
      return
    case "unregisterVoipPush":
      defaults.removeObject(forKey: Self.voipKey)
      pushRegistry?.desiredPushTypes = []
      result(nil)
      return
    default:
      break
    }
    // The rest act on one call.
    let known = [
      "reportConnecting", "reportConnected", "answer", "end", "setHeld", "setMuted", "update",
      "endpoints", "selectEndpoint",
    ]
    guard known.contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let id = args["id"] as? String, let uuid = UUID(uuidString: id) else {
      result(SystemCallError.failed.flutterError("\(call.method): no call id"))
      return
    }
    switch call.method {
    case "endpoints":
      // iOS has no call endpoints: call audio uses the platform's routes.
      result(nil)
      return
    case "selectEndpoint":
      result(false)
      return
    default:
      break
    }
    guard let record = registry[uuid] else {
      result(SystemCallError.notFound.flutterError("No call \(id)."))
      return
    }
    guard let provider else {
      result(SystemCallError.unavailable.flutterError("System calls aren't configured."))
      return
    }
    switch call.method {
    case "reportConnecting":
      provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
      registry.update(uuid) { if $0.state == .dialing { $0.state = .connecting } }
      result(nil)
    case "reportConnected":
      provider.reportOutgoingCall(with: uuid, connectedAt: nil)
      registry.update(uuid) {
        if $0.state == .dialing || $0.state == .connecting { $0.state = .active }
      }
      result(nil)
    case "answer":
      guard !record.outgoing, record.state == .ringing else {
        result(false)
        return
      }
      request(CXAnswerCallAction(call: uuid), result: result)
    case "end":
      let reason =
        (args["reason"] as? String).flatMap(SystemCallEndReason.init(rawValue:)) ?? .local
      end(record, reason: reason, result: result)
    case "setHeld":
      let onHold = args["onHold"] as? Bool ?? false
      if onHold == (record.state == .held) {
        result(true)  // Nothing to change: no event.
      } else if record.state == .ringing || record.state == .dialing {
        result(false)
      } else {
        request(CXSetHeldCallAction(call: uuid, onHold: onHold), result: result)
      }
    case "setMuted":
      let muted = args["muted"] as? Bool ?? false
      if muted == record.muted {
        result(true)  // Nothing to change: no event.
      } else {
        request(CXSetMutedCallAction(call: uuid, muted: muted), result: result)
      }
    case "update":
      let update = callUpdate(record)
      if let name = args["displayName"] as? String {
        update.localizedCallerName = name
        registry.update(uuid) { $0.displayName = name }
      }
      if let video = args["video"] as? Bool {
        update.hasVideo = video
        registry.update(uuid) { $0.video = video }
      }
      provider.reportCall(with: uuid, updated: update)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Creates (or reconfigures) the provider from Dart's
  /// `SystemCallsOptions.toMap()`, persists it, and turns manual audio on.
  @discardableResult
  func configure(_ config: [String: Any]) -> Bool {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = config["supportsVideo"] as? Bool ?? true
    configuration.maximumCallsPerCallGroup = max(1, config["maximumCalls"] as? Int ?? 1)
    configuration.includesCallsInRecents = config["includesCallsInRecents"] as? Bool ?? true
    configuration.supportedHandleTypes = [.generic, .phoneNumber, .emailAddress]
    if let name = config["iconTemplateImageName"] as? String, let image = UIImage(named: name) {
      configuration.iconTemplateImageData = image.pngData()
    }
    if let sound = config["ringtoneSound"] as? String {
      configuration.ringtoneSound = sound
    }
    supportsHolding = config["supportsHolding"] as? Bool ?? true
    supportsDtmf = config["supportsDtmf"] as? Bool ?? false
    if let provider {
      provider.configuration = configuration
    } else {
      let provider = CXProvider(configuration: configuration)
      provider.setDelegate(self, queue: nil)
      self.provider = provider
    }
    // Only property-list values (Dart's nulls dropped).
    defaults.set(config.filter { !($0.value is NSNull) }, forKey: Self.configKey)
    audio?.enableManualAudio()
    updateAudio()
    return true
  }

  private func reportIncomingCall(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let call = SystemCallRecord.fromDart(arguments) else {
      result(SystemCallError.failed.flutterError("reportIncomingCall: malformed call"))
      return
    }
    guard let provider else {
      result(SystemCallError.unavailable.flutterError("System calls aren't configured."))
      return
    }
    guard registry.add(call) else {
      result(SystemCallError.alreadyExists.flutterError())
      return
    }
    updateAudio()
    provider.reportNewIncomingCall(with: call.uuid, update: callUpdate(call)) { [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error {
          self.registry.remove(call.uuid)
          self.updateAudio()
          result(SystemCallError.incoming(error).flutterError(error.localizedDescription))
        } else {
          result(nil)
        }
      }
    }
  }

  private func startOutgoingCall(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let call = SystemCallRecord.fromDart(arguments) else {
      result(SystemCallError.failed.flutterError("startOutgoingCall: malformed call"))
      return
    }
    guard provider != nil else {
      result(SystemCallError.unavailable.flutterError("System calls aren't configured."))
      return
    }
    guard registry.add(call) else {
      result(SystemCallError.alreadyExists.flutterError())
      return
    }
    updateAudio()
    let action = CXStartCallAction(call: call.uuid, handle: call.cxHandle)
    action.isVideo = call.video
    controller.request(CXTransaction(action: action)) { [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error {
          self.registry.remove(call.uuid)
          self.updateAudio()
          result(SystemCallError.request(error).flutterError(error.localizedDescription))
        } else {
          result(nil)
        }
      }
    }
  }

  private func end(
    _ call: SystemCallRecord, reason: SystemCallEndReason, result: @escaping FlutterResult
  ) {
    if let callKitReason = reason.callKitReason {
      // Ended elsewhere (the other side, a timeout, another device): told,
      // not asked, so there is no action to perform.
      provider?.reportCall(with: call.uuid, endedAt: nil, reason: callKitReason)
      ended(call.uuid, reason)
      result(true)
      return
    }
    endReasons[call.uuid] = reason
    controller.request(CXTransaction(action: CXEndCallAction(call: call.uuid))) {
      [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }
        guard let error else {
          result(true)
          return
        }
        self.endReasons[call.uuid] = nil
        if SystemCallError.request(error) == .notFound {
          // CallKit no longer has it: it is over here too, without an
          // event (Dart ends it when the request isn't accepted).
          self.registry.remove(call.uuid)
          self.updateAudio()
          result(false)
        } else {
          result(SystemCallError.request(error).flutterError(error.localizedDescription))
        }
      }
    }
  }

  private func request(_ action: CXCallAction, result: @escaping FlutterResult) {
    controller.request(CXTransaction(action: action)) { error in
      DispatchQueue.main.async {
        if let error {
          NSLog(
            "cloudflare_realtime: CallKit refused %@: %@", "\(type(of: action))",
            error.localizedDescription)
        }
        result(error == nil)
      }
    }
  }

  private func callUpdate(_ call: SystemCallRecord) -> CXCallUpdate {
    let update = CXCallUpdate()
    update.remoteHandle = call.cxHandle
    update.localizedCallerName = call.displayName
    update.hasVideo = call.video
    update.supportsHolding = supportsHolding
    update.supportsDTMF = supportsDtmf
    update.supportsGrouping = false
    update.supportsUngrouping = false
    return update
  }

  private func ended(_ uuid: UUID, _ reason: SystemCallEndReason) {
    endReasons[uuid] = nil
    guard registry.remove(uuid) != nil else { return }
    updateAudio()
    events.send(["event": "ended", "id": uuid.uuidString.lowercased(), "reason": reason.rawValue])
  }

  private func updateAudio() {
    if registry.isEmpty { audioActivated = false }
    audio?.update(hasCalls: !registry.isEmpty, activated: audioActivated)
  }

  /// Whether CallKit owns the audio session's activation now (a CallKit
  /// call exists): the app must not activate it itself.
  var ownsAudioSession: Bool { !registry.isEmpty }

  // MARK: VoIP pushes

  private func startVoipRegistry() {
    if pushRegistry == nil {
      let registry = PKPushRegistry(queue: .main)
      registry.delegate = self
      pushRegistry = registry
    }
    pushRegistry?.desiredPushTypes = [.voIP]
  }

  static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  /// Reports a VoIP push's call to CallKit, then runs [completion] (once
  /// CallKit has it, as iOS requires).
  func reportPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
    if provider == nil {
      // Pushes before any configuration: the defaults.
      configure(defaults.dictionary(forKey: Self.configKey) ?? [:])
    }
    guard let provider else {
      completion()
      return
    }
    let push = VoipPushCall(payload: payload)
    let call = push.call
    if push.malformed {
      NSLog("cloudflare_realtime: a VoIP push without a call (id, handle); ended as failed")
    } else if registry.contains(call.uuid) {
      // Already known (the app's signaling reported it first). iOS still
      // wants a report for the push; CallKit refuses the duplicate.
      provider.reportNewIncomingCall(with: call.uuid, update: callUpdate(call)) { _ in
        DispatchQueue.main.async { completion() }
      }
      return
    } else {
      registry.add(call)
      updateAudio()
      events.send(["event": "reported", "call": call.map])
    }
    provider.reportNewIncomingCall(with: call.uuid, update: callUpdate(call)) {
      [weak self] error in
      DispatchQueue.main.async {
        defer { completion() }
        guard let self else { return }
        if push.malformed {
          if error == nil {
            provider.reportCall(with: call.uuid, endedAt: nil, reason: .failed)
          }
        } else if let error {
          NSLog(
            "cloudflare_realtime: CallKit refused a pushed call: %@", error.localizedDescription)
          self.ended(call.uuid, .failed)
        }
      }
    }
  }
}

// MARK: - CXProviderDelegate

extension SystemCalls: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    // CallKit dropped every call (its daemon restarted).
    for call in registry.calls {
      ended(call.uuid, .failed)
    }
    audioActivated = false
    updateAudio()
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    guard let call = registry[action.callUUID] else {
      action.fail()
      return
    }
    audio?.configureCategory(video: call.video)
    // The start action carries no name; the update does.
    provider.reportCall(with: call.uuid, updated: callUpdate(call))
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let call = registry[action.callUUID], registry.answer(action.callUUID) else {
      action.fail()
      return
    }
    audio?.configureCategory(video: call.video)
    events.send(["event": "answered", "id": call.id])
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    let uuid = action.callUUID
    if let call = registry[uuid] {
      let reason =
        endReasons[uuid] ?? (!call.outgoing && call.state == .ringing ? .declined : .local)
      ended(uuid, reason)
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    let uuid = action.callUUID
    guard registry.contains(uuid) else {
      action.fail()
      return
    }
    if registry.setHeld(uuid, action.isOnHold) {
      events.send(["event": "held", "id": uuid.uuidString.lowercased(), "onHold": action.isOnHold])
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    let uuid = action.callUUID
    guard registry.contains(uuid) else {
      action.fail()
      return
    }
    if registry.setMuted(uuid, action.isMuted) {
      events.send(["event": "muted", "id": uuid.uuidString.lowercased(), "muted": action.isMuted])
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    guard registry.contains(action.callUUID) else {
      action.fail()
      return
    }
    events.send([
      "event": "dtmf", "id": action.callUUID.uuidString.lowercased(), "digits": action.digits,
    ])
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
    // Group calls aren't supported (docs/design.md §4.8).
    action.fail()
  }

  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    NSLog("cloudflare_realtime: CallKit timed out performing %@", "\(type(of: action))")
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    audioActivated = true
    audio?.didActivate(audioSession)
    updateAudio()
    events.send(["event": "audioActivated"])
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    audioActivated = false
    audio?.didDeactivate(audioSession)
    updateAudio()
    events.send(["event": "audioDeactivated"])
  }
}

// MARK: - PKPushRegistryDelegate

extension SystemCalls: PKPushRegistryDelegate {
  func pushRegistry(
    _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType
  ) {
    guard type == .voIP else { return }
    events.send(["event": "voipToken", "token": Self.hex(pushCredentials.token)])
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    events.send(["event": "voipToken", "token": NSNull()])
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType, completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    reportPush(payload.dictionaryPayload, completion: completion)
  }
}
