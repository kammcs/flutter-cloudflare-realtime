import 'dart:ffi';
import 'dart:io' show Platform;

typedef _SetThreadExecutionStateNative = Uint32 Function(Uint32);
typedef _SetThreadExecutionState = int Function(int);
typedef _CallNtPowerInformationNative = Int32 Function(
  Int32,
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
  Uint32,
);
typedef _CallNtPowerInformation = int Function(
  int,
  Pointer<Void>,
  int,
  Pointer<Uint32>,
  int,
);
typedef _CoTaskMemAllocNative = Pointer<Void> Function(IntPtr);
typedef _CoTaskMemAlloc = Pointer<Void> Function(int);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void>);
typedef _CoTaskMemFree = void Function(Pointer<Void>);

const _systemExecutionState = 16;

/// The execution state (`ES_*` flags) of this thread and of the system, or
/// `null` off Windows.
///
/// - `thread`: `SetThreadExecutionState(0)`, which changes nothing and
///   returns the calling thread's state. Integration tests run on the root
///   isolate, the thread the package sets it from.
/// - `system`: `CallNtPowerInformation(SystemExecutionState)`, every
///   process's requests combined (what `powercfg /requests` lists, which
///   needs an elevated prompt); `-1` when it can't be read.
({int thread, int system})? readWindowsExecutionState() {
  if (!Platform.isWindows) return null;
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setThreadExecutionState = kernel32
      .lookupFunction<_SetThreadExecutionStateNative, _SetThreadExecutionState>(
        'SetThreadExecutionState',
      );
  final thread = setThreadExecutionState(0);

  final powrprof = DynamicLibrary.open('powrprof.dll');
  final callNtPowerInformation = powrprof
      .lookupFunction<_CallNtPowerInformationNative, _CallNtPowerInformation>(
        'CallNtPowerInformation',
      );
  final ole32 = DynamicLibrary.open('ole32.dll');
  final alloc = ole32.lookupFunction<_CoTaskMemAllocNative, _CoTaskMemAlloc>(
    'CoTaskMemAlloc',
  );
  final free = ole32.lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFree>(
    'CoTaskMemFree',
  );
  final out = alloc(sizeOf<Uint32>()).cast<Uint32>();
  try {
    final status = callNtPowerInformation(
      _systemExecutionState,
      nullptr,
      0,
      out,
      sizeOf<Uint32>(),
    );
    return (thread: thread, system: status == 0 ? out.value : -1);
  } finally {
    free(out.cast());
  }
}
