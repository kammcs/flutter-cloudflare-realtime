import AVFoundation
import Foundation
import ObjectiveC

/// WebRTC's `RTCAudioSession`, as much of it as the CallKit hand-off needs
/// (docs/design.md §4.8). The selectors are WebRTC's; the protocol only
/// lets Swift send them.
@objc private protocol RTCAudioSessionAPI: NSObjectProtocol {
  var useManualAudio: Bool { get set }
  var isAudioEnabled: Bool { get set }
  var isActive: Bool { get }
  func lockForConfiguration()
  func unlockForConfiguration()
  func audioSessionDidActivate(_ session: AVAudioSession)
  func audioSessionDidDeactivate(_ session: AVAudioSession)
  @objc(setCategory:mode:options:error:)
  func setCategory(_ category: String, mode: String, options: UInt) throws
}

/// Call audio while CallKit owns it (docs/design.md §4.8).
///
/// An app in a CallKit call must not activate its audio session: CallKit
/// activates it after the start or answer action and says so with
/// `provider(_:didActivate:)`. WebRTC's `RTCAudioSession` supports exactly
/// this: with `useManualAudio` it starts its audio only while
/// `isAudioEnabled`, and `audioSessionDidActivate:` /
/// `audioSessionDidDeactivate:` tell it what the system did.
///
/// WebRTC is in the process through flutter_webrtc, but this package has no
/// build-time dependency on it (its SPM product can't be reached from
/// another plugin's package by a stable path, and the podspec would need
/// flutter_webrtc's pod). So `RTCAudioSession` is reached through the
/// Objective-C runtime; without it (no WebRTC loaded), every call here does
/// nothing and the category is set on `AVAudioSession` directly.
final class SystemCallAudio {
  static let shared = SystemCallAudio()

  private let session: RTCAudioSessionAPI?
  private let configurationClass: NSObject.Type?
  private var guardInstalled = false
  /// Whether CallKit owns the session's activation now: a CallKit call
  /// exists. flutter_webrtc's own deactivation is skipped meanwhile.
  fileprivate(set) var callKitOwnsSession = false

  private init() {
    session = Self.findSession()
    configurationClass = NSClassFromString("RTCAudioSessionConfiguration") as? NSObject.Type
  }

  /// Whether WebRTC's `RTCAudioSession` was found.
  var isAvailable: Bool { session != nil }

  var useManualAudio: Bool { session?.useManualAudio ?? false }

  var isAudioEnabled: Bool { session?.isAudioEnabled ?? true }

  private static let selectors = [
    "useManualAudio", "setUseManualAudio:", "isAudioEnabled", "setIsAudioEnabled:", "isActive",
    "lockForConfiguration", "unlockForConfiguration", "audioSessionDidActivate:",
    "audioSessionDidDeactivate:", "setCategory:mode:options:error:",
  ]

  private static func findSession() -> RTCAudioSessionAPI? {
    guard let cls = NSClassFromString("RTCAudioSession") as? NSObject.Type else { return nil }
    let shared = NSSelectorFromString("sharedInstance")
    guard cls.responds(to: shared),
      let instance = cls.perform(shared)?.takeUnretainedValue() as? NSObject
    else { return nil }
    for name in selectors where !instance.responds(to: NSSelectorFromString(name)) {
      NSLog("cloudflare_realtime: RTCAudioSession lacks %@; CallKit audio hand-off is off", name)
      return nil
    }
    return unsafeBitCast(instance, to: RTCAudioSessionAPI.self)
  }

  /// Turns manual audio on (system calls configured): WebRTC starts its
  /// audio only while `isAudioEnabled`, which stays `true` outside CallKit
  /// calls, so other calls are unchanged.
  func enableManualAudio() {
    installDeactivationGuard()
    guard let session, !session.useManualAudio else { return }
    // Allowed first, so audio that runs now (a call without CallKit) isn't
    // stopped by the switch; `update` follows the calls from here.
    if !session.isAudioEnabled { session.isAudioEnabled = true }
    session.useManualAudio = true
    NSLog("cloudflare_realtime: WebRTC manual audio on (system calls)")
  }

