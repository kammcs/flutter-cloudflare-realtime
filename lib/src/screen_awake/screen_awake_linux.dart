import 'dart:convert' show LineSplitter, utf8;
import 'dart:ffi';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';

import '../diagnostics/log.dart';
import 'screen_awake_backend.dart';

/// How a [LinuxScreenAwakeBackend] keeps the screen on.
enum LinuxInhibitor {
  /// The XDG desktop portal: `org.freedesktop.portal.Inhibit.Inhibit` with
  /// the idle flag, ended by closing the returned request. It works on
  /// Wayland and X11, inside a Flatpak or Snap sandbox too, but only for an
  /// app the portal can name: a sandboxed app, or a host app launched under
  /// its application ID (GNOME Shell and KDE start a `.desktop` app in an
  /// `app-<launcher>-<app ID>-<random>.scope`). For a host app without one
  /// (started from a terminal), GNOME's backend refuses the inhibitor
  /// ("Application ID not specified") while the portal still answers, so the
  /// failure can't be seen.
  portal,

  /// `org.freedesktop.ScreenSaver.Inhibit`, ended with `UnInhibit`. GNOME
  /// (gsd-screensaver-proxy, forwarding to gnome-session), KDE Plasma, Xfce
  /// and xscreensaver provide it, on Wayland and X11; sandboxes usually
  /// don't let it through.
  screenSaver,
}

/// The order to try the inhibitors in: the portal first where it can name
/// the app ([linuxPortalKnowsApp]), else `org.freedesktop.ScreenSaver` first.
/// Either falls back to the other when its service doesn't answer.
List<LinuxInhibitor> defaultLinuxInhibitors() => linuxPortalKnowsApp()
    ? const [LinuxInhibitor.portal, LinuxInhibitor.screenSaver]
    : const [LinuxInhibitor.screenSaver, LinuxInhibitor.portal];

/// Whether the desktop portal can tell which app this process is, as
/// `xdg-desktop-portal` does for its callers: a Flatpak (`/.flatpak-info`), a
/// Snap (`SNAP`), or a host app whose systemd unit carries a valid
/// application ID ([appIdFromSystemdUnit], from `/proc/self/cgroup`).
bool linuxPortalKnowsApp() {
  try {
    if (File('/.flatpak-info').existsSync()) return true;
    if ((Platform.environment['SNAP'] ?? '').isNotEmpty) return true;
    final cgroup = File('/proc/self/cgroup').readAsStringSync();
    for (final line in const LineSplitter().convert(cgroup)) {
      if (!line.startsWith('0::')) continue;
      return appIdFromSystemdUnit(line.split('/').last) != null;
    }
  } catch (_) {
    // Unreadable: assume not.
  }
  return false;
}

/// The application ID in a systemd unit name that follows the desktop
/// naming convention (`app-[<launcher>-]<app ID>[-<random>].scope`, or
/// `app-[<launcher>-]<app ID>[@<random>].service`), or `null`. Valid IDs
/// have a dot, as `g_application_id_is_valid` requires.
@visibleForTesting
String? appIdFromSystemdUnit(String unit) {
  final match = RegExp(r'^app-(.+)\.(scope|service)$').firstMatch(unit);
  if (match == null) return null;
  var body = match[1]!;
  final at = body.indexOf('@');
  if (at >= 0) body = body.substring(0, at);
  final parts = body.split('-');
  if (parts.length > 1 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(parts.last)) {
    parts.removeLast();
  }
  if (parts.length > 1 && !parts.first.contains('.')) parts.removeAt(0);
  final id = parts.join('-');
  final valid = RegExp(
    r'^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)+$',
  );
  return valid.hasMatch(id) && id.length <= 255 ? id : null;
}

