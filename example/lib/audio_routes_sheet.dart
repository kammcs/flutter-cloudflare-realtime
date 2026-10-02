import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Asks for Android's BLUETOOTH_CONNECT, without which Bluetooth headsets
/// aren't listed as audio routes on Android 12+. Best effort.
Future<void> requestBluetoothPermission() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await const MethodChannel('example/permissions')
        .invokeMethod<void>('requestBluetoothConnect');
  } catch (_) {
    // Not fatal: Bluetooth routes are just missing.
  }
}

/// The icon for [kind].
IconData audioRouteIcon(AudioRouteKind? kind) => switch (kind) {
  AudioRouteKind.speaker => Icons.volume_up,
  AudioRouteKind.earpiece => Icons.phone_in_talk,
  AudioRouteKind.wiredHeadset => Icons.headset,
  AudioRouteKind.bluetooth => Icons.bluetooth_audio,
  AudioRouteKind.usb => Icons.usb,
  AudioRouteKind.other || null => Icons.speaker_group,
};

/// What to call [route] in the UI.
String audioRouteLabel(AudioRoute route) => switch (route.kind) {
  AudioRouteKind.speaker => 'Speaker',
  AudioRouteKind.earpiece => 'Phone',
  _ when route.name.isNotEmpty => route.name,
  AudioRouteKind.wiredHeadset => 'Headset',
  AudioRouteKind.bluetooth => 'Bluetooth',
  AudioRouteKind.usb => 'USB audio',
  AudioRouteKind.other => 'Other',
};

/// A sheet listing the room's audio routes, the current one checked.
Future<void> showAudioRoutesSheet(BuildContext context, Room room) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: StreamBuilder<List<AudioRoute>>(
          stream: room.audioRoutes,
          initialData: room.currentAudioRoutes,
          builder: (context, routes) => StreamBuilder<AudioRoute?>(
            stream: room.audioRouteChanges,
            initialData: room.currentAudioRoute,
            builder: (context, current) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final route in routes.data ?? const <AudioRoute>[])
                  ListTile(
                    leading: Icon(audioRouteIcon(route.kind)),
                    title: Text(audioRouteLabel(route)),
                    trailing: route.id == current.data?.id
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () async {
                      Navigator.of(context).pop();
                      try {
                        await room.selectAudioRoute(route);
                      } on AudioRouteUnavailableException {
                        // The list updates itself; nothing else to do.
                      }
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
