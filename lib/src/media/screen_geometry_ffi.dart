import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:ui' show Rect;

import 'media_types.dart';
import 'screen_geometry.dart';

/// The platform's [NativeScreenGeometry]: Core Graphics on macOS, user32
/// on Windows, `null` elsewhere.
NativeScreenGeometry? createNativeScreenGeometry() {
  if (Platform.isMacOS) return MacOSScreenGeometry();
  if (Platform.isWindows) return WindowsScreenGeometry();
  return null;
}

// --- macOS -----------------------------------------------------------------

/// A `CGRect`: `{{x, y}, {width, height}}`, four `CGFloat`s (doubles on
/// 64-bit macOS). Laid out and passed like the nested original.
final class _CGRect extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
  @Double()
  external double width;
  @Double()
  external double height;
}

// CoreGraphics
typedef _CGMainDisplayIDNative = Uint32 Function();
typedef _CGMainDisplayID = int Function();
typedef _CGGetActiveDisplayListNative =
    Int32 Function(Uint32, Pointer<Uint32>, Pointer<Uint32>);
typedef _CGGetActiveDisplayList =
    int Function(int, Pointer<Uint32>, Pointer<Uint32>);
typedef _CGDisplayBoundsNative = _CGRect Function(Uint32);
typedef _CGDisplayBounds = _CGRect Function(int);
typedef _CGDisplayCopyDisplayModeNative = Pointer<Void> Function(Uint32);
typedef _CGDisplayCopyDisplayMode = Pointer<Void> Function(int);
typedef _CGDisplayModeGetSizeNative = IntPtr Function(Pointer<Void>);
typedef _CGDisplayModeGetSize = int Function(Pointer<Void>);
typedef _CGDisplayModeReleaseNative = Void Function(Pointer<Void>);
typedef _CGDisplayModeRelease = void Function(Pointer<Void>);
typedef _CGWindowListCopyWindowInfoNative =
    Pointer<Void> Function(Uint32, Uint32);
typedef _CGWindowListCopyWindowInfo = Pointer<Void> Function(int, int);
typedef _CGRectMakeWithDictionaryRepresentationNative =
    Bool Function(Pointer<Void>, Pointer<_CGRect>);
typedef _CGRectMakeWithDictionaryRepresentation =
    bool Function(Pointer<Void>, Pointer<_CGRect>);
// CoreFoundation
typedef _CFArrayGetCountNative = IntPtr Function(Pointer<Void>);
typedef _CFArrayGetCount = int Function(Pointer<Void>);
typedef _CFArrayGetValueAtIndexNative =
    Pointer<Void> Function(Pointer<Void>, IntPtr);
typedef _CFArrayGetValueAtIndex = Pointer<Void> Function(Pointer<Void>, int);
typedef _CFDictionaryGetValueNative =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _CFDictionaryGetValue =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _CFReleaseNative = Void Function(Pointer<Void>);
typedef _CFRelease = void Function(Pointer<Void>);
// libc
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _Malloc = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);

const _kCGErrorSuccess = 0;
const _kCGWindowListOptionIncludingWindow = 1 << 3;
const _kCGNullWindowID = 0;
const _maxDisplays = 32;

/// macOS: Core Graphics, through `dart:ffi`.
///
/// - **Displays:** `CGGetActiveDisplayList`, with `CGDisplayBounds` (points
///   in the global display space), the scale from the display mode
///   (`CGDisplayModeGetPixelWidth / CGDisplayModeGetWidth`) and
///   `CGMainDisplayID` for the primary display. `flutter_webrtc`'s screen
///   source ID is the `CGDirectDisplayID` in decimal (its ScreenCaptureKit
///   capturer matches `"%u"` of `SCDisplay.displayID` against it).
/// - **Windows:** `CGWindowListCopyWindowInfo(IncludingWindow, id)` and its
///   `kCGWindowBounds`. The window source ID is the `CGWindowID` (libwebrtc's
///   `kCGWindowNumber`).
///
/// None of it needs the Screen Recording permission or an entitlement, and
/// it works in the App Sandbox: window bounds are readable without the
/// permission (window titles are not, and aren't read here).
class MacOSScreenGeometry implements NativeScreenGeometry {
  /// Creates the reader. Libraries open on first use.
  MacOSScreenGeometry();

