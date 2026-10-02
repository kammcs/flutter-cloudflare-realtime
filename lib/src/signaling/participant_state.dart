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

/// The simulcast layers a published video track sends: a hint for
/// subscribers choosing a layer (`docs/design.md` §6).
///
/// [rids] lists the encodings highest first (`a`, `b`, `c` by default).
/// [width] and [height] are the size of the highest layer, and
/// [scaleDownBy] each layer's `scaleResolutionDownBy`, in the order of
/// [rids]. A room announces the size it captures (portrait on a phone held
/// upright), and announces it again when it changes (M12); older clients
/// announced the size they asked for.
///
/// ## Wire shape
///
/// ```json
/// {"rids": ["a", "b", "c"], "width": 1280, "height": 720, "scaleDownBy": [1, 2, 4]}
/// ```
///
/// Only `rids` is required. [SimulcastInfo.fromJson] is tolerant: this is a
/// hint, so malformed input reads as `null` (no hint) rather than failing
/// the whole participant state.
@immutable
class SimulcastInfo {
  /// Creates a simulcast description.
  ///
  /// [rids] must not be empty. When given, [scaleDownBy] has one entry per
  /// rid.
  SimulcastInfo({
    required List<String> rids,
    this.width,
    this.height,
    List<double>? scaleDownBy,
  }) : assert(rids.isNotEmpty, 'rids must not be empty'),
       assert(
         scaleDownBy == null || scaleDownBy.length == rids.length,
         'scaleDownBy needs one entry per rid',
       ),
       rids = List.unmodifiable(rids),
       scaleDownBy = scaleDownBy == null
           ? null
           : List.unmodifiable(scaleDownBy);

  /// Parses the wire shape written by [toJson], or returns `null` if [json]
  /// isn't a usable simulcast description.
  static SimulcastInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final rids = json['rids'];
    if (rids is! List || rids.isEmpty || rids.any((r) => r is! String)) {
      return null;
    }
    int? positive(Object? value) =>
        value is num && value.isFinite && value > 0 ? value.round() : null;
    List<double>? scales;
    final rawScales = json['scaleDownBy'];
    if (rawScales is List &&
        rawScales.length == rids.length &&
        rawScales.every((s) => s is num && s.isFinite && s >= 1)) {
      scales = [for (final s in rawScales) (s as num).toDouble()];
    }
    return SimulcastInfo(
      rids: rids.cast<String>(),
      width: positive(json['width']),
      height: positive(json['height']),
      scaleDownBy: scales,
    );
  }

  /// The encodings' RIDs, highest layer first.
  final List<String> rids;

  /// The highest layer's width in pixels, if known.
  final int? width;

  /// The highest layer's height in pixels, if known.
  final int? height;

  /// Each layer's `scaleResolutionDownBy`, in the order of [rids]. `null`
  /// means the package's convention: 1, 2, 4, ...
  final List<double>? scaleDownBy;

  /// The wire shape documented on [SimulcastInfo].
  Map<String, Object?> toJson() => {
    'rids': rids,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (scaleDownBy != null)
      'scaleDownBy': [
        for (final s in scaleDownBy!)
          if (s == s.roundToDouble()) s.toInt() else s,
      ],
  };

  @override
  bool operator ==(Object other) =>
      other is SimulcastInfo &&
      listEquals(other.rids, rids) &&
      other.width == width &&
      other.height == height &&
      listEquals(other.scaleDownBy, scaleDownBy);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(rids),
    width,
    height,
    scaleDownBy == null ? null : Object.hashAll(scaleDownBy!),
  );

  @override
  String toString() =>
      'SimulcastInfo(${rids.join(',')}'
      '${height == null ? '' : ', ${width ?? '?'}x$height'})';
}

/// Describes one track a participant publishes to the SFU.
///
/// Participants learn what to pull from each other's [TrackInfo]s: the key it
/// sits under in [ParticipantState.tracks] is the SFU `trackName`, and
/// [ParticipantState.sessionId] is the session to pull it from.
///
/// Two optional fields help subscribers; peers that don't know them keep
/// working:
///
/// - [muted]: the publisher isn't sending media for the track right now. The
///   track stays published, so unmuting needs no new pull.
/// - [simulcast]: the layers a simulcast video track sends. Subscribers ask
///   for a layer (`preferredRid`) only when it is set.
@immutable
class TrackInfo {
  /// Creates a track description.
  const TrackInfo({
    required this.kind,
    required this.source,
    this.muted = false,
    this.simulcast,
  });

