import 'dart:async';

import 'package:cloudflare_realtime/src/media/media_backend.dart';
import 'package:cloudflare_realtime/src/media/media_types.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

int _nextId = 0;

/// A [MediaStreamTrack] that records what the library does to it.
class FakeTrack extends MediaStreamTrack {
  FakeTrack({required String kind, this.settings = const {}, String? label})
    : _trackKind = kind,
      _label = label ?? '',
      _id = 'track-${_nextId++}';

  final String _trackKind;
  final String _label;
  final String _id;
  final Map<String, dynamic> settings;
  bool _enabled = true;
  bool stopped = false;

  /// Called when the track is stopped.
  void Function()? onStop;

  @override
  String get id => _id;

  @override
  String get kind => _trackKind;

  @override
  String get label => _label;

  @override
  bool get enabled => _enabled;

  @override
  set enabled(bool value) => _enabled = value;

  @override
  bool get muted => false;

  @override
  Map<String, dynamic> getSettings() => settings;

  @override
  Future<void> stop() async {
    stopped = true;
    onStop?.call();
  }

  @override
  Future<void> dispose() => stop();

  /// Simulates the platform ending the track (unplug, "Stop sharing").
  void endExternally() => onEnded?.call();
}

/// A [MediaStream] holding [FakeTrack]s.
class FakeStream extends MediaStream {
  FakeStream(this.tracks) : super('stream-${_nextId++}', 'local');

  final List<FakeTrack> tracks;
  bool disposed = false;

  @override
  bool get active => tracks.any((t) => !t.stopped);

  @override
  Future<void> getMediaTracks() async {}

  @override
  Future<void> addTrack(MediaStreamTrack track, {bool addToNative = true}) =>
      throw UnimplementedError();

  @override
  Future<void> removeTrack(
    MediaStreamTrack track, {
    bool removeFromNative = true,
  }) => throw UnimplementedError();

  @override
  List<MediaStreamTrack> getTracks() => List.of(tracks);

  @override
  List<MediaStreamTrack> getAudioTracks() =>
      tracks.where((t) => t.kind == 'audio').toList();

  @override
  List<MediaStreamTrack> getVideoTracks() =>
      tracks.where((t) => t.kind == 'video').toList();

  @override
  Future<void> dispose() async => disposed = true;

  FakeTrack get track => tracks.first;
}

/// The device ID a set of `getUserMedia` constraints asks for, in either the
/// web or the native shape.
String? requestedDeviceId(Map<String, dynamic> media) {
  final exact = (media['deviceId'] as Map?)?['exact'];
  if (exact is String) return exact;
  final optional = media['optional'] as List?;
  if (optional == null) return null;
  for (final entry in optional) {
    final sourceId = (entry as Map)['sourceId'];
    if (sourceId is String) return sourceId;
  }
  return null;
}

/// A scriptable [MediaBackend].
///
/// `getUserMedia` behaves like a platform: it opens the requested device if
/// it's plugged in (and not in [failingDeviceIds]), or the first device of
/// the kind when none was requested.
class FakeMediaBackend implements MediaBackend {
  FakeMediaBackend({
    this.platform = MediaPlatform.windows,
    List<MediaDevice> devices = const [],
    this.desktop,
    this.screenCapture,
    this.broadcast,
  }) : _devices = List.of(devices);

  @override
  MediaPlatform platform;

  List<MediaDevice> _devices;

  /// Device IDs whose capture fails with NotReadableError.
  final Set<String> failingDeviceIds = {};

  /// When set, every getUserMedia call fails with this.
  Object? userMediaError;

  /// When set, getDisplayMedia calls this instead of the default.
  Future<MediaStream> Function(Map<String, dynamic> constraints)?
  onDisplayMedia;

  final List<Map<String, dynamic>> userMediaCalls = [];
  final List<Map<String, dynamic>> displayMediaCalls = [];
  final List<FakeStream> streams = [];
  int enumerateCalls = 0;

  final StreamController<void> _changes = StreamController.broadcast(
    sync: true,
  );

  final FakeDesktopCapturer? desktop;

  @override
  DesktopCapturerBackend? get desktopCapturer => desktop;

  final FakeScreenCaptureService? screenCapture;

  @override
  ScreenCaptureServiceBackend? get screenCaptureService => screenCapture;

