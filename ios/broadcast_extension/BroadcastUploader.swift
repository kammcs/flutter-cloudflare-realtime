// cloudflare_realtime: Broadcast Upload Extension template (MIT License).
//
// Sends the screen to the app over the UNIX socket flutter_webrtc listens
// on (`<App Group container>/rtc_SSFD`), in the framing its
// FlutterSocketConnectionFrameReader reads: one serialized HTTP message per
// frame, with the headers Content-Length, Buffer-Width, Buffer-Height and
// Buffer-Orientation (a CGImagePropertyOrientation) and a JPEG body.
//
// Broadcast extensions are limited to about 50 MB of memory, so it keeps
// one CIContext, encodes one frame at a time and drops frames while busy,
// and throttles to the app's frame rate before doing any work.

import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ReplayKit

final class BroadcastUploader {
  /// Why the connection to the app ended.
  enum CloseReason {
    /// The app wasn't listening (it isn't sharing, or gave up waiting).
    case notConnected
    /// The app stopped sharing, or went away.
    case closedByApp
  }

  /// Called once, on the main queue, when the connection ends by itself
  /// (not after [stop]).
  var onClose: ((CloseReason) -> Void)?

  private let socketPath: String
  private let frameInterval: TimeInterval
  private let scale: Double

  /// How long to keep trying to reach the app's socket.
  private static let connectTimeout: TimeInterval = 5
  /// How often a still screen is sent again. ReplayKit only delivers frames
  /// when the screen changes, and a sender without frames looks stalled
  /// (and leaves late subscribers without a picture).
  private static let repeatInterval: TimeInterval = 1
  private static let jpegQuality = 0.8

  private let queue = DispatchQueue(
    label: "cloudflare_realtime.broadcast.upload", qos: .userInitiated)
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  // Guarded by `lock`: read from ReplayKit's thread.
  private let lock = NSLock()
  private var connected = false
  private var busy = false
  private var stopped = false
  private var lastAccepted: TimeInterval = 0

  // Only touched on `queue`.
  private var socket: Int32 = -1
  private var eofSource: DispatchSourceRead?
  private var repeatTimer: DispatchSourceTimer?
  private var lastFrame: Data?
  private var lastSent: TimeInterval = 0
  private var closed = false

  init(socketPath: String, frameRate: Int, scale: Double) {
    self.socketPath = socketPath
    self.frameInterval = 1 / Double(max(frameRate, 1))
    self.scale = scale
  }

  /// Connects to the app, retrying for a few seconds.
  func start() {
    let deadline = Date().addingTimeInterval(Self.connectTimeout)
    queue.async { self.connect(until: deadline) }
  }

