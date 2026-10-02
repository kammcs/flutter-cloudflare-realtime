import AVFoundation
import Flutter
import UIKit

/// The package's iOS plugin: call audio routing (docs/design.md §4.6),
/// interruptions and the proximity sensor (§4.7), here; the camera paused
/// by the system (`CallBackground`, §4.7); and the screen share's Broadcast
/// Upload Extension support (`ScreenBroadcast`, §10).
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
/// say what interrupted). WebRTC's `RTCAudioSession` re-activates the
/// session itself after an interruption (and when the app becomes active
/// during one); `resume` does the same, for Dart's policy.
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
    let methods = FlutterMethodChannel(
      name: "dev.kammcs.cloudflare_realtime/call_audio",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "dev.kammcs.cloudflare_realtime/call_audio_events",
      binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
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
    default:
      result(FlutterMethodNotImplemented)
    }
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
  private func resume() -> Bool {
    do {
      try session.setActive(true)
      return true
    } catch {
      NSLog("cloudflare_realtime: resuming the audio session failed: %@", "\(error)")
      return false
    }
  }

  private func interruption(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    switch type {
    case .began:
      sink?(["event": "interruption", "type": "began", "reason": "unknown"])
    case .ended:
      sink?(["event": "interruption", "type": "ended"])
    @unknown default:
      break
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