  /// Parses the wire shape written by [toJson].
  ///
  /// Throws a [FormatException] if `kind` is missing or unknown. An unknown
  /// `source` becomes [TrackSource.custom]; a missing one is an error.
  /// `muted` and `simulcast` are optional and read tolerantly: anything but
  /// `true` is not muted, and a malformed `simulcast` is ignored.
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
      muted: json['muted'] == true,
      simulcast: SimulcastInfo.fromJson(json['simulcast']),
    );
  }

  /// Whether this is an audio or a video track.
  final TrackKind kind;

  /// What the track captures.
  final TrackSource source;

  /// Whether the publisher is currently not sending media for this track.
  final bool muted;

  /// The simulcast layers the track sends, or `null` for a track sent as a
  /// single encoding (and for audio).
  final SimulcastInfo? simulcast;

  /// The wire shape: `{"kind": "video", "source": "camera"}`, plus
  /// `"muted": true` while muted and a `"simulcast"` object for simulcast
  /// video. Both are omitted when not set.
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'source': source.name,
    if (muted) 'muted': true,
    if (simulcast != null) 'simulcast': simulcast!.toJson(),
  };

  /// Returns a copy with the given fields replaced. Set [clearSimulcast] to
  /// remove [simulcast]; it takes precedence.
  TrackInfo copyWith({
    TrackKind? kind,
    TrackSource? source,
    bool? muted,
    SimulcastInfo? simulcast,
    bool clearSimulcast = false,
  }) => TrackInfo(
    kind: kind ?? this.kind,
    source: source ?? this.source,
    muted: muted ?? this.muted,
    simulcast: clearSimulcast ? null : (simulcast ?? this.simulcast),
  );

  @override
  bool operator ==(Object other) =>
      other is TrackInfo &&
      other.kind == kind &&
      other.source == source &&
      other.muted == muted &&
      other.simulcast == simulcast;

  @override
  int get hashCode => Object.hash(kind, source, muted, simulcast);

  @override
  String toString() =>
      'TrackInfo(${kind.name}, ${source.name}'
      '${muted ? ', muted' : ''}${simulcast == null ? '' : ', $simulcast'})';
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
///     "cam-9f2c": {
///       "kind": "video",
///       "source": "camera",
///       "simulcast": {"rids": ["a", "b", "c"], "width": 1280, "height": 720}
///     },
///     "mic-1b7e": {"kind": "audio", "source": "microphone", "muted": true}
///   },
///   "metadata": {"displayName": "Ada"},
///   "layerDemand": {"camera-77aa": "c"}
/// }
/// ```
///
/// - `participantId` (string, required).
/// - `sessionId` (string or `null`): `null` until the participant has an SFU
///   session. It changes when the session is replaced, for example after a
///   reconnection.
/// - `tracks` (object, required, may be empty): SFU `trackName` to
///   [TrackInfo]: `kind` and `source` (required), `muted` (optional,
///   omitted when `false`) and `simulcast` (optional, see
///   [SimulcastInfo]).
/// - `metadata` (object, optional): omitted when [metadata] is `null`.
/// - `layerDemand` (object, optional): the simulcast layer this participant
///   pulls of other participants' tracks, as SFU `trackName` to RID (see
///   [layerDemand]). Omitted when [layerDemand] is `null`.
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
    Map<String, String>? layerDemand,
  }) : tracks = Map.unmodifiable(tracks),
       metadata = metadata == null ? null : Map.unmodifiable(metadata),
       layerDemand = layerDemand == null ? null : Map.unmodifiable(layerDemand);

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
      layerDemand: _layerDemandFromJson(json['layerDemand']),
    );
  }

  // Tolerant, like [SimulcastInfo.fromJson]: a malformed value reads as
  // "not reported", which publishers treat as wanting every layer.
  static Map<String, String>? _layerDemandFromJson(Object? json) {
    if (json is! Map) return null;
    final demand = <String, String>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (key is! String || value is! String || value.isEmpty) return null;
      demand[key] = value;
    }
    return demand;
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

  /// The simulcast layer this participant pulls of other participants'
  /// video tracks: SFU `trackName` to the RID it asks for (the highest
  /// layer it wants), or `null` if the participant doesn't report it.
  ///
  /// Publishers use it to stop encoding layers that no one pulls
  /// (`docs/design.md` §6.2). A reported map lists every simulcast track
  /// the participant pulls or is about to pull; a track that isn't listed
  /// isn't pulled. `null` (an older client, or one that turned reporting
  /// off) counts as pulling every layer of every track. The room names
  /// tracks `<source>-<uuid>`, so the names are unique across publishers
  /// and the map isn't keyed by publisher.
  final Map<String, String>? layerDemand;

  /// The wire shape documented on [ParticipantState].
  Map<String, Object?> toJson() => {
    'participantId': participantId,
    'sessionId': sessionId,
    'tracks': {
      for (final MapEntry(:key, :value) in tracks.entries) key: value.toJson(),
    },
    if (metadata != null) 'metadata': metadata,
    if (layerDemand != null) 'layerDemand': layerDemand,
  };

  /// Returns a copy with the given fields replaced.
  ///
  /// Set [clearSessionId], [clearMetadata] or [clearLayerDemand] to reset
  /// those fields to `null`; they take precedence over [sessionId],
  /// [metadata] and [layerDemand].
  ParticipantState copyWith({
    String? participantId,
    String? sessionId,
    bool clearSessionId = false,
    Map<String, TrackInfo>? tracks,
    Map<String, Object?>? metadata,
    bool clearMetadata = false,
    Map<String, String>? layerDemand,
    bool clearLayerDemand = false,
  }) => ParticipantState(
    participantId: participantId ?? this.participantId,
    sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
    tracks: tracks ?? this.tracks,
    metadata: clearMetadata ? null : (metadata ?? this.metadata),
    layerDemand: clearLayerDemand ? null : (layerDemand ?? this.layerDemand),
  );

  /// Value equality. [metadata] is compared deeply.
  @override
  bool operator ==(Object other) =>
      other is ParticipantState &&
      other.participantId == participantId &&
      other.sessionId == sessionId &&
      mapEquals(other.tracks, tracks) &&
      _deepEquality.equals(other.metadata, metadata) &&
      mapEquals(other.layerDemand, layerDemand);

  @override
  int get hashCode => Object.hash(
    participantId,
    sessionId,
    Object.hashAllUnordered(
      tracks.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    _deepEquality.hash(metadata),
    layerDemand == null
        ? null
        : Object.hashAllUnordered(
            layerDemand!.entries.map((e) => Object.hash(e.key, e.value)),
          ),
  );

  @override
  String toString() =>
      'ParticipantState($participantId, session: $sessionId, '
      'tracks: $tracks${metadata == null ? '' : ', metadata: $metadata'}'
      '${layerDemand == null ? '' : ', layerDemand: $layerDemand'})';
}