  /// Encodes and sends [sampleBuffer] unless it comes too soon after the
  /// last one, or the previous frame is still being sent.
  func send(_ sampleBuffer: CMSampleBuffer) {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    // A little slack, so 30 fps capture isn't throttled to 15 for 30.
    let accept =
      connected && !busy && !stopped && now - lastAccepted >= frameInterval * 0.9
    if accept {
      busy = true
      lastAccepted = now
    }
    lock.unlock()
    guard accept, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      if accept { setBusy(false) }
      return
    }
    let orientation =
      (CMGetAttachment(
        sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)
        as? NSNumber)?.uint32Value ?? CGImagePropertyOrientation.up.rawValue
    queue.async {
      defer { self.setBusy(false) }
      guard !self.closed else { return }
      let message: Data? = autoreleasepool { self.encode(pixels, orientation: orientation) }
      guard let message else { return }
      self.lastFrame = message
      self.write(message)
    }
  }

  /// Disconnects. No [onClose] call follows.
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
    queue.async { self.close(reason: nil) }
  }

  // MARK: Connection (on `queue`)

  private func connect(until deadline: Date) {
    guard !closed, !isStopped else { return }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd >= 0 {
      var on: Int32 = 1
      // A write to a closed socket must fail, not kill the extension.
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let path = Array(socketPath.utf8CString)
      let fits = path.count <= MemoryLayout.size(ofValue: address.sun_path)
      if fits {
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
          path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let status = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
          }
        }
        if status == 0 {
          didConnect(fd)
          return
        }
      }
      Darwin.close(fd)
    }
    if Date() >= deadline {
      close(reason: .notConnected)
      return
    }
    queue.asyncAfter(deadline: .now() + 0.25) { self.connect(until: deadline) }
  }

  private func didConnect(_ fd: Int32) {
    socket = fd
    // The app never writes: the socket turns readable only when the app
    // closes it.
    let eof = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    eof.setEventHandler { [weak self] in
      guard let self else { return }
      var byte: UInt8 = 0
      let n = recv(fd, &byte, 1, MSG_DONTWAIT)
      if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
        self.close(reason: .closedByApp)
      }
    }
    eof.resume()
    eofSource = eof
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + Self.repeatInterval, repeating: Self.repeatInterval)
    timer.setEventHandler { [weak self] in self?.repeatStillFrame() }
    timer.resume()
    repeatTimer = timer
    setConnected(true)
  }

  private func repeatStillFrame() {
    guard !closed, let frame = lastFrame,
      ProcessInfo.processInfo.systemUptime - lastSent >= Self.repeatInterval
    else { return }
    lock.lock()
    let idle = !busy
    lock.unlock()
    if idle { write(frame) }
  }

  private func write(_ message: Data) {
    guard socket >= 0 else { return }
    let ok = message.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
      guard let base = raw.baseAddress else { return false }
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(socket, base + offset, raw.count - offset)
        if n < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += n
      }
      return true
    }
    if ok {
      lastSent = ProcessInfo.processInfo.systemUptime
    } else {
      close(reason: .closedByApp)
    }
  }

  private func close(reason: CloseReason?) {
    guard !closed else { return }
    closed = true
    setConnected(false)
    repeatTimer?.cancel()
    repeatTimer = nil
    eofSource?.cancel()
    eofSource = nil
    if socket >= 0 {
      Darwin.close(socket)
      socket = -1
    }
    lastFrame = nil
    guard let reason, !isStopped, let onClose else { return }
    DispatchQueue.main.async { onClose(reason) }
  }

  // MARK: Encoding (on `queue`)

  /// One framed message: the frame scaled and encoded as JPEG.
  private func encode(_ pixels: CVPixelBuffer, orientation: UInt32) -> Data? {
    let width = CVPixelBufferGetWidth(pixels)
    let height = CVPixelBufferGetHeight(pixels)
    guard width > 0, height > 0 else { return nil }
    // Even sizes: the app converts each frame to I420.
    let targetWidth = max(2, Int((Double(width) * scale).rounded()) & ~1)
    let targetHeight = max(2, Int((Double(height) * scale).rounded()) & ~1)
    var image = CIImage(cvPixelBuffer: pixels)
    if targetWidth != width || targetHeight != height {
      let scaleY = Double(targetHeight) / Double(height)
      let scaleX = Double(targetWidth) / Double(width)
      // Lanczos keeps small text more legible than a plain transform.
      image = image.applyingFilter(
        "CILanczosScaleTransform",
        parameters: [
          kCIInputScaleKey: scaleY,
          kCIInputAspectRatioKey: scaleX / scaleY,
        ])
    }
    image = image.cropped(
      to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    let options = [
      CIImageRepresentationOption(
        rawValue: kCGImageDestinationLossyCompressionQuality as String): Self.jpegQuality
    ]
    guard
      let jpeg = context.jpegRepresentation(
        of: image, colorSpace: colorSpace, options: options)
    else { return nil }

    let message = CFHTTPMessageCreateResponse(nil, 200, nil, kCFHTTPVersion1_1)
      .takeRetainedValue()
    for (field, value) in [
      ("Content-Length", jpeg.count),
      ("Buffer-Width", targetWidth),
      ("Buffer-Height", targetHeight),
      ("Buffer-Orientation", Int(orientation)),
    ] {
      CFHTTPMessageSetHeaderFieldValue(message, field as CFString, String(value) as CFString)
    }
    CFHTTPMessageSetBody(message, jpeg as CFData)
    return CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data?
  }

  // MARK: Shared state

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func setBusy(_ value: Bool) {
    lock.lock()
    busy = value
    lock.unlock()
  }

  private func setConnected(_ value: Bool) {
    lock.lock()
    connected = value
    lock.unlock()
  }
}
