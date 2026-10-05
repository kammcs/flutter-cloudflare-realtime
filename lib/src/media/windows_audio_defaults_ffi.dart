import 'dart:ffi';
import 'dart:io' show Platform;

import '../diagnostics/log.dart';

/// The endpoint IDs of Windows' default communications microphone
/// (`input`) and speaker (`output`), or `null` when this isn't Windows or
/// Core Audio can't say.
///
/// The IDs are Core Audio endpoint IDs (`{0.0.1.00000000}.{guid}`), which
/// is what `flutter_webrtc`'s Windows plugin reports as the `deviceId` of
/// audio devices (libwebrtc's `AudioDeviceWindowsCore` hands it the
/// endpoint ID as the device's GUID).
///
/// The "communications" role is the one libwebrtc itself uses when no
/// device is chosen; where it has none, the plain default ("console") is
/// used. Synchronous and cheap (a few COM calls), so it runs on every
/// device enumeration.
({String? input, String? output})? readWindowsDefaultAudioEndpoints() {
  if (!Platform.isWindows) return null;
  try {
    return _CoreAudio().readDefaults();
  } catch (error) {
    RealtimeLog.warning(
      'reading the default audio devices failed',
      error: error,
    );
    return null;
  }
}

// ole32.dll
typedef _CoInitializeExNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CoInitializeEx = int Function(Pointer<Void>, int);
typedef _CoUninitializeNative = Void Function();
typedef _CoUninitialize = void Function();
typedef _CoCreateInstanceNative =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Void>,
      Uint32,
      Pointer<Uint8>,
      Pointer<Pointer<Void>>,
    );
typedef _CoCreateInstance =
    int Function(
      Pointer<Uint8>,
      Pointer<Void>,
      int,
      Pointer<Uint8>,
      Pointer<Pointer<Void>>,
    );
typedef _CoTaskMemAllocNative = Pointer<Void> Function(IntPtr);
typedef _CoTaskMemAlloc = Pointer<Void> Function(int);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void>);
typedef _CoTaskMemFree = void Function(Pointer<Void>);

// COM methods take the object ("this") first.
typedef _ReleaseNative = Uint32 Function(Pointer<Void>);
typedef _Release = int Function(Pointer<Void>);
typedef _GetDefaultAudioEndpointNative =
    Int32 Function(Pointer<Void>, Int32, Int32, Pointer<Pointer<Void>>);
typedef _GetDefaultAudioEndpoint =
    int Function(Pointer<Void>, int, int, Pointer<Pointer<Void>>);
typedef _GetIdNative = Int32 Function(Pointer<Void>, Pointer<Pointer<Uint16>>);
typedef _GetId = int Function(Pointer<Void>, Pointer<Pointer<Uint16>>);

const _clsidMMDeviceEnumerator = 'BCDE0395-E52F-467C-8E3D-C4579291692E';
const _iidIMMDeviceEnumerator = 'A95664D2-9614-4F35-A746-DE8DB63617E6';
const _coinitApartmentThreaded = 0x2;
const _clsctxAll = 0x17;
const _eRender = 0;
const _eCapture = 1;
const _eConsole = 0;
const _eCommunications = 2;

// IUnknown: QueryInterface, AddRef, Release.
const _release = 2;
// IMMDeviceEnumerator: ..., EnumAudioEndpoints, GetDefaultAudioEndpoint.
const _getDefaultAudioEndpoint = 4;
// IMMDevice: ..., Activate, OpenPropertyStore, GetId.
const _getId = 5;

class _CoreAudio {
  _CoreAudio() : _ole32 = DynamicLibrary.open('ole32.dll');

  final DynamicLibrary _ole32;

  late final _coInitializeEx = _ole32
      .lookupFunction<_CoInitializeExNative, _CoInitializeEx>('CoInitializeEx');
  late final _coUninitialize = _ole32
      .lookupFunction<_CoUninitializeNative, _CoUninitialize>('CoUninitialize');
  late final _coCreateInstance = _ole32
      .lookupFunction<_CoCreateInstanceNative, _CoCreateInstance>(
        'CoCreateInstance',
      );
  late final _coTaskMemAlloc = _ole32
      .lookupFunction<_CoTaskMemAllocNative, _CoTaskMemAlloc>('CoTaskMemAlloc');
  late final _coTaskMemFree = _ole32
      .lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFree>('CoTaskMemFree');