  late final DynamicLibrary _cg = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
  );
  late final DynamicLibrary _cf = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
  );
  late final DynamicLibrary _libc = DynamicLibrary.process();

  late final _mainDisplayID = _cg
      .lookupFunction<_CGMainDisplayIDNative, _CGMainDisplayID>(
        'CGMainDisplayID',
      );
  late final _activeDisplayList = _cg
      .lookupFunction<_CGGetActiveDisplayListNative, _CGGetActiveDisplayList>(
        'CGGetActiveDisplayList',
      );
  late final _displayBounds = _cg
      .lookupFunction<_CGDisplayBoundsNative, _CGDisplayBounds>(
        'CGDisplayBounds',
      );
  late final _copyDisplayMode = _cg
      .lookupFunction<
        _CGDisplayCopyDisplayModeNative,
        _CGDisplayCopyDisplayMode
      >('CGDisplayCopyDisplayMode');
  late final _modeWidth = _cg
      .lookupFunction<_CGDisplayModeGetSizeNative, _CGDisplayModeGetSize>(
        'CGDisplayModeGetWidth',
      );
  late final _modePixelWidth = _cg
      .lookupFunction<_CGDisplayModeGetSizeNative, _CGDisplayModeGetSize>(
        'CGDisplayModeGetPixelWidth',
      );
  late final _modeRelease = _cg
      .lookupFunction<_CGDisplayModeReleaseNative, _CGDisplayModeRelease>(
        'CGDisplayModeRelease',
      );
  late final _windowListCopyWindowInfo = _cg
      .lookupFunction<
        _CGWindowListCopyWindowInfoNative,
        _CGWindowListCopyWindowInfo
      >('CGWindowListCopyWindowInfo');
  late final _rectFromDictionary = _cg
      .lookupFunction<
        _CGRectMakeWithDictionaryRepresentationNative,
        _CGRectMakeWithDictionaryRepresentation
      >('CGRectMakeWithDictionaryRepresentation');
  late final Pointer<Void> _kCGWindowBounds = _cg
      .lookup<Pointer<Void>>('kCGWindowBounds')
      .value;
  late final _arrayCount = _cf
      .lookupFunction<_CFArrayGetCountNative, _CFArrayGetCount>(
        'CFArrayGetCount',
      );
  late final _arrayValue = _cf
      .lookupFunction<_CFArrayGetValueAtIndexNative, _CFArrayGetValueAtIndex>(
        'CFArrayGetValueAtIndex',
      );
  late final _dictionaryValue = _cf
      .lookupFunction<_CFDictionaryGetValueNative, _CFDictionaryGetValue>(
        'CFDictionaryGetValue',
      );
  late final _cfRelease = _cf.lookupFunction<_CFReleaseNative, _CFRelease>(
    'CFRelease',
  );
  late final _malloc = _libc.lookupFunction<_MallocNative, _Malloc>('malloc');
  late final _free = _libc.lookupFunction<_FreeNative, _Free>('free');

  @override
  List<NativeDisplay> displays() {
    final ids = _malloc(sizeOf<Uint32>() * (_maxDisplays + 1)).cast<Uint32>();
    if (ids == nullptr) throw StateError('malloc');
    final count = ids + _maxDisplays;
    try {
      if (_activeDisplayList(_maxDisplays, ids, count) != _kCGErrorSuccess) {
        throw StateError('CGGetActiveDisplayList failed');
      }
      final main = _mainDisplayID();
      return [for (var i = 0; i < count.value; i++) _display(ids[i], main)];
    } finally {
      _free(ids.cast());
    }
  }

  NativeDisplay _display(int id, int main) {
    final rect = _displayBounds(id);
    final bounds = Rect.fromLTWH(rect.x, rect.y, rect.width, rect.height);
    return (
      id: '$id',
      bounds: bounds,
      scaleFactor: _scale(id),
      isPrimary: id == main,
    );
  }

  double _scale(int id) {
    final mode = _copyDisplayMode(id);
    if (mode == nullptr) return 1;
    try {
      final points = _modeWidth(mode);
      final pixels = _modePixelWidth(mode);
      return points > 0 && pixels > 0 ? pixels / points : 1;
    } finally {
      _modeRelease(mode);
    }
  }

  @override
  Rect? windowFrame(String id) {
    final windowId = int.tryParse(id);
    if (windowId == null ||
        windowId <= _kCGNullWindowID ||
        windowId > 0xFFFFFFFF) {
      return null;
    }
    final list = _windowListCopyWindowInfo(
      _kCGWindowListOptionIncludingWindow,
      windowId,
    );
    if (list == nullptr) return null;
    final rect = _malloc(sizeOf<_CGRect>()).cast<_CGRect>();
    try {
      if (rect == nullptr || _arrayCount(list) < 1) return null;
      final info = _arrayValue(list, 0);
      final bounds = _dictionaryValue(info, _kCGWindowBounds);
      if (bounds == nullptr || !_rectFromDictionary(bounds, rect)) {
        return null;
      }
      final r = rect.ref;
      return Rect.fromLTWH(r.x, r.y, r.width, r.height);
    } finally {
      if (rect != nullptr) _free(rect.cast());
      _cfRelease(list);
    }
  }

  /// [ScreenSourceEndCause.closed] when the window server no longer lists
  /// the window. A minimized or hidden window is still listed (with a
  /// frame), so there is no other cause on macOS.
  @override
  ScreenSourceEndCause? windowEndCause(String id) =>
      windowFrame(id) == null ? ScreenSourceEndCause.closed : null;
}

