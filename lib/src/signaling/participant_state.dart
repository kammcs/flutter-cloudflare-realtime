/// @docImport 'signaling.dart';
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// The media kind of a published track.
enum TrackKind {
  /// An audio track.
  audio,

  /// A video track.
  video,
}

/// What a published track captures.
///
/// Serialized by [name]. Unknown names read from the wire become [custom],
/// so newer peers can add sources without breaking older ones.
enum TrackSource {
  /// A camera.
  camera,

  /// A microphone.
  microphone,

  /// A screen, window or browser tab share (video).
  screen,

  /// Audio captured alongside a screen share.
  screenAudio,

  /// Anything else the app publishes.
  custom,
}

/// Describes one track a participant publishes to the SFU.
///
/// Participants learn what to pull from each other's [TrackInfo]s: the key it
/// sits under in [ParticipantState.tracks] is the SFU `trackName`, and
/// [ParticipantState.sessionId] is the session to pull it from.
@immutable
class TrackInfo {
  /// Creates a track description.
  const TrackInfo({required this.kind, required this.source});

  /// Parses the wire shape written by [toJson].
  ///
  /// Throws a [FormatException] if `kind` is missing or unknown. An unknown
  /// `source` becomes [TrackSource.custom]; a missing one is an error.
  factory TrackInfo.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    final source = json['source'];
    if (kind is! String || source is! String) {
      throw FormatException(
        'TrackInfo needs string "kind" and "source" fields.',
        json,
      );
    }
    final parsedKind = TrackKind.values.asNameMap()[kind];
    if (parsedKind == null) {
      throw FormatException('Unknown track kind "$kind".', json);
    }
    return TrackInfo(
      kind: parsedKind,
      source: TrackSource.values.asNameMap()[source] ?? TrackSource.custom,
    );
  }

  /// Whether this is an audio or a video track.
  final TrackKind kind;

  /// What the track captures.
  final TrackSource source;

  /// The wire shape: `{"kind": "video", "source": "camera"}`.
  Map<String, Object?> toJson() => {'kind': kind.name, 'source': source.name};

  /// Returns a copy with the given fields replaced.
  TrackInfo copyWith({TrackKind? kind, TrackSource? source}) =>
      TrackInfo(kind: kind ?? this.kind, source: source ?? this.source);

  @override
  bool operator ==(Object other) =>
      other is TrackInfo && other.kind == kind && other.source == source;

  @override
  int get hashCode => Object.hash(kind, source);

  @override
  String toString() => 'TrackInfo(${kind.name}, ${source.name})';
}

const DeepCollectionEquality _deepEquality = DeepCollectionEquality();

/// What one participant tells the others through [Signaling].
///
/// This is the payload a signaling adapter carries, for example as a presence
/// payload. The package reads remote participants' states to decide what to
/// pull, and publishes the local participant's state as it changes.
///
/// ## Wire shape
///
/// [toJson] and [fromJson] use this JSON object, which adapters should store
/// as-is:
///
/// ```json
/// {
///   "participantId": "user-123:device-a",
///   "sessionId": "2a45a4d8...",
///   "tracks": {
///     "cam-9f2c": {"kind": "video", "source": "camera"},
///     "mic-1b7e": {"kind": "audio", "source": "microphone"}
///   },
///   "metadata": {"displayName": "Ada"}
/// }
/// ```
///
/// - `participantId` (string, required).
/// - `sessionId` (string or `null`): `null` until the participant has an SFU
///   session. It changes when the session is replaced, for example after a
///   reconnection.
/// - `tracks` (object, required, may be empty): SFU `trackName` to
///   [TrackInfo].
/// - `metadata` (object, optional): omitted when [metadata] is `null`.
///
/// Readers ignore unknown keys, so later versions can add fields.
@immutable
class ParticipantState {
  /// Creates a participant state.
  ///
  /// [tracks] and [metadata] are copied into unmodifiable maps.
  ParticipantState({
    required this.participantId,
    this.sessionId,
    Map<String, TrackInfo> tracks = const {},
    Map<String, Object?>? metadata,
  }) : tracks = Map.unmodifiable(tracks),
       metadata = metadata == null ? null : Map.unmodifiable(metadata);

