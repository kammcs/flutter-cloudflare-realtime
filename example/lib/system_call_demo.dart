import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether this platform has a system call UI (CallKit, Android Telecom):
/// phones. Elsewhere the package keeps calls in Dart only.
bool get systemCallsAvailable =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

const _permissions = MethodChannel('example/permissions');

/// Sets system calls up (docs/design.md §4.8), with what Android asks of the
/// host app: the notification permission (13+), for the call's notification,
/// and the full-screen intent (14+), for an incoming call over the lock
/// screen; when the latter isn't granted, the user is sent to its settings
/// page once. Completes with [SystemCalls.isSupported].
Future<bool> prepareSystemCalls() async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      await _permissions.invokeMethod<void>('requestNotifications');
      if (!(await _permissions.invokeMethod<bool>('canUseFullScreenIntent') ??
              true) &&
          !_askedFullScreen) {
        _askedFullScreen = true;
        await _permissions.invokeMethod<void>('openFullScreenIntentSettings');
      }
    } catch (_) {
      // Best effort: the call still works, without a full-screen ring.
    }
  }
  return SystemCalls.instance.configure();
}

bool _askedFullScreen = false;

/// Begins a UIKit background task on iOS, so Dart keeps running for a
/// while (about 30 s) after the app leaves the foreground, and completes
/// with the function that ends it (safe to call more than once). Elsewhere,
/// or if iOS refuses, it does nothing.
///
/// The example's stand-in for a VoIP push: it keeps **Simulate incoming
/// call**'s delay running on a locked iPhone, and the join of a call
/// answered from the lock screen. The native side is the `example/
/// background_task` channel in `example/ios/Runner/AppDelegate.swift`.
Future<Future<void> Function()> beginBackgroundTask(String name) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return _noTask;
  int? id;
  try {
    id = await _backgroundTask.invokeMethod<int>('begin', {'name': name});
  } catch (_) {
    // Best effort: without it, the work waits for the app to come back.
  }
  if (id == null) return _noTask;
  var ended = false;
  return () async {
    if (ended) return;
    ended = true;
    try {
      await _backgroundTask.invokeMethod<void>('end', {'id': id});
    } catch (_) {
      // The task expired, and its handler ended it.
    }
  };
}

const _backgroundTask = MethodChannel('example/background_task');

Future<void> _noTask() async {}

/// Shows the ringing [call] in the app too, with Answer and Decline, and
/// completes with whether it was answered: here, in the system's UI (the
/// lock screen, the notification, a headset, a watch), or not at all (it
/// ended).
///
/// The outcome comes from the call, not from the dialog: on a locked iPhone
/// the app is in the background, where Flutter builds no widgets (no
/// frames) until it comes back, so the dialog isn't even built while the
/// call is answered or declined on the lock screen. The dialog goes once the
/// call stops ringing.
Future<bool> showIncomingCall(BuildContext context, SystemCall call) async {
  final navigator = Navigator.of(context);
  // stateChanges replays the current state; it closes once the call ends.
  final outcome = Completer<SystemCallState>();
  final subscription = call.stateChanges.listen(
    (state) {
      if (state != SystemCallState.ringing && !outcome.isCompleted) {
        outcome.complete(state);
      }
    },
    onDone: () {
      if (!outcome.isCompleted) outcome.complete(SystemCallState.ended);
    },
  );
  final dialog = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    builder: (_) => _IncomingCallDialog(call: call),
  );
  unawaited(navigator.push(dialog));
  final state = await outcome.future;
  unawaited(subscription.cancel());
  if (dialog.isActive) navigator.removeRoute(dialog);
  return state != SystemCallState.ended;
}

class _IncomingCallDialog extends StatelessWidget {
  const _IncomingCallDialog({required this.call});

  final SystemCall call;

  Future<void> _try(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(call.isVideo ? Icons.videocam : Icons.ring_volume),
      title: Text(call.displayName ?? call.handle.value),
      content: const Text(
        'Incoming call. Answer here, or in the notification or on the lock '
        'screen.',
      ),
      actions: [
        TextButton(
          onPressed: () => _try(context, call.end),
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: () => _try(context, call.answer),
          child: const Text('Answer'),
        ),
      ],
    );
  }
}

/// Holds and resumes [call] from the call screen.
class SystemCallHoldButton extends StatelessWidget {
  const SystemCallHoldButton({super.key, required this.call});

  final SystemCall call;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SystemCallState>(
      stream: call.stateChanges,
      initialData: call.state,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final held = state == SystemCallState.held;
        final canHold = held || state == SystemCallState.active;
        return IconButton(
          tooltip: held ? 'Resume the call' : 'Hold the call',
          icon: Icon(held ? Icons.play_circle : Icons.pause_circle),
          onPressed: canHold
              ? () => call.setHeld(!held).catchError((Object e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('$e')));
                  }
                })
              : null,
        );
      },
    );
  }
}