/// Linux: an idle inhibitor on the session bus while held, through the
/// Inhibit portal or `org.freedesktop.ScreenSaver` ([LinuxInhibitor],
/// [defaultLinuxInhibitors]).
///
/// Both are D-Bus calls through GLib's GDBus (`libgio-2.0`, which every
/// Flutter Linux app links through GTK), with `dart:ffi` and no plugin code.
/// The calls are synchronous on the calling isolate, as the Windows and
/// macOS backends' are (a call to a running service answers in a few
/// milliseconds), and give up after 2 s. On a helper isolate they would
/// leave work that fake-time widget tests can't finish.
/// The inhibitor belongs to the process's shared session-bus connection, so
/// it ends with the process even if it isn't released. On GNOME,
/// `busctl --user call org.gnome.SessionManager /org/gnome/SessionManager
/// org.gnome.SessionManager GetInhibitors` lists it while held.
class LinuxScreenAwakeBackend implements ScreenAwakeBackend {
  /// Creates the backend. [inhibitors] are tried in order (by default
  /// [defaultLinuxInhibitors]); tests may pass one alone.
  LinuxScreenAwakeBackend({
    @visibleForTesting List<LinuxInhibitor>? inhibitors,
    @visibleForTesting this.portalBusName = _portalBus,
  }) : inhibitors = inhibitors ?? defaultLinuxInhibitors();

  /// The inhibitors to try, in order.
  final List<LinuxInhibitor> inhibitors;

  /// The portal's bus name; tests name a missing one to check the fallback.
  final String portalBusName;

  _Hold? _hold;

  /// Which inhibitor holds the screen on now, or `null` while none does.
  LinuxInhibitor? get activeInhibitor => _hold?.kind;

  @override
  bool get supported => true;

  // The calls are synchronous, so changes can't interleave.
  @override
  Future<bool> setKeepAwake(bool on) async => on ? _take() : _letGo();

  bool _take() {
    if (_hold != null) return true;
    for (final kind in inhibitors) {
      final _InhibitResult result;
      try {
        final portalBus = portalBusName;
        result = _inhibit(kind, portalBus);
      } catch (error) {
        RealtimeLog.warning('screen awake: ${kind.name} failed', error: error);
        continue;
      }
      if (result.error case final error?) {
        RealtimeLog.info('screen awake: ${kind.name} unavailable ($error)');
        continue;
      }
      _hold = _Hold(kind, result.handle, result.cookie);
      return true;
    }
    RealtimeLog.warning('screen awake: no idle inhibitor answered');
    return false;
  }

  bool _letGo() {
    final hold = _hold;
    _hold = null;
    if (hold == null) return false;
    String? error;
    final portalBus = portalBusName;
    try {
      error = _uninhibit(hold.kind, hold.handle, hold.cookie, portalBus);
    } catch (e) {
      error = '$e';
    }
    if (error != null) {
      RealtimeLog.warning('screen awake: release failed', error: error);
    }
    return false;
  }

  @override
  Stream<bool> get changes => const Stream.empty();
}

final class _Hold {
  _Hold(this.kind, this.handle, this.cookie);

  final LinuxInhibitor kind;

  /// The portal's request object path.
  final String handle;

  /// The ScreenSaver cookie.
  final int cookie;
}

/// What an inhibit call returned: a portal handle or a ScreenSaver cookie,
/// or the error.
final class _InhibitResult {
  const _InhibitResult({this.handle = '', this.cookie = 0, this.error});

  final String handle;
  final int cookie;
  final String? error;
}

const _appName = 'cloudflare_realtime';
const _reason = 'Video call';

const _portalBus = 'org.freedesktop.portal.Desktop';
const _portalPath = '/org/freedesktop/portal/desktop';
const _portalInhibit = 'org.freedesktop.portal.Inhibit';
const _portalRequest = 'org.freedesktop.portal.Request';
// org.freedesktop.portal.Inhibit flags: 8 is Idle (the session going idle,
// which blanks or locks the screen and may suspend).
const _inhibitIdle = 8;

const _screenSaverBus = 'org.freedesktop.ScreenSaver';
const _screenSaverPath = '/org/freedesktop/ScreenSaver';
const _screenSaverInterface = 'org.freedesktop.ScreenSaver';