  final FakeBroadcastExtension? broadcast;

  @override
  BroadcastExtensionBackend? get broadcastExtension => broadcast;

  List<MediaDevice> get devices => List.unmodifiable(_devices);

  /// Replaces the device list and fires `devicechange`.
  void setDevices(List<MediaDevice> devices) {
    _devices = List.of(devices);
    _changes.add(null);
  }

  /// Replaces the device list without firing `devicechange`.
  void setDevicesSilently(List<MediaDevice> devices) {
    _devices = List.of(devices);
  }

  /// Requested device ID -> the device ID the "platform" really opens, like
  /// native Windows falling back to the first camera.
  final Map<String, String> redirects = {};

  /// Extra settings for captured video tracks, such as a width and height.
  Map<String, dynamic> videoSettings = const {};

  /// Called after each successful getUserMedia.
  void Function()? afterUserMedia;

  @override
  Stream<void> get deviceChanges => _changes.stream;

  @override
  Future<List<MediaDevice>> enumerateDevices() async {
    enumerateCalls++;
    return List.of(_devices);
  }

  @override
  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints) async {
    userMediaCalls.add(constraints);
    final error = userMediaError;
    if (error != null) throw error;
    final isAudio = constraints['audio'] != false;
    final kind = isAudio
        ? MediaDeviceKind.audioInput
        : MediaDeviceKind.videoInput;
    final media =
        (isAudio ? constraints['audio'] : constraints['video']) as Map;
    final requested = requestedDeviceId(Map<String, dynamic>.from(media));
    final wanted = redirects[requested] ?? requested;
    final ofKind = _devices.where((d) => d.kind == kind).toList();
    final MediaDevice device;
    if (wanted == null) {
      if (ofKind.isEmpty) throw 'Unable to getUserMedia: NotFoundError';
      device = ofKind.first;
    } else {
      final match = ofKind.where((d) => d.deviceId == wanted);
      if (match.isEmpty) throw 'Unable to getUserMedia: NotFoundError';
      device = match.first;
    }
    if (failingDeviceIds.contains(device.deviceId)) {
      throw 'Unable to getUserMedia: NotReadableError';
    }
    final stream = FakeStream([
      FakeTrack(
        kind: isAudio ? 'audio' : 'video',
        label: device.label,
        settings: {'deviceId': device.deviceId, if (!isAudio) ...videoSettings},
      ),
    ]);
    streams.add(stream);
    afterUserMedia?.call();
    return stream;
  }

  @override
  Future<MediaStream> getDisplayMedia(Map<String, dynamic> constraints) async {
    displayMediaCalls.add(constraints);
    final handler = onDisplayMedia;
    if (handler != null) return handler(constraints);
    final stream = FakeStream([
      FakeTrack(kind: 'video'),
      if (constraints['audio'] == true) FakeTrack(kind: 'audio'),
    ]);
    streams.add(stream);
    return stream;
  }

  Future<void> close() => _changes.close();
}

/// A scriptable [ScreenCaptureServiceBackend] (Android's consent dialog
/// and foreground service). Records every call in [calls].
class FakeScreenCaptureService implements ScreenCaptureServiceBackend {
  /// What the consent dialog answers.
  bool consent = true;

  /// When set, [startService] throws it.
  Object? startError;

  /// What [watch] answers.
  bool canWatch = true;

  /// When set, [requestConsent] waits for it.
  Completer<void>? consentGate;

  /// `consent`, `start`, `watch:<trackId>`, `stop`, in order.
  final List<String> calls = [];

  bool running = false;

  final _stopped = StreamController<String?>.broadcast(sync: true);

  /// Simulates the user stopping the share outside the app: the system's
  /// stop ([trackId]) or the notification (`null`).
  void stopFromSystem([String? trackId]) => _stopped.add(trackId);

  @override
  Future<bool> requestConsent() async {
    calls.add('consent');
    await consentGate?.future;
    return consent;
  }

  @override
  Future<void> startService() async {
    calls.add('start');
    final error = startError;
    if (error != null) throw error;
    running = true;
  }

  @override
  Future<bool> watch(String trackId) async {
    calls.add('watch:$trackId');
    return canWatch;
  }

  @override
  Future<void> stopService() async {
    calls.add('stop');
    running = false;
  }

  @override
  Stream<String?> get stopped => _stopped.stream;
}

