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

/// Shows the ringing [call] in the app too, with Answer and Decline, and
/// completes with whether it was answered: here, in the system's UI (the
/// notification, a headset, a watch), or not at all.
Future<bool> showIncomingCall(BuildContext context, SystemCall call) async {
  final answered = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _IncomingCallDialog(call: call),
  );
  return answered ?? false;
}

class _IncomingCallDialog extends StatefulWidget {
  const _IncomingCallDialog({required this.call});

  final SystemCall call;

  @override
  State<_IncomingCallDialog> createState() => _IncomingCallDialogState();
}

class _IncomingCallDialogState extends State<_IncomingCallDialog> {
  late final StreamSubscription<SystemCallState> _state;

  @override
  void initState() {
    super.initState();
    // Answered or ended anywhere: the dialog goes.
    _state = widget.call.stateChanges.listen((state) {
      if (state == SystemCallState.ringing || !mounted) return;
      Navigator.of(context).pop(state != SystemCallState.ended);
    });
  }

  @override
  void dispose() {
    _state.cancel();
    super.dispose();
  }

  Future<void> _try(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    return AlertDialog(
      icon: Icon(call.isVideo ? Icons.videocam : Icons.ring_volume),
      title: Text(call.displayName ?? call.handle.value),
      content: const Text(
        'Incoming call. Answer here, or in the notification or on the lock '
        'screen.',
      ),
      actions: [
        TextButton(
          onPressed: () => _try(call.end),
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: () => _try(call.answer),
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