_InhibitResult _inhibit(LinuxInhibitor kind, String portalBus) {
  final GDBus bus;
  try {
    bus = GDBus.open();
  } catch (error) {
    return _InhibitResult(error: '$error');
  }
  return bus.withArena((arena) {
    switch (kind) {
      case LinuxInhibitor.portal:
        final reply = bus.call(
          arena,
          bus: portalBus,
          path: _portalPath,
          interface: _portalInhibit,
          method: 'Inhibit',
          parameters: bus.tuple([
            bus.string(''),
            bus.uint32(_inhibitIdle),
            bus.dictionary({'reason': bus.string(_reason)}),
          ]),
          replyType: '(o)',
        );
        if (reply.error case final error?) return _InhibitResult(error: error);
        return _InhibitResult(handle: bus.firstString(reply.value!));
      case LinuxInhibitor.screenSaver:
        final reply = bus.call(
          arena,
          bus: _screenSaverBus,
          path: _screenSaverPath,
          interface: _screenSaverInterface,
          method: 'Inhibit',
          parameters: bus.tuple([bus.string(_appName), bus.string(_reason)]),
          replyType: '(u)',
        );
        if (reply.error case final error?) return _InhibitResult(error: error);
        return _InhibitResult(cookie: bus.firstUint32(reply.value!));
    }
  });
}

// Returns the error, or null.
String? _uninhibit(
  LinuxInhibitor kind,
  String handle,
  int cookie,
  String portalBus,
) {
  final GDBus bus;
  try {
    bus = GDBus.open();
  } catch (error) {
    return '$error';
  }
  return bus.withArena((arena) {
    final reply = switch (kind) {
      LinuxInhibitor.portal => bus.call(
        arena,
        bus: portalBus,
        path: handle,
        interface: _portalRequest,
        method: 'Close',
        parameters: bus.tuple([]),
      ),
      LinuxInhibitor.screenSaver => bus.call(
        arena,
        bus: _screenSaverBus,
        path: _screenSaverPath,
        interface: _screenSaverInterface,
        method: 'UnInhibit',
        parameters: bus.tuple([bus.uint32(cookie)]),
      ),
    };
    return reply.error;
  });
}

// --- GDBus through dart:ffi ------------------------------------------------

typedef _GBusGetSyncNative =
    Pointer<Void> Function(Int32, Pointer<Void>, Pointer<Pointer<_GError>>);
typedef _GBusGetSync =
    Pointer<Void> Function(int, Pointer<Void>, Pointer<Pointer<_GError>>);
typedef _CallSyncNative =
    Pointer<Void> Function(
      Pointer<Void> connection,
      Pointer<Uint8> busName,
      Pointer<Uint8> objectPath,
      Pointer<Uint8> interfaceName,
      Pointer<Uint8> methodName,
      Pointer<Void> parameters,
      Pointer<Uint8> replyType,
      Int32 flags,
      Int32 timeoutMsec,
      Pointer<Void> cancellable,
      Pointer<Pointer<_GError>> error,
    );
typedef _CallSync =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      int,
      Pointer<Void>,
      Pointer<Pointer<_GError>>,
    );
typedef _NewStringNative = Pointer<Void> Function(Pointer<Uint8>);
typedef _NewUint32Native = Pointer<Void> Function(Uint32);
typedef _NewUint32 = Pointer<Void> Function(int);
typedef _NewVariantNative = Pointer<Void> Function(Pointer<Void>);
typedef _NewDictEntryNative =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _NewArrayNative =
    Pointer<Void> Function(Pointer<Uint8>, Pointer<Pointer<Void>>, Size);
typedef _NewArray =
    Pointer<Void> Function(Pointer<Uint8>, Pointer<Pointer<Void>>, int);
typedef _NewTupleNative = Pointer<Void> Function(Pointer<Pointer<Void>>, Size);
typedef _NewTuple = Pointer<Void> Function(Pointer<Pointer<Void>>, int);
typedef _GetChildNative = Pointer<Void> Function(Pointer<Void>, Size);
typedef _GetChild = Pointer<Void> Function(Pointer<Void>, int);
typedef _GetStringNative =
    Pointer<Uint8> Function(Pointer<Void>, Pointer<Size>);
typedef _GetUint32Native = Uint32 Function(Pointer<Void>);
typedef _GetUint32 = int Function(Pointer<Void>);
typedef _UnrefNative = Void Function(Pointer<Void>);
typedef _Unref = void Function(Pointer<Void>);
typedef _ErrorFreeNative = Void Function(Pointer<_GError>);
typedef _ErrorFree = void Function(Pointer<_GError>);
typedef _MallocNative = Pointer<Void> Function(Size);
typedef _Malloc = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);

final class _GError extends Struct {
  @Uint32()
  external int domain;

  @Int32()
  external int code;

  external Pointer<Uint8> message;
}