/// A scriptable [BroadcastExtensionBackend] (iOS). Records every call in
/// [calls]. Like the real extension, a broadcast that is running finishes
/// when the app releases its capture ([captureReleased]).
class FakeBroadcastExtension implements BroadcastExtensionBackend {
  /// What [status] reports as missing.
  List<BroadcastSetupProblem> problems = const [];

  /// Whether a broadcast is running.
  bool broadcasting = false;

  /// When set, [status] throws it.
  Object? statusError;

  /// `status`, `prepare:<frameRate>@<scale>`, `abandon`, in order.
  final List<String> calls = [];

  final _events = StreamController<BroadcastExtensionEvent>.broadcast(
    sync: true,
  );

  /// The user starts the broadcast.
  void start() {
    broadcasting = true;
    _events.add(BroadcastExtensionEvent.started);
  }

  /// The broadcast finishes (the user stopped it, or the app's capture
  /// ended).
  void finish() {
    broadcasting = false;
    _events.add(BroadcastExtensionEvent.finished);
  }

  /// The app released the capture the broadcast sends to: the extension
  /// sees its socket close and finishes.
  void captureReleased() {
    if (broadcasting) finish();
  }

  @override
  Future<BroadcastExtensionStatus> status() async {
    calls.add('status');
    final error = statusError;
    if (error != null) throw error;
    return BroadcastExtensionStatus(
      problems: problems,
      broadcasting: broadcasting,
    );
  }

  @override
  Future<void> prepare({required int frameRate, required double scale}) async {
    calls.add('prepare:$frameRate@$scale');
  }

  @override
  Future<void> abandon() async => calls.add('abandon');

  @override
  Stream<BroadcastExtensionEvent> get events => _events.stream;
}

/// A scriptable [DesktopCapturerBackend].
class FakeDesktopCapturer implements DesktopCapturerBackend {
  FakeDesktopCapturer([List<ScreenSource> sources = const []])
    : sources = List.of(sources);

  List<ScreenSource> sources;

  /// The next [getSources] calls throw these, in order.
  final List<Object> getSourcesErrors = [];

  int getSourcesCalls = 0;
  int updateSourcesCalls = 0;
  final List<Set<ScreenSourceType>> requestedTypes = [];
  ({int width, int height})? lastThumbnailSize;

  final added = StreamController<ScreenSource>.broadcast(sync: true);
  final removed = StreamController<ScreenSource>.broadcast(sync: true);
  final nameChanged = StreamController<ScreenSource>.broadcast(sync: true);
  final thumbnailChanged = StreamController<ScreenSource>.broadcast(sync: true);

  @override
  Future<List<ScreenSource>> getSources({
    required Set<ScreenSourceType> types,
    ({int width, int height})? thumbnailSize,
  }) async {
    getSourcesCalls++;
    requestedTypes.add(types);
    lastThumbnailSize = thumbnailSize;
    if (getSourcesErrors.isNotEmpty) throw getSourcesErrors.removeAt(0);
    return sources.where((s) => types.contains(s.type)).toList();
  }

  @override
  Future<bool> updateSources({required Set<ScreenSourceType> types}) async {
    updateSourcesCalls++;
    return true;
  }

  @override
  Stream<ScreenSource> get onAdded => added.stream;

  @override
  Stream<ScreenSource> get onRemoved => removed.stream;

  @override
  Stream<ScreenSource> get onNameChanged => nameChanged.stream;

  @override
  Stream<ScreenSource> get onThumbnailChanged => thumbnailChanged.stream;
}

const cam1 = MediaDevice(
  deviceId: 'cam-1',
  kind: MediaDeviceKind.videoInput,
  label: 'Built-in Camera',
);
const cam2 = MediaDevice(
  deviceId: 'cam-2',
  kind: MediaDeviceKind.videoInput,
  label: 'USB Webcam',
);
const mic1 = MediaDevice(
  deviceId: 'mic-1',
  kind: MediaDeviceKind.audioInput,
  label: 'Built-in Microphone',
);
const mic2 = MediaDevice(
  deviceId: 'mic-2',
  kind: MediaDeviceKind.audioInput,
  label: 'Headset Microphone',
);
const speaker1 = MediaDevice(
  deviceId: 'spk-1',
  kind: MediaDeviceKind.audioOutput,
  label: 'Speakers',
);
