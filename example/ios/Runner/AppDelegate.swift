import Flutter
import UIKit
import cloudflare_realtime

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundTasks: ExampleBackgroundTasks?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // CallKit's provider and the PushKit registry from launch, before the
    // implicit engine registers the plugins (doc/ios.md, VoIP pushes).
    CloudflareRealtimePlugin.handleLaunch()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    backgroundTasks = ExampleBackgroundTasks(
      messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// The example's `example/background_task` channel (`beginBackgroundTask`
/// in lib/system_call_demo.dart): UIKit background tasks, so Dart keeps
/// running for a while after the app leaves the foreground.
///
/// The example's **Simulate incoming call** waits 5 s in Dart before
/// reporting the call, time to lock the phone. Once locked, iOS suspends the
/// app within a few seconds (no call exists yet, so neither the `audio` nor
/// the `voip` background mode keeps it running), and the call would only
/// ring after unlocking. A real app is woken by a VoIP push instead, which
/// reports its call natively (docs/design.md §4.8); this is the example's
/// stand-in. iOS grants a background task about 30 s. A call answered from
/// the lock screen also joins its room under one, until its microphone is
/// published (the call's audio keeps the app running from then on).
///
/// - `begin` `{name}` → the task's ID (an `int`), or `nil` if iOS refused.
/// - `end` `{id}`: ends it; ending one that already ended (or expired) is a
///   no-op.
///
/// A task that runs out of time is ended by its expiration handler, as iOS
/// requires (otherwise it kills the app).
final class ExampleBackgroundTasks {
  private let channel: FlutterMethodChannel
  private var tasks = Set<Int>()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "example/background_task", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "begin":
      let name = args["name"] as? String ?? "example"
      var id = UIBackgroundTaskIdentifier.invalid
      id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
        NSLog("example: background task \"%@\" expired", name)
        self?.end(id.rawValue)
      }
      if id == .invalid {
        result(nil)
      } else {
        tasks.insert(id.rawValue)
        result(id.rawValue)
      }
    case "end":
      if let id = args["id"] as? Int { end(id) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func end(_ id: Int) {
    guard tasks.remove(id) != nil else { return }
    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
  }
}
