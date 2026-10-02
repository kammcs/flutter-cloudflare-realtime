import AVFoundation
import Flutter

/// A call outside the foreground on iOS (docs/design.md §4.7).
///
/// iOS needs no service: a call keeps its audio in the background with the
/// app's `UIBackgroundModes: audio` and an active audio session. But the
/// system interrupts every camera capture session when the app goes to the
/// background (and in some multitasking and system-pressure cases). WebRTC's
/// camera capturer, which flutter_webrtc uses, restarts its session by
/// itself when the interruption ends or the app becomes active again; the
/// track stays live and simply sends no frames meanwhile, so nothing tells
/// the app. This reports it.
///
/// It observes `AVCaptureSession.wasInterruptedNotification` and
/// `interruptionEndedNotification` for every capture session in the
/// process (flutter_webrtc's own, which this package can't reach), and sends
/// `{event: cameraPaused, reason}` while any is interrupted and
/// `{event: cameraResumed}` once none is. `startService` and `stopService`
/// exist for Dart's shape: Android's foreground service has no iOS
/// counterpart.
final class CallBackground: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  private var interrupted = Set<ObjectIdentifier>()

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startService":
      result(false)
    case "stopService":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func reason(of notification: Notification) -> String {
    guard let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
      let reason = AVCaptureSession.InterruptionReason(rawValue: raw)
    else { return "other" }
    switch reason {
    case .videoDeviceNotAvailableInBackground: return "background"
    case .videoDeviceInUseByAnotherClient: return "inUseByAnotherApp"
    case .videoDeviceNotAvailableWithMultipleForegroundApps: return "multipleForegroundApps"
    case .videoDeviceNotAvailableDueToSystemPressure: return "systemPressure"
    default: return "other"
    }
  }

  private func paused(_ notification: Notification) {
    guard let session = notification.object as? AVCaptureSession else { return }
    interrupted.insert(ObjectIdentifier(session))
    sink?(["event": "cameraPaused", "reason": reason(of: notification)])
  }

  private func ended(_ notification: Notification) {
    guard let session = notification.object as? AVCaptureSession else { return }
    guard interrupted.remove(ObjectIdentifier(session)) != nil, interrupted.isEmpty else { return }
    sink?(["event": "cameraResumed"])
  }

  // A session stopped while interrupted (the camera unpublished in the
  // background) never posts the end.
  private func stopped(_ notification: Notification) {
    guard let session = notification.object as? AVCaptureSession, !session.isInterrupted else {
      return
    }
    guard interrupted.remove(ObjectIdentifier(session)) != nil, interrupted.isEmpty else { return }
    sink?(["event": "cameraResumed"])
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: .main
      ) { [weak self] in self?.paused($0) },
      center.addObserver(
        forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: .main
      ) { [weak self] in self?.ended($0) },
      center.addObserver(
        forName: AVCaptureSession.didStopRunningNotification, object: nil, queue: .main
      ) { [weak self] in self?.stopped($0) },
    ]
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    interrupted.removeAll()
    sink = nil
    return nil
  }
}
