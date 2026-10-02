// cloudflare_realtime: Broadcast Upload Extension template (MIT License).
//
// Copy this file and BroadcastUploader.swift into your app's Broadcast
// Upload Extension target. See "iOS screen share setup" in the package's
// README. Link only ReplayKit: an extension must never link Flutter.
//
// What it does: when the user starts the broadcast from the picker the app
// shows, it tells the app (Darwin notifications), connects to the socket
// flutter_webrtc listens on in the App Group container, and sends it the
// screen as JPEG frames at the frame rate and scale the app asked for.
// When the app stops sharing, it ends the broadcast with a short message.

import Foundation
import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {
  /// The Info.plist key that names the App Group (the same key and value as
  /// in the app's Info.plist).
  private static let appGroupKey = "RTCAppGroupIdentifier"

  /// The socket flutter_webrtc listens on, in the App Group container.
  private static let socketName = "rtc_SSFD"

  /// Set once, before the first sample buffer, and never cleared:
  /// ReplayKit calls this class from several threads, and a stopped
  /// uploader ignores further frames.
  private var uploader: BroadcastUploader?
  private var appGroup: String?

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    guard
      let group = Bundle.main.object(forInfoDictionaryKey: Self.appGroupKey) as? String,
      !group.isEmpty,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    else {
      end("Screen sharing isn't set up: the broadcast extension has no App Group.")
      return
    }
    appGroup = group
    let settings = UserDefaults(suiteName: group)
    let frameRate = settings?.integer(forKey: "cloudflare_realtime.broadcast.frameRate") ?? 0
    let scale = settings?.double(forKey: "cloudflare_realtime.broadcast.scale") ?? 0
    post("started")
    let uploader = BroadcastUploader(
      socketPath: container.appendingPathComponent(Self.socketName).path,
      frameRate: frameRate > 0 ? min(frameRate, 60) : 15,
      scale: scale > 0 ? min(scale, 1) : 0.5)
    uploader.onClose = { [weak self] reason in
      switch reason {
      case .notConnected:
        self?.end("Start screen sharing from the app.")
      case .closedByApp:
        self?.end("Screen sharing has stopped.")
      }
    }
    self.uploader = uploader
    uploader.start()
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType
  ) {
    // Video only: the app captures its own microphone.
    if sampleBufferType == .video { uploader?.send(sampleBuffer) }
  }

  override func broadcastFinished() {
    // The user stopped the broadcast (the status bar or Control Center).
    uploader?.stop()
    post("finished")
  }

  /// Ends the broadcast with [message], which the system shows the user.
  private func end(_ message: String) {
    uploader?.stop()
    post("finished")
    // An NSError's description reads better in the system's alert than a
    // Swift error's.
    finishBroadcastWithError(
      NSError(
        domain: RPRecordingErrorDomain, code: -1,
        userInfo: [NSLocalizedDescriptionKey: message]))
  }

  /// Posts `<appGroup>.cloudflare_realtime.broadcast.<event>` to the app.
  /// A second `finished` is harmless.
  private func post(_ event: String) {
    guard let group = appGroup else { return }
    let name = "\(group).cloudflare_realtime.broadcast.\(event)" as CFString
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name), nil, nil, true)
  }
}