  ({String? input, String? output})? readDefaults() {
    // S_OK or S_FALSE (already initialized here) must be balanced; a
    // thread already in the other apartment (RPC_E_CHANGED_MODE) can use
    // COM as it is.
    final init = _coInitializeEx(nullptr, _coinitApartmentThreaded);
    final uninitialize = init == 0 || init == 1;
    final memory = _coTaskMemAlloc(48).cast<Uint8>();
    if (memory == nullptr) {
      if (uninitialize) _coUninitialize();
      return null;
    }
    final clsid = memory;
    final iid = memory + 16;
    final out = (memory + 32).cast<Pointer<Void>>();
    try {
      _writeGuid(clsid, _clsidMMDeviceEnumerator);
      _writeGuid(iid, _iidIMMDeviceEnumerator);
      out.value = nullptr;
      if (_coCreateInstance(clsid, nullptr, _clsctxAll, iid, out) != 0) {
        return null;
      }
      final enumerator = out.value;
      try {
        return (
          input: _defaultId(enumerator, _eCapture, out),
          output: _defaultId(enumerator, _eRender, out),
        );
      } finally {
        _releaseObject(enumerator);
      }
    } finally {
      _coTaskMemFree(memory.cast());
      if (uninitialize) _coUninitialize();
    }
  }

  /// The ID of the default [flow] endpoint for communications, else for
  /// everything else ("console").
  String? _defaultId(
    Pointer<Void> enumerator,
    int flow,
    Pointer<Pointer<Void>> out,
  ) {
    final getDefault = _vtable(enumerator)[_getDefaultAudioEndpoint]
        .cast<NativeFunction<_GetDefaultAudioEndpointNative>>()
        .asFunction<_GetDefaultAudioEndpoint>();
    for (final role in const [_eCommunications, _eConsole]) {
      out.value = nullptr;
      if (getDefault(enumerator, flow, role, out) != 0) continue;
      final device = out.value;
      try {
        final id = _deviceId(device);
        if (id != null && id.isNotEmpty) return id;
      } finally {
        _releaseObject(device);
      }
    }
    return null;
  }

  String? _deviceId(Pointer<Void> device) {
    final getId = _vtable(
      device,
    )[_getId].cast<NativeFunction<_GetIdNative>>().asFunction<_GetId>();
    final slot = _coTaskMemAlloc(8).cast<Pointer<Uint16>>();
    if (slot == nullptr) return null;
    try {
      slot.value = nullptr;
      if (getId(device, slot) != 0) return null;
      final text = slot.value;
      if (text == nullptr) return null;
      try {
        final units = <int>[];
        for (var i = 0; text[i] != 0 && i < 1024; i++) {
          units.add(text[i]);
        }
        return String.fromCharCodes(units);
      } finally {
        _coTaskMemFree(text.cast());
      }
    } finally {
      _coTaskMemFree(slot.cast());
    }
  }

  static Pointer<Pointer<Void>> _vtable(Pointer<Void> object) =>
      object.cast<Pointer<Pointer<Void>>>().value;

  static void _releaseObject(Pointer<Void> object) {
    if (object == nullptr) return;
    _vtable(object)[_release]
        .cast<NativeFunction<_ReleaseNative>>()
        .asFunction<_Release>()(object);
  }

  /// Writes a GUID ("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX") in its binary
  /// layout: three little-endian fields, then eight bytes as written.
  static void _writeGuid(Pointer<Uint8> to, String guid) {
    final hex = guid.replaceAll('-', '');
    int byte(int index) =>
        int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16);
    const order = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15];
    for (var i = 0; i < 16; i++) {
      to[i] = byte(order[i]);
    }
  }
}