const _gBusTypeSession = 2;
const _callTimeoutMs = 2000;

/// A D-Bus reply: the value, or the error's message.
final class GDBusReply {
  const GDBusReply._(this.value, this.error);

  /// The reply's `GVariant`, owned by the arena; `null` on error.
  final Pointer<Void>? value;

  /// The error's message, or `null`.
  final String? error;
}

/// Synchronous calls on the session bus through GDBus (`libgio-2.0`), with
/// `GVariant` built from its typed constructors (no varargs). Internal: used
/// by [LinuxScreenAwakeBackend].
final class GDBus {
  GDBus._(DynamicLibrary gio, DynamicLibrary libc)
    : _busGetSync = gio.lookupFunction<_GBusGetSyncNative, _GBusGetSync>(
        'g_bus_get_sync',
      ),
      _callSync = gio.lookupFunction<_CallSyncNative, _CallSync>(
        'g_dbus_connection_call_sync',
      ),
      _newString = gio.lookupFunction<_NewStringNative, _NewStringNative>(
        'g_variant_new_string',
      ),
      _newUint32 = gio.lookupFunction<_NewUint32Native, _NewUint32>(
        'g_variant_new_uint32',
      ),
      _newVariant = gio.lookupFunction<_NewVariantNative, _NewVariantNative>(
        'g_variant_new_variant',
      ),
      _newDictEntry = gio
          .lookupFunction<_NewDictEntryNative, _NewDictEntryNative>(
            'g_variant_new_dict_entry',
          ),
      _newArray = gio.lookupFunction<_NewArrayNative, _NewArray>(
        'g_variant_new_array',
      ),
      _newTuple = gio.lookupFunction<_NewTupleNative, _NewTuple>(
        'g_variant_new_tuple',
      ),
      _getChild = gio.lookupFunction<_GetChildNative, _GetChild>(
        'g_variant_get_child_value',
      ),
      _getString = gio.lookupFunction<_GetStringNative, _GetStringNative>(
        'g_variant_get_string',
      ),
      _getUint32 = gio.lookupFunction<_GetUint32Native, _GetUint32>(
        'g_variant_get_uint32',
      ),
      _unref = gio.lookupFunction<_UnrefNative, _Unref>('g_variant_unref'),
      _refSink = gio.lookupFunction<_NewVariantNative, _NewVariantNative>(
        'g_variant_ref_sink',
      ),
      _errorFree = gio.lookupFunction<_ErrorFreeNative, _ErrorFree>(
        'g_error_free',
      ),
      _malloc = libc.lookupFunction<_MallocNative, _Malloc>('malloc'),
      _free = libc.lookupFunction<_FreeNative, _Free>('free');

  /// Opens `libgio-2.0.so.0` (GLib's symbols resolve through it). Throws
  /// where it isn't installed.
  factory GDBus.open() =>
      GDBus._(DynamicLibrary.open('libgio-2.0.so.0'), DynamicLibrary.process());

  final _GBusGetSync _busGetSync;
  final _CallSync _callSync;
  final _NewStringNative _newString;
  final _NewUint32 _newUint32;
  final _NewVariantNative _newVariant;
  final _NewDictEntryNative _newDictEntry;
  final _NewArray _newArray;
  final _NewTuple _newTuple;
  final _GetChild _getChild;
  final _GetStringNative _getString;
  final _GetUint32 _getUint32;
  final _Unref _unref;
  final _NewVariantNative _refSink;
  final _ErrorFree _errorFree;
  final _Malloc _malloc;
  final _Free _free;

  /// Runs [body] with an arena that frees its C strings and replies after.
  T withArena<T>(T Function(GDBusArena arena) body) {
    final arena = GDBusArena._(this);
    try {
      return body(arena);
    } finally {
      arena._release();
    }
  }

  /// A floating `s`. Floating values are consumed by the container or the
  /// call they are passed to.
  Pointer<Void> string(String value) {
    final c = _cString(value);
    try {
      return _newString(c);
    } finally {
      _free(c.cast());
    }
  }

  /// A floating `u`.
  Pointer<Void> uint32(int value) => _newUint32(value);