// --- Windows ---------------------------------------------------------------

// user32.dll
typedef _EnumDisplayDevicesWNative =
    Int32 Function(Pointer<Uint16>, Uint32, Pointer<Uint8>, Uint32);
typedef _EnumDisplayDevicesW =
    int Function(Pointer<Uint16>, int, Pointer<Uint8>, int);
typedef _MonitorEnumProcNative =
    Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, IntPtr);
typedef _EnumDisplayMonitorsNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<NativeFunction<_MonitorEnumProcNative>>,
      IntPtr,
    );
typedef _EnumDisplayMonitors =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<NativeFunction<_MonitorEnumProcNative>>,
      int,
    );
typedef _GetMonitorInfoWNative = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _GetMonitorInfoW = int Function(Pointer<Void>, Pointer<Uint8>);
typedef _HwndPredicateNative = Int32 Function(Pointer<Void>);
typedef _HwndPredicate = int Function(Pointer<Void>);
typedef _GetWindowRectNative = Int32 Function(Pointer<Void>, Pointer<Int32>);
typedef _GetWindowRect = int Function(Pointer<Void>, Pointer<Int32>);
// shcore.dll
typedef _GetDpiForMonitorNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Uint32>, Pointer<Uint32>);
typedef _GetDpiForMonitor =
    int Function(Pointer<Void>, int, Pointer<Uint32>, Pointer<Uint32>);
// dwmapi.dll
typedef _DwmGetWindowAttributeNative =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32);
typedef _DwmGetWindowAttribute =
    int Function(Pointer<Void>, int, Pointer<Void>, int);
// ole32.dll
typedef _CoTaskMemAllocNative = Pointer<Void> Function(IntPtr);
typedef _CoTaskMemAlloc = Pointer<Void> Function(int);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void>);
typedef _CoTaskMemFree = void Function(Pointer<Void>);

// DISPLAY_DEVICEW: cb, DeviceName[32], DeviceString[128], StateFlags,
// DeviceID[128], DeviceKey[128] (WCHARs).
const _displayDeviceSize = 840;
const _displayDeviceNameOffset = 4;
const _displayDeviceStateFlagsOffset = 324;
const _displayDeviceActive = 0x1;
// MONITORINFOEXW: cbSize, rcMonitor, rcWork, dwFlags, szDevice[32].
const _monitorInfoExSize = 104;
const _monitorInfoRectOffset = 4;
const _monitorInfoFlagsOffset = 36;
const _monitorInfoDeviceOffset = 40;
const _monitorInfoFPrimary = 0x1;
const _deviceNameChars = 32;
const _mdtEffectiveDpi = 0;
const _dwmwaExtendedFrameBounds = 9;

/// The monitors [EnumDisplayMonitors] reported to [_onMonitor]. The
/// callback runs synchronously, on the calling thread, during the call.
final List<int> _enumeratedMonitors = [];

int _onMonitor(
  Pointer<Void> monitor,
  Pointer<Void> dc,
  Pointer<Void> rect,
  int data,
) {
  _enumeratedMonitors.add(monitor.address);
  return 1;
}

