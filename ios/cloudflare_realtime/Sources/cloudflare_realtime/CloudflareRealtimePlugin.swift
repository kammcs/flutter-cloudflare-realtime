import AVFoundation
import Flutter
import UIKit

/// The package's iOS plugin: call audio routing (docs/design.md §4.6),
/// interruptions, the proximity sensor and keeping the screen on (§4.7),
/// here; the camera paused
/// by the system (`CallBackground`, §4.7); system calls with CallKit and
/// PushKit (`SystemCalls`, §4.8), with `handleLaunch()` for the app's
/// launch; and the screen share's Broadcast Upload Extension support
/// (`ScreenBroadcast`, §10).
///
/// Call audio routing:
///
/// Thin by design: it lists the routes, reports the current one and its
/// changes, and selects one. Which route to pick is decided in Dart, and
/// the session's base configuration (voice or video chat) is set through
/// flutter_webrtc, which keeps managing the session here.
///
/// iOS has no general output setter. The speaker is an override; the
/// receiver, wired and Bluetooth hands-free routes are reached by choosing
/// their input, and the output follows. Stereo-only Bluetooth and AirPlay
/// can only be chosen in Apple's route picker: they are listed while they
/// are the current route, but can't be selected here.
///
/// Interruptions: `AVAudioSession.interruptionNotification` is forwarded as
/// `{event: interruption, type: began|ended, reason: unknown}` (iOS doesn't
/// say what interrupted), except while a CallKit call exists (§4.8: the
/// call's hold and audio deactivation are its interruptions then). WebRTC's
/// `RTCAudioSession` re-activates the session itself after an interruption
/// (and when the app becomes active during one); `resume` does the same,
/// for Dart's policy.
public class CloudflareRealtimePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  private let broadcast = ScreenBroadcast()
  private let background = CallBackground()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = CloudflareRealtimePlugin()
    let broadcast = instance.broadcast
    FlutterMethodChannel(
      name: "dev.kammcs.cloudflare_realtime/screen_broadcast",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in broadcast.handle(call, result: result) }
    FlutterEventChannel(
      name: "dev.kammcs.cloudflare_realtime/screen_broadcast_events",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(broadcast)
    let background = instance.background
    FlutterMethodChannel(
      name: "dev.kammcs.cloudflare_realtime/call_background",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in background.handle(call, result: result) }
    FlutterEventChannel(
      name: "dev.kammcs.cloudflare_realtime/call_background_events",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(background)
    // One for the process: every engine shares the calls and their events.
    registerSystemCalls(SystemCalls.shared, messenger: registrar.messenger())
    let methods = FlutterMethodChannel(
      name: "dev.kammcs.cloudflare_realtime/call_audio",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "dev.kammcs.cloudflare_realtime/call_audio_events",
      binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    // So the engine calls detachFromEngine(for:) (the screen's hold).
    registrar.publish(instance)
  }

  /// System calls' channels on one engine's [messenger]. [systemCalls] is
  /// restored first (nothing to do when `handleLaunch()` already did it).
  static func registerSystemCalls(
    _ systemCalls: SystemCalls, messenger: FlutterBinaryMessenger
  ) {
    systemCalls.restore()
    FlutterMethodChannel(
      name: "dev.kammcs.cloudflare_realtime/system_calls",
      binaryMessenger: messenger
    ).setMethodCallHandler { call, result in systemCalls.handle(call, result: result) }
    FlutterEventChannel(
      name: "dev.kammcs.cloudflare_realtime/system_calls_events",
      binaryMessenger: messenger
    ).setStreamHandler(SystemCallEventStream(systemCalls.events))
  }

  // MARK: Launch

  /// Restores system calls at app launch: the CallKit provider from the
  /// last `SystemCalls.configure()`, and the PushKit registry if the app
  /// registered for VoIP pushes (`VoipPush.register()`). Call it from
  /// `application(_:didFinishLaunchingWithOptions:)`:
  ///
  /// ```swift
  /// import cloudflare_realtime
  ///
  /// CloudflareRealtimePlugin.handleLaunch()
  /// ```
  ///
  /// Apple asks for the PushKit registry to exist by the end of
  /// `didFinishLaunching`: a VoIP push that launched the app must be
  /// reported to CallKit, or iOS terminates the app and, after repeated
  /// failures, stops delivering its VoIP pushes. Plugin registration
  /// restores them too, but a Flutter engine may register its plugins
  /// later (a UIScene app's implicit engine, an engine started on demand,
  /// add-to-app). Without this call they are restored when the first
  /// engine registers the plugin, as before.
  ///
  /// Safe to call more than once, and before any Flutter engine exists:
  /// what a push raises meanwhile waits for Dart to listen. Meant for the
  /// main thread; from another thread it runs on the main queue, later.
  /// Does nothing until the app has configured system calls or registered
  /// for VoIP pushes once (docs/design.md §4.8, Launch).
  @objc public static func handleLaunch() {
    if Thread.isMainThread {
      launch(SystemCalls.shared)
    } else {
      DispatchQueue.main.async { launch(SystemCalls.shared) }
    }
  }

  /// `handleLaunch()` on [systemCalls] (for tests).
  static func launch(_ systemCalls: SystemCalls) {
    systemCalls.restore()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "activate", "deactivate":
      // flutter_webrtc activates the session when audio starts.
      result(nil)
    case "routes":
      result(routes().map { $0.map })
    case "current":
      result(current()?.map)
    case "select":
      let id = (call.arguments as? [String: Any])?["id"] as? String ?? ""
      result(select(id))
    case "resume":
      result(resume())
    case "proximity":
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      // No-op on devices without the sensor (iPads): it reads back false.
      UIDevice.current.isProximityMonitoringEnabled = enabled
      result(UIDevice.current.isProximityMonitoringEnabled)
    case "keepScreenOn":
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      setKeepScreenOn(enabled)
      result(enabled)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Keeping the screen on

  // Engines holding the idle timer off, process-wide (each engine's Dart
  // side already counts its own rooms), and the value to restore.
  private static var screenHolders = 0
  private static var savedIdleTimerDisabled = false
  private var holdsScreen = false

  /// Keeps the screen on (no dimming, no auto-lock) while [enabled], with
  /// `UIApplication.isIdleTimerDisabled`; the value from before the first
  /// holder is restored when the last one lets go, so an app's own setting
  /// survives. Dart decides when (a call with live video, §4.7); the
  /// proximity sensor still turns the screen off near the ear.
  private func setKeepScreenOn(_ enabled: Bool) {
    guard enabled != holdsScreen else { return }
    holdsScreen = enabled
    let app = UIApplication.shared
    if enabled {
      if Self.screenHolders == 0 { Self.savedIdleTimerDisabled = app.isIdleTimerDisabled }
      Self.screenHolders += 1
      app.isIdleTimerDisabled = true
    } else {
      Self.screenHolders -= 1
      if Self.screenHolders == 0 { app.isIdleTimerDisabled = Self.savedIdleTimerDisabled }
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    setKeepScreenOn(false)
  }

  // MARK: Routes

  private struct Route {
    let id: String
    let kind: String
    let name: String
    var map: [String: String] { ["id": id, "kind": kind, "name": name] }
  }

  private static let speaker = Route(id: "speaker", kind: "speaker", name: "")
  private static let receiver = Route(id: "receiver", kind: "earpiece", name: "")

  private func kind(of port: AVAudioSession.Port) -> String? {
    switch port {
    case .builtInSpeaker: return "speaker"
    case .builtInReceiver: return "earpiece"
    case .headsetMic, .headphones: return "wiredHeadset"
    case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return "bluetooth"
    case .usbAudio: return "usb"
    case .airPlay, .carAudio, .HDMI: return "other"
    default: return nil
    }
  }

  private var session: AVAudioSession { AVAudioSession.sharedInstance() }

  private func routes() -> [Route] {
    let inputs = session.availableInputs ?? []
    let outputs = session.currentRoute.outputs
    let wired =
      inputs.contains { $0.portType == .headsetMic }
      || outputs.contains { $0.portType == .headphones }
    var list = [Self.speaker]
    if !wired { list.append(Self.receiver) }
    // Wired, Bluetooth hands-free and USB routes, chosen through their input.
    for port in inputs {
      guard port.portType != .builtInMic, let kind = kind(of: port.portType) else { continue }
      list.append(Route(id: port.uid, kind: kind, name: port.portName))
    }
    // The current output when it has no input of its own (stereo Bluetooth,
    // AirPlay, headphones without a mic).
    for port in outputs {
      guard let kind = kind(of: port.portType), kind != "speaker", kind != "earpiece" else {
        continue
      }
      if !list.contains(where: { $0.kind == kind && $0.name == port.portName }) {
        list.append(Route(id: port.uid, kind: kind, name: port.portName))
      }
    }
    return list
  }

  private func current() -> Route? {
    guard let output = session.currentRoute.outputs.first,
      let kind = kind(of: output.portType)
    else { return nil }
    if kind == "speaker" { return Self.speaker }
    if kind == "earpiece" { return Self.receiver }
    let all = routes()
    return all.first { $0.id == output.uid }
      ?? all.first { $0.kind == kind && $0.name == output.portName }
      ?? Route(id: output.uid, kind: kind, name: output.portName)
  }

  private func select(_ id: String) -> Bool {
    do {
      switch id {
      case Self.speaker.id:
        try session.overrideOutputAudioPort(.speaker)
      case Self.receiver.id:
        try session.overrideOutputAudioPort(.none)
        let mic = session.availableInputs?.first { $0.portType == .builtInMic }
        try session.setPreferredInput(mic)
      default:
        if let port = session.availableInputs?.first(where: { $0.uid == id }) {
          try session.overrideOutputAudioPort(.none)
          try session.setPreferredInput(port)
        } else {
          // Only Apple's route picker can choose an output without an
          // input; it's fine if it already is the route.
          return session.currentRoute.outputs.contains { $0.uid == id }
        }
      }
      return true
    } catch {
      NSLog("cloudflare_realtime: selecting audio route %@ failed: %@", id, "\(error)")
      return false
    }
  }

  // MARK: Interruptions

  /// Activates the audio session again after an interruption. Fails while
  /// something with priority (a phone call) still holds the audio.
  ///
  /// Never while a CallKit call exists (§4.8): CallKit owns the session's
  /// activation then, and Dart takes the call off hold instead.
  private func resume() -> Bool {
    let systemCalls = SystemCalls.shared
    if systemCalls.ownsAudioSession { return systemCalls.audioActivated }
    do {
      try session.setActive(true)
      return true
    } catch {
      NSLog("cloudflare_realtime: resuming the audio session failed: %@", "\(error)")
      return false
    }
  }

  private func interruption(_ notification: Notification) {
    let event = Self.interruptionEvent(
      notification.userInfo, callKitOwnsSession: SystemCalls.shared.ownsAudioSession)
    if let event { sink?(event) }
  }

  /// The event for an `AVAudioSession` interruption, or `nil`.
  ///
  /// `nil` while a CallKit call exists (§4.8): CallKit owns the session
  /// then, and the call's interruptions are its hold and its audio
  /// deactivation (`SystemCalls`). A notification iOS posts for those (it
  /// can arrive late, after the unhold) must not interrupt the room again.
  static func interruptionEvent(_ userInfo: [AnyHashable: Any]?, callKitOwnsSession: Bool)
    -> [String: Any]?
  {
    guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return nil }
    if callKitOwnsSession {
      NSLog(
        "cloudflare_realtime: audio session interruption (%@) left to CallKit",
        type == .began ? "began" : "ended")
      return nil
    }
    switch type {
    case .began:
      return ["event": "interruption", "type": "began", "reason": "unknown"]
    case .ended:
      return ["event": "interruption", "type": "ended"]
    @unknown default:
      return nil
    }
  }

  // MARK: Changes

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    // Posted on a secondary thread; the sink must be used on the main one.
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.sink?("changed")
      },
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] notification in
        self?.interruption(notification)
      },
    ]
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    sink = nil
    return nil
  }
}