  /// A floating `a{sv}`.
  Pointer<Void> dictionary(Map<String, Pointer<Void>> entries) {
    final children = entries.entries
        .map((e) => _newDictEntry(string(e.key), _newVariant(e.value)))
        .toList();
    final type = _cString('{sv}');
    try {
      return _withArray(children, (array, n) => _newArray(type, array, n));
    } finally {
      _free(type.cast());
    }
  }

  /// A floating tuple of [children].
  Pointer<Void> tuple(List<Pointer<Void>> children) =>
      _withArray(children, _newTuple);

  /// The string in the first child of the tuple [value] (an `o` or an `s`).
  String firstString(Pointer<Void> value) {
    final child = _getChild(value, 0);
    try {
      final c = _getString(child, nullptr);
      return _fromCString(c);
    } finally {
      _unref(child);
    }
  }

  /// The `u` in the first child of the tuple [value].
  int firstUint32(Pointer<Void> value) {
    final child = _getChild(value, 0);
    try {
      return _getUint32(child);
    } finally {
      _unref(child);
    }
  }

  /// Calls [method] and waits for the reply, at most 2 s. [parameters] is
  /// a floating tuple, consumed by the call. A [replyType] that doesn't
  /// match the reply is an error.
  GDBusReply call(
    GDBusArena arena, {
    required String bus,
    required String path,
    required String interface,
    required String method,
    required Pointer<Void> parameters,
    String? replyType,
  }) {
    final error = arena._errorSlot();
    final connection = _busGetSync(_gBusTypeSession, nullptr, error);
    if (connection == nullptr) {
      // The call didn't consume the floating parameters: sink and drop them.
      _unref(_refSink(parameters));
      return GDBusReply._(null, arena._takeError(error) ?? 'no session bus');
    }
    // The shared session connection stays open for the process.
    final reply = _callSync(
      connection,
      arena._cString(bus),
      arena._cString(path),
      arena._cString(interface),
      arena._cString(method),
      parameters,
      replyType == null ? nullptr : arena._cString(replyType),
      0,
      _callTimeoutMs,
      nullptr,
      error,
    );
    if (reply == nullptr) {
      return GDBusReply._(null, arena._takeError(error) ?? 'no reply');
    }
    arena._variants.add(reply);
    return GDBusReply._(reply, null);
  }

  Pointer<Void> _withArray(
    List<Pointer<Void>> children,
    Pointer<Void> Function(Pointer<Pointer<Void>>, int) build,
  ) {
    final n = children.length;
    final array = _malloc(
      sizeOf<Pointer<Void>>() * (n == 0 ? 1 : n),
    ).cast<Pointer<Void>>();
    try {
      for (var i = 0; i < n; i++) {
        array[i] = children[i];
      }
      return build(array, n);
    } finally {
      _free(array.cast());
    }
  }

  Pointer<Uint8> _cString(String value) {
    final bytes = utf8.encode(value);
    final buffer = _malloc(bytes.length + 1).cast<Uint8>();
    buffer.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return buffer;
  }

  static String _fromCString(Pointer<Uint8> c) {
    if (c == nullptr) return '';
    var length = 0;
    while (c[length] != 0) {
      length++;
    }
    return utf8.decode(c.asTypedList(length), allowMalformed: true);
  }
}

/// The C memory of one [GDBus.withArena] body.
final class GDBusArena {
  GDBusArena._(this._bus);

  final GDBus _bus;
  final List<Pointer<Void>> _memory = [];
  final List<Pointer<Void>> _variants = [];

  Pointer<Uint8> _cString(String value) {
    final c = _bus._cString(value);
    _memory.add(c.cast());
    return c;
  }

  Pointer<Pointer<_GError>> _errorSlot() {
    final slot = _bus
        ._malloc(sizeOf<Pointer<_GError>>())
        .cast<Pointer<_GError>>();
    slot.value = nullptr;
    _memory.add(slot.cast());
    return slot;
  }

  String? _takeError(Pointer<Pointer<_GError>> slot) {
    final error = slot.value;
    if (error == nullptr) return null;
    slot.value = nullptr;
    final message = GDBus._fromCString(error.ref.message);
    _bus._errorFree(error);
    return message;
  }

  void _release() {
    for (final variant in _variants) {
      _bus._unref(variant);
    }
    _variants.clear();
    for (final pointer in _memory) {
      _bus._free(pointer);
    }
    _memory.clear();
  }
}