/// Windows: user32, shcore and dwmapi, through `dart:ffi`. **Not verified
/// on a device**: built from the Win32 documentation and libwebrtc's
/// source, and unit-tested only through fakes of [NativeScreenGeometry].
///
/// - **Displays:** `flutter_webrtc`'s screen source ID is libwebrtc's
///   screen ID: the index of the display device in
///   `EnumDisplayDevicesW(NULL, index)`, counting inactive devices too
///   (`GetScreenList` in `screen_capture_utils.cc`; the DXGI capturer maps
///   its outputs back to those indices by device name). Each active device
///   is matched by name (`\\.\DISPLAY1`) to a monitor from
///   `EnumDisplayMonitors` / `GetMonitorInfoW`, which gives its bounds
///   (`rcMonitor`) and `MONITORINFOF_PRIMARY`; the scale is
///   `GetDpiForMonitor(MDT_EFFECTIVE_DPI) / 96`.
/// - **Windows:** the window source ID is the `HWND` in decimal (as
///   `flutter_webrtc`'s loopback-audio code parses it). The frame is
///   `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`, else
///   `GetWindowRect`; a hidden window (not `IsWindowVisible`, such as one
///   an app hid to the tray) or a minimized one (`IsIconic`) has none.
///
/// Coordinates are physical pixels for a per-monitor DPI-aware process,
/// which Flutter's Windows runner is (its manifest).
class WindowsScreenGeometry implements NativeScreenGeometry {
  /// Creates the reader. Libraries open on first use.
  WindowsScreenGeometry();

  late final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  late final DynamicLibrary _ole32 = DynamicLibrary.open('ole32.dll');

  late final _enumDisplayDevices = _user32
      .lookupFunction<_EnumDisplayDevicesWNative, _EnumDisplayDevicesW>(
        'EnumDisplayDevicesW',
      );
  late final _enumDisplayMonitors = _user32
      .lookupFunction<_EnumDisplayMonitorsNative, _EnumDisplayMonitors>(
        'EnumDisplayMonitors',
      );
  late final _getMonitorInfo = _user32
      .lookupFunction<_GetMonitorInfoWNative, _GetMonitorInfoW>(
        'GetMonitorInfoW',
      );
  late final _isWindow = _user32
      .lookupFunction<_HwndPredicateNative, _HwndPredicate>('IsWindow');
  late final _isIconic = _user32
      .lookupFunction<_HwndPredicateNative, _HwndPredicate>('IsIconic');
  late final _isWindowVisible = _user32
      .lookupFunction<_HwndPredicateNative, _HwndPredicate>('IsWindowVisible');
  late final _getWindowRect = _user32
      .lookupFunction<_GetWindowRectNative, _GetWindowRect>('GetWindowRect');
  late final _GetDpiForMonitor? _getDpiForMonitor = () {
    try {
      return DynamicLibrary.open(
        'shcore.dll',
      ).lookupFunction<_GetDpiForMonitorNative, _GetDpiForMonitor>(
        'GetDpiForMonitor',
      );
    } catch (_) {
      return null;
    }
  }();
  late final _DwmGetWindowAttribute? _dwmGetWindowAttribute = () {
    try {
      return DynamicLibrary.open(
        'dwmapi.dll',
      ).lookupFunction<_DwmGetWindowAttributeNative, _DwmGetWindowAttribute>(
        'DwmGetWindowAttribute',
      );
    } catch (_) {
      return null;
    }
  }();
  late final _alloc = _ole32
      .lookupFunction<_CoTaskMemAllocNative, _CoTaskMemAlloc>('CoTaskMemAlloc');
  late final _free = _ole32
      .lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFree>('CoTaskMemFree');

  @override
  List<NativeDisplay> displays() {
    final monitors = _monitorsByDevice();
    final device = _alloc(_displayDeviceSize).cast<Uint8>();
    if (device == nullptr) throw StateError('CoTaskMemAlloc');
    try {
      final displays = <NativeDisplay>[];
      // libwebrtc's GetScreenList: every index until the call fails, only
      // active devices, the index being the screen ID.
      for (var index = 0; ; index++) {
        device
            .asTypedList(_displayDeviceSize)
            .fillRange(0, _displayDeviceSize, 0);
        device.cast<Uint32>().value = _displayDeviceSize;
        if (_enumDisplayDevices(nullptr, index, device, 0) == 0) break;
        final flags = (device + _displayDeviceStateFlagsOffset)
            .cast<Uint32>()
            .value;
        if (flags & _displayDeviceActive == 0) continue;
        final name = _wideString(device + _displayDeviceNameOffset);
        final monitor = monitors[name];
        if (monitor == null) continue;
        displays.add((
          id: '$index',
          bounds: monitor.bounds,
          scaleFactor: monitor.scaleFactor,
          isPrimary: monitor.isPrimary,
        ));
      }
      return displays;
    } finally {
      _free(device.cast());
    }
  }