  /// Follows the calls: `isAudioEnabled` is `true` while no CallKit call
  /// exists or CallKit activated the session, and `false` from a call's
  /// report until `provider(_:didActivate:)`.
  func update(hasCalls: Bool, activated: Bool) {
    callKitOwnsSession = hasCalls
    let enabled = !hasCalls || activated
    guard let session, session.isAudioEnabled != enabled else { return }
    session.isAudioEnabled = enabled
  }

  /// CallKit activated the session (`provider(_:didActivate:)`).
  func didActivate(_ audioSession: AVAudioSession) {
    session?.audioSessionDidActivate(audioSession)
  }

  /// CallKit deactivated the session (`provider(_:didDeactivate:)`).
  func didDeactivate(_ audioSession: AVAudioSession) {
    session?.audioSessionDidDeactivate(audioSession)
  }

  /// Sets the category before CallKit activates the session, in the start
  /// and answer actions, as Apple asks: `playAndRecord`, with the mode and
  /// options of WebRTC's configuration (the base configuration call audio
  /// sets, docs/design.md §4.6).
  func configureCategory(video: Bool) {
    let config = configurationClass.flatMap { cls -> NSObject? in
      let sel = NSSelectorFromString("webRTCConfiguration")
      guard cls.responds(to: sel) else { return nil }
      return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }
    // Read only what the configuration has (KVC raises for a missing key).
    func read(_ key: String) -> Any? {
      guard let config, config.responds(to: NSSelectorFromString(key)) else { return nil }
      return config.value(forKey: key)
    }
    let category = AVAudioSession.Category.playAndRecord.rawValue
    var mode =
      read("mode") as? String
      ?? (video ? AVAudioSession.Mode.videoChat : AVAudioSession.Mode.voiceChat).rawValue
    if mode != AVAudioSession.Mode.voiceChat.rawValue
      && mode != AVAudioSession.Mode.videoChat.rawValue
    {
      mode = (video ? AVAudioSession.Mode.videoChat : AVAudioSession.Mode.voiceChat).rawValue
    }
    // allowBluetooth (hands-free), as call audio always allows it.
    let allowBluetoothHFP: UInt = 0x4
    var options = (read("categoryOptions") as? NSNumber)?.uintValue ?? 0
    if read("category") as? String != category { options = 0 }
    options |= allowBluetoothHFP
    do {
      if let session {
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.setCategory(category, mode: mode, options: options)
      } else {
        try AVAudioSession.sharedInstance().setCategory(
          AVAudioSession.Category(rawValue: category), mode: AVAudioSession.Mode(rawValue: mode),
          options: AVAudioSession.CategoryOptions(rawValue: options))
      }
    } catch {
      NSLog("cloudflare_realtime: setting the call's audio category failed: %@", "\(error)")
    }
  }

  // flutter_webrtc deactivates the session itself
  // (`+[AudioUtils deactiveRtcAudioSession]`) when a peer connection closes
  // or a stream is disposed and no local audio track or open peer
  // connection is left: during a re-session of a receive-only call (§8.1),
  // or when a call's room closes before CallKit ends it. In a CallKit call
  // that would take the session from under CallKit (CallKit owns its
  // activation, and only CallKit gives it back). The guard skips that
  // deactivation while a CallKit call exists; CallKit deactivates the
  // session itself when the call ends.
  private func installDeactivationGuard() {
    guard !guardInstalled else { return }
    guardInstalled = true
    let selector = NSSelectorFromString("deactiveRtcAudioSession")
    guard let cls = NSClassFromString("AudioUtils"),
      let method = class_getClassMethod(cls, selector)
    else {
      NSLog("cloudflare_realtime: flutter_webrtc's AudioUtils not found; no deactivation guard")
      return
    }
    typealias Deactivate = @convention(c) (AnyClass, Selector) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Deactivate.self)
    let replacement: @convention(block) (AnyClass) -> Void = { cls in
      if SystemCallAudio.shared.callKitOwnsSession {
        NSLog("cloudflare_realtime: kept the audio session active: CallKit owns it")
        return
      }
      original(cls, selector)
    }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
  }
}
