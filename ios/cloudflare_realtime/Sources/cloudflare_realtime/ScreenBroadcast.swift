import Flutter
import Foundation

/// Screen share on iOS (docs/design.md §10): what `flutter_webrtc` leaves
/// to the app around its Broadcast Upload Extension capturer.
///
/// `flutter_webrtc` captures with `getDisplayMedia({video: {deviceId:
/// "broadcast"}})`: it listens on `<App Group container>/rtc_SSFD` for the
/// extension's frames and taps an `RPSystemBroadcastPickerView` for the
/// user. It doesn't say whether the app is set up for it, whether the user
/// started the broadcast, or when it stops. This class adds those:
///
/// - `status`: what's missing from the setup (`problems`, codes the Dart
///   side explains) and whether a broadcast is running (`broadcasting`).
/// - `prepare {frameRate, scale}`: the settings the extension reads from the
///   App Group's user defaults when the broadcast starts.
/// - `abandon`: removes the socket file after a share gave up waiting, so a
///   broadcast started late can't connect to a listener nobody reads.
///
/// Events (`{event: "started" | "finished"}`) forward the extension's
/// Darwin notifications, `<appGroup>.cloudflare_realtime.broadcast.<event>`,
/// which the package's extension template posts.
final class ScreenBroadcast: NSObject, FlutterStreamHandler {
  private static let appGroupKey = "RTCAppGroupIdentifier"
  private static let extensionKey = "RTCScreenSharingExtension"
  private static let socketName = "rtc_SSFD"
  private static let extensionPoint = "com.apple.broadcast-services-upload"
  private static let frameRateKey = "cloudflare_realtime.broadcast.frameRate"
  private static let scaleKey = "cloudflare_realtime.broadcast.scale"

  private let appGroup: String?
  private var sink: FlutterEventSink?
  private var observing = false
  private var broadcasting = false

  override init() {
    let group = Bundle.main.object(forInfoDictionaryKey: Self.appGroupKey) as? String
    appGroup = group?.isEmpty == false ? group : nil
    super.init()
    observe()
  }

  deinit {
    if observing {
      CFNotificationCenterRemoveEveryObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        Unmanaged.passUnretained(self).toOpaque())
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(["problems": problems(), "broadcasting": broadcasting])
    case "prepare":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let group = appGroup, let defaults = UserDefaults(suiteName: group) else {
        result(
          FlutterError(
            code: "screen_broadcast", message: "No RTCAppGroupIdentifier in Info.plist.",
            details: nil))
        return
      }
      defaults.set((args["frameRate"] as? NSNumber)?.intValue ?? 15, forKey: Self.frameRateKey)
      defaults.set((args["scale"] as? NSNumber)?.doubleValue ?? 0.5, forKey: Self.scaleKey)
      result(nil)
    case "abandon":
      if let socket = socketURL() {
        try? FileManager.default.removeItem(at: socket)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Setup check

  private func socketURL() -> URL? {
    guard let group = appGroup else { return nil }
    return FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: group)?
      .appendingPathComponent(Self.socketName)
  }

  /// What's missing, as codes (`BroadcastSetupProblem` in Dart).
  private func problems() -> [String] {
    var problems: [String] = []
    let wanted = Bundle.main.object(forInfoDictionaryKey: Self.extensionKey) as? String
    if appGroup == nil { problems.append("noAppGroupKey") }
    if wanted?.isEmpty ?? true { problems.append("noExtensionKey") }
    if let group = appGroup,
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) == nil
    {
      problems.append("appGroupUnavailable")
    }
    let extensions = broadcastExtensions()
    if extensions.isEmpty {
      problems.append("extensionMissing")
    } else if let wanted, !wanted.isEmpty {
      if let match = extensions.first(where: { $0.bundleIdentifier == wanted }) {
        let group = match.object(forInfoDictionaryKey: Self.appGroupKey) as? String
        if appGroup != nil && group != appGroup {
          problems.append("extensionAppGroupMismatch")
        }
      } else {
        problems.append("extensionIdMismatch")
      }
    }
    return problems
  }

  /// The app's embedded Broadcast Upload Extensions.
  private func broadcastExtensions() -> [Bundle] {
    guard let plugIns = Bundle.main.builtInPlugInsURL,
      let urls = try? FileManager.default.contentsOfDirectory(
        at: plugIns, includingPropertiesForKeys: nil)
    else { return [] }
    return urls.filter { $0.pathExtension == "appex" }.compactMap { url in
      guard let bundle = Bundle(url: url),
        let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
        ext["NSExtensionPointIdentifier"] as? String == Self.extensionPoint
      else { return nil }
      return bundle
    }
  }

  // MARK: Events

  private func observe() {
    guard let group = appGroup else { return }
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    for event in ["started", "finished"] {
      let name = "\(group).cloudflare_realtime.broadcast.\(event)" as CFString
      CFNotificationCenterAddObserver(
        center, observer,
        { _, observer, name, _, _ in
          guard let observer, let name else { return }
          let me = Unmanaged<ScreenBroadcast>.fromOpaque(observer).takeUnretainedValue()
          let event = (name.rawValue as String).components(separatedBy: ".").last ?? ""
          DispatchQueue.main.async { me.received(event) }
        }, name, nil, .deliverImmediately)
    }
    observing = true
  }

  private func received(_ event: String) {
    switch event {
    case "started": broadcasting = true
    case "finished": broadcasting = false
    default: return
    }
    NSLog("cloudflare_realtime: screen broadcast %@", event)
    sink?(["event": event])
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