  /// The monitors by device name (`\\.\DISPLAY1`).
  Map<String, ({Rect bounds, double scaleFactor, bool isPrimary})>
  _monitorsByDevice() {
    _enumeratedMonitors.clear();
    final callback = Pointer.fromFunction<_MonitorEnumProcNative>(
      _onMonitor,
      0,
    );
    _enumDisplayMonitors(nullptr, nullptr, callback, 0);
    final handles = List.of(_enumeratedMonitors);
    _enumeratedMonitors.clear();

    final info = _alloc(_monitorInfoExSize + 8).cast<Uint8>();
    if (info == nullptr) throw StateError('CoTaskMemAlloc');
    final dpi = (info + _monitorInfoExSize).cast<Uint32>();
    try {
      final result =
          <String, ({Rect bounds, double scaleFactor, bool isPrimary})>{};
      for (final address in handles) {
        final monitor = Pointer<Void>.fromAddress(address);
        info
            .asTypedList(_monitorInfoExSize)
            .fillRange(0, _monitorInfoExSize, 0);
        info.cast<Uint32>().value = _monitorInfoExSize;
        if (_getMonitorInfo(monitor, info) == 0) continue;
        final rect = (info + _monitorInfoRectOffset).cast<Int32>();
        final flags = (info + _monitorInfoFlagsOffset).cast<Uint32>().value;
        result[_wideString(info + _monitorInfoDeviceOffset)] = (
          bounds: Rect.fromLTRB(
            rect[0].toDouble(),
            rect[1].toDouble(),
            rect[2].toDouble(),
            rect[3].toDouble(),
          ),
          scaleFactor: _scale(monitor, dpi),
          isPrimary: flags & _monitorInfoFPrimary != 0,
        );
      }
      return result;
    } finally {
      _free(info.cast());
    }
  }

  double _scale(Pointer<Void> monitor, Pointer<Uint32> dpi) {
    final getDpi = _getDpiForMonitor;
    if (getDpi == null) return 1;
    if (getDpi(monitor, _mdtEffectiveDpi, dpi, dpi + 1) != 0) return 1;
    return dpi.value > 0 ? dpi.value / 96 : 1;
  }

  @override
  Rect? windowFrame(String id) {
    final handle = int.tryParse(id);
    if (handle == null || handle <= 0) return null;
    final window = Pointer<Void>.fromAddress(handle);
    if (_isWindow(window) == 0 ||
        _isWindowVisible(window) == 0 ||
        _isIconic(window) != 0) {
      return null;
    }
    final rect = _alloc(16).cast<Int32>();
    if (rect == nullptr) return null;
    try {
      final dwm = _dwmGetWindowAttribute;
      final ok =
          (dwm != null &&
              dwm(window, _dwmwaExtendedFrameBounds, rect.cast(), 16) == 0) ||
          _getWindowRect(window, rect) != 0;
      if (!ok) return null;
      return Rect.fromLTRB(
        rect[0].toDouble(),
        rect[1].toDouble(),
        rect[2].toDouble(),
        rect[3].toDouble(),
      );
    } finally {
      _free(rect.cast());
    }
  }

  @override
  ScreenSourceEndCause? windowEndCause(String id) {
    final handle = int.tryParse(id);
    if (handle == null || handle <= 0) return ScreenSourceEndCause.closed;
    final window = Pointer<Void>.fromAddress(handle);
    if (_isWindow(window) == 0) return ScreenSourceEndCause.closed;
    // An app that closes to the tray may minimize the window and then hide
    // it, so hidden is checked first.
    if (_isWindowVisible(window) == 0) return ScreenSourceEndCause.hidden;
    if (_isIconic(window) != 0) return ScreenSourceEndCause.minimized;
    return null;
  }

  static String _wideString(Pointer<Uint8> at) {
    final chars = at.cast<Uint16>();
    final units = <int>[];
    for (var i = 0; i < _deviceNameChars && chars[i] != 0; i++) {
      units.add(chars[i]);
    }
    return String.fromCharCodes(units);
  }
}