  /// Parses the wire shape written by [toJson].
  ///
  /// Throws a [FormatException] if the input doesn't match it.
  factory ParticipantState.fromJson(Map<String, Object?> json) {
    final participantId = json['participantId'];
    if (participantId is! String) {
      throw FormatException(
        'ParticipantState needs a string "participantId".',
        json,
      );
    }
    final sessionId = switch (json['sessionId']) {
      null => null,
      final String id => id,
      _ => throw FormatException('"sessionId" must be a string or null.', json),
    };
    final tracks = json['tracks'];
    if (tracks is! Map) {
      throw FormatException('"tracks" must be an object.', json);
    }
    final metadata = switch (json['metadata']) {
      null => null,
      final Map map => map,
      _ => throw FormatException(
        '"metadata" must be an object or absent.',
        json,
      ),
    };
    return ParticipantState(
      participantId: participantId,
      sessionId: sessionId,
      tracks: {
        for (final MapEntry(:key, :value) in tracks.entries)
          _stringKey(key, json): _trackFromJson(value, json),
      },
      metadata: metadata == null
          ? null
          : {
              for (final MapEntry(:key, :value) in metadata.entries)
                _stringKey(key, json): value,
            },
    );
  }

  static String _stringKey(Object? key, Object source) {
    if (key is String) return key;
    throw FormatException('Object keys must be strings.', source);
  }

  static TrackInfo _trackFromJson(Object? value, Object source) {
    if (value is! Map) {
      throw FormatException('Each track must be an object.', source);
    }
    return TrackInfo.fromJson({
      for (final MapEntry(:key, :value) in value.entries)
        _stringKey(key, source): value,
    });
  }

  /// Identifies the participant within a room.
  ///
  /// Must be unique per connection in a room. If one user may join from
  /// several devices, include a device or connection ID.
  final String participantId;

  /// The participant's current SFU session, or `null` before it has one.
  final String? sessionId;

  /// The tracks this participant publishes, keyed by SFU `trackName`.
  final Map<String, TrackInfo> tracks;

  /// Free-form, JSON-encodable app data, such as a display name.
  ///
  /// The package doesn't read it. Keep it small: signaling transports often
  /// limit payload sizes.
  final Map<String, Object?>? metadata;

  /// The wire shape documented on [ParticipantState].
  Map<String, Object?> toJson() => {
    'participantId': participantId,
    'sessionId': sessionId,
    'tracks': {
      for (final MapEntry(:key, :value) in tracks.entries) key: value.toJson(),
    },
    if (metadata != null) 'metadata': metadata,
  };

  /// Returns a copy with the given fields replaced.
  ///
  /// Set [clearSessionId] or [clearMetadata] to reset those fields to `null`;
  /// they take precedence over [sessionId] and [metadata].
  ParticipantState copyWith({
    String? participantId,
    String? sessionId,
    bool clearSessionId = false,
    Map<String, TrackInfo>? tracks,
    Map<String, Object?>? metadata,
    bool clearMetadata = false,
  }) => ParticipantState(
    participantId: participantId ?? this.participantId,
    sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
    tracks: tracks ?? this.tracks,
    metadata: clearMetadata ? null : (metadata ?? this.metadata),
  );

  /// Value equality. [metadata] is compared deeply.
  @override
  bool operator ==(Object other) =>
      other is ParticipantState &&
      other.participantId == participantId &&
      other.sessionId == sessionId &&
      mapEquals(other.tracks, tracks) &&
      _deepEquality.equals(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(
    participantId,
    sessionId,
    Object.hashAllUnordered(
      tracks.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    _deepEquality.hash(metadata),
  );

  @override
  String toString() =>
      'ParticipantState($participantId, session: $sessionId, '
      'tracks: $tracks${metadata == null ? '' : ', metadata: $metadata'})';
}
