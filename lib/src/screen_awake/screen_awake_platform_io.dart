import 'dart:convert' show utf8;
import 'dart:ffi';
import 'dart:io' show Platform;

import '../diagnostics/log.dart';
import 'screen_awake_backend.dart';

/// The backend for this platform: the plugin on Android and iOS,
/// `dart:ffi` on Windows and macOS, nothing on Linux.
ScreenAwakeBackend createPlatformScreenAwakeBackend() {
  if (Platform.isAndroid || Platform.isIOS) {
    return const MethodChannelScreenAwakeBackend();
  }
  if (Platform.isWindows) return WindowsScreenAwakeBackend();
  if (Platform.isMacOS) return MacOSScreenAwakeBackend();
  return const UnsupportedScreenAwakeBackend();
}

// kernel32.dll
typedef _SetThreadExecutionStateNative = Uint32 Function(Uint32);
typedef _SetThreadExecutionState = int Function(int);

const _esSystemRequired = 0x00000001;
const _esDisplayRequired = 0x00000002;
const _esContinuous = 0x80000000;

/// Windows: `SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED |
/// ES_SYSTEM_REQUIRED)` while held, `ES_CONTINUOUS` alone to release.
///
/// The state belongs to the calling thread (and ends with it), so it is set
/// and cleared from the same isolate: the root isolate, whose thread is
/// Flutter's UI thread for the app's lifetime. `powercfg /requests` lists it
/// under `DISPLAY` and `SYSTEM`, with the app's executable.
class WindowsScreenAwakeBackend implements ScreenAwakeBackend {
  /// Creates the backend.
  WindowsScreenAwakeBackend();

  late final _SetThreadExecutionState _setThreadExecutionState =
      DynamicLibrary.open('kernel32.dll').lookupFunction<
        _SetThreadExecutionStateNative,
        _SetThreadExecutionState
      >('SetThreadExecutionState');

  @override
  bool get supported => true;

  @override
  Future<bool> setKeepAwake(bool on) async {
    // The previous state, or 0 when the call failed.
    final previous = _setThreadExecutionState(
      on
          ? _esContinuous | _esDisplayRequired | _esSystemRequired
          : _esContinuous,
    );
    if (previous == 0) {
      RealtimeLog.warning('SetThreadExecutionState failed');
      return false;
    }
    return on;
  }

  @override
  Stream<bool> get changes => const Stream.empty();
}

// IOKit and CoreFoundation.
typedef _IOPMAssertionCreateWithNameNative =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Pointer<Uint32>);
typedef _IOPMAssertionCreateWithName =
    int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint32>);
typedef _IOPMAssertionReleaseNative = Int32 Function(Uint32);
typedef _IOPMAssertionRelease = int Function(int);
typedef _CFStringCreateWithCStringNative =
    Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, Uint32);
typedef _CFStringCreateWithCString =
    Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _CFReleaseNative = Void Function(Pointer<Void>);
typedef _CFRelease = void Function(Pointer<Void>);
// libc
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _Malloc = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);

// kIOPMAssertionTypePreventUserIdleDisplaySleep
const _assertionType = 'PreventUserIdleDisplaySleep';
const _assertionName = 'cloudflare_realtime: video call';
const _kIOPMAssertionLevelOn = 255;
const _kCFStringEncodingUTF8 = 0x08000100;
const _kIOReturnSuccess = 0;

/// macOS: an `IOPMAssertion` of type `PreventUserIdleDisplaySleep` while
/// held (`IOPMAssertionCreateWithName`), released with
/// `IOPMAssertionRelease`. It works in the App Sandbox without an
/// entitlement; `pmset -g assertions` lists it with its name.
class MacOSScreenAwakeBackend implements ScreenAwakeBackend {
  /// Creates the backend.
  MacOSScreenAwakeBackend();

  late final DynamicLibrary _iokit = DynamicLibrary.open(
    '/System/Library/Frameworks/IOKit.framework/IOKit',
  );
  late final DynamicLibrary _coreFoundation = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
  );
  late final DynamicLibrary _libc = DynamicLibrary.process();

  late final _IOPMAssertionCreateWithName _create = _iokit
      .lookupFunction<
        _IOPMAssertionCreateWithNameNative,
        _IOPMAssertionCreateWithName
      >('IOPMAssertionCreateWithName');
  late final _IOPMAssertionRelease _release = _iokit
      .lookupFunction<_IOPMAssertionReleaseNative, _IOPMAssertionRelease>(
        'IOPMAssertionRelease',
      );
  late final _CFStringCreateWithCString _cfString = _coreFoundation
      .lookupFunction<
        _CFStringCreateWithCStringNative,
        _CFStringCreateWithCString
      >('CFStringCreateWithCString');
  late final _CFRelease _cfRelease = _coreFoundation
      .lookupFunction<_CFReleaseNative, _CFRelease>('CFRelease');
  late final _Malloc _malloc = _libc.lookupFunction<_MallocNative, _Malloc>(
    'malloc',
  );
  late final _Free _free = _libc.lookupFunction<_FreeNative, _Free>('free');

  // The held assertion's ID, or null.
  int? _assertion;

  @override
  bool get supported => true;

  @override
  Future<bool> setKeepAwake(bool on) async {
    try {
      return on ? _hold() : _letGo();
    } catch (error) {
      RealtimeLog.warning('IOPMAssertion failed', error: error);
      return false;
    }
  }

  bool _hold() {
    if (_assertion != null) return true;
    final type = _cfStringFrom(_assertionType);
    final name = _cfStringFrom(_assertionName);
    final id = _malloc(sizeOf<Uint32>()).cast<Uint32>();
    try {
      final result = _create(type, _kIOPMAssertionLevelOn, name, id);
      if (result != _kIOReturnSuccess) {
        RealtimeLog.warning(
          'IOPMAssertionCreateWithName failed',
          errorCode: '$result',
        );
        return false;
      }
      _assertion = id.value;
      return true;
    } finally {
      _free(id.cast());
      _cfRelease(type);
      _cfRelease(name);
    }
  }

  bool _letGo() {
    final assertion = _assertion;
    _assertion = null;
    if (assertion != null) _release(assertion);
    return false;
  }

  Pointer<Void> _cfStringFrom(String value) {
    final bytes = utf8.encode(value);
    final buffer = _malloc(bytes.length + 1).cast<Uint8>();
    try {
      buffer.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      final string = _cfString(nullptr, buffer, _kCFStringEncodingUTF8);
      if (string == nullptr) throw StateError('CFStringCreateWithCString');
      return string;
    } finally {
      _free(buffer.cast());
    }
  }

  @override
  Stream<bool> get changes => const Stream.empty();
}
