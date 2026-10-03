// The session lifecycle, push/pull/update/close flows and their ordering are
// ported from partytracks' `PartyTracks.ts`, ISC License, Copyright 2024
// Sunil Pai. See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:convert' show LineSplitter;
import 'dart:math' as math;

import 'package:flutter_webrtc/flutter_webrtc.dart'
    show
        MediaStreamTrack,
        RTCIceConnectionState,
        RTCPeerConnectionState,
        RTCSignalingState,
        StatsReport;

import '../broker/broker_client.dart';
import '../broker/broker_exception.dart';
import '../broker/models/common.dart';
import '../broker/models/session.dart';
import '../broker/models/tracks.dart';
import '../data/data_channel_manager.dart';
import '../util/state_stream.dart';
import 'flutter_webrtc_peer_connection.dart';
import 'op_queue.dart';
import 'peer_connection.dart';
import 'publish_options.dart';
import 'sdp_repair.dart';
import 'sfu_session_events.dart';
import 'track_name.dart';

part 'track_publication.dart';

/// Options for [SfuSession.connect].
class SfuSessionOptions {
  /// Creates session options.
  const SfuSessionOptions({
    this.iceServers,
    this.correlationId,
    this.defaults = const SfuSessionDefaults(),
    this.iceDisconnectedTimeout = const Duration(seconds: 7),
    this.remoteTrackTimeout = const Duration(seconds: 5),
    this.layerUpdateRetryTimeout = const Duration(seconds: 10),
  });

  /// ICE servers to use instead of fetching them from the broker's
  /// `generate-ice-servers`, in `flutter_webrtc`'s format.
  final List<Map<String, dynamic>>? iceServers;

  /// A diagnostic label sent with `sessions/new`.
  final String? correlationId;

  /// Defaults for [PublishOptions].
  final SfuSessionDefaults defaults;

  /// How long the ICE connection may stay `disconnected` before the session
  /// reports [PeerConnectionFailureKind.iceDisconnectedTimeout]. partytracks
  /// uses 7 seconds. Null never times out.
  final Duration? iceDisconnectedTimeout;

  /// How long a pull waits for its transceiver to appear after
  /// renegotiation (partytracks: 5 seconds).
  final Duration remoteTrackTimeout;

  /// How long [SfuSession.setPreferredRid] keeps retrying while the SFU
  /// rejects the update because the track "is not configured for
  /// simulcast".
  ///
  /// The SFU answers so until it forwards the pulled track to this session,
  /// so a layer change right after a pull fails until media reaches the
  /// subscriber (a few hundred milliseconds in tests against the real SFU;
  /// `docs/design.md` §4.2). For a track published without simulcast the
  /// error is final, and it is thrown after this timeout. [Duration.zero]
  /// fails on the first rejection.
  final Duration layerUpdateRetryTimeout;
}

/// One peer connection to the Cloudflare SFU, bound to one SFU session.
///
/// A participant normally has one session that carries everything it
/// publishes and subscribes to (`docs/design.md` §4.2). Create one with
/// [connect]; every SFU call goes through the [BrokerClient].
///
/// All operations ([publish], [subscribe], [setPreferredRid], [unpublish],
/// [unsubscribe]) run through one serialized queue, because the SFU needs
/// each SDP exchange to finish before the next mutation. Pushes, pulls,
/// updates and closes that arrive in the same event-loop turn are batched
/// into one request each, as in partytracks. A failing operation fails only
/// its own tracks; the queue moves on.
///
/// The session doesn't reconnect by itself. When the SFU session is gone or
/// the peer connection fails, it reports an [SfuSessionFailure] on
/// [failures] and stops accepting operations. Recover by connecting a new
/// session and moving [LocalTrackPublication]s and
/// [RemoteTrackSubscription]s to it with [republish] and [resubscribe].
class SfuSession {
  SfuSession._({
    required BrokerClient broker,
    required this.sessionId,
    required PeerConnection peerConnection,
    required this.options,
  }) : _broker = broker,
       _pc = peerConnection {
    _pushes = BatchDispatcher(
      (batch) => _enqueue(batch, _runPushBatch, requireAlive: true),
    );
    _pulls = BatchDispatcher(
      (batch) => _enqueue(batch, _runPullBatch, requireAlive: true),
    );
    _updates = BatchDispatcher(
      (batch) => _enqueue(batch, _runUpdateBatch, requireAlive: true),
    );
    _closes = BatchDispatcher(
      (batch) => _enqueue(batch, _runCloseBatch, requireAlive: false),
    );
    _pcSubscriptions = [
      _pc.onConnectionState.listen(_onConnectionState),
      _pc.onIceConnectionState.listen(_onIceConnectionState),
    ];
  }

  /// Creates an SFU session and its peer connection.
  ///
  /// Requests `sessions/new` while it fetches the ICE servers (unless
  /// [SfuSessionOptions.iceServers] is set) and creates the peer connection
  /// with `bundlePolicy: max-bundle`. Nothing is negotiated until the first
  /// [publish], [subscribe] or [establishConnection].
  ///
  /// **The SFU expires a session whose peer connection never connected**,
  /// about ten seconds after `sessions/new` (later calls then fail with a
  /// `SessionGoneException`, HTTP 410). If the first publish may come later
  /// than that (a permission prompt, a screen-share picker), call
  /// [establishConnection] right after connecting. A `Room` does.
  ///
  /// Throws the broker's exception if either call fails, or the platform's
  /// if the peer connection can't be created; nothing is left open then.
  static Future<SfuSession> connect({
    required BrokerClient broker,
    SfuSessionOptions options = const SfuSessionOptions(),
  }) => connectSfuSession(broker: broker, options: options);

  final BrokerClient _broker;
  final PeerConnection _pc;

  /// This session's ID. Other participants pull its tracks by it, so share
  /// it through signaling.
  final String sessionId;

  /// The options the session was created with.
  final SfuSessionOptions options;

  final OpQueue _queue = OpQueue();
  late final BatchDispatcher<_PushItem> _pushes;
  late final BatchDispatcher<_PullItem> _pulls;
  late final BatchDispatcher<_UpdateItem> _updates;
  late final BatchDispatcher<_CloseItem> _closes;
  late final List<StreamSubscription<Object?>> _pcSubscriptions;

  final StateStream<SfuConnectionState> _connectionState = StateStream(
    SfuConnectionState.initial,
    distinct: true,
  );
  final StreamController<SfuSessionFailure> _failures =
      StreamController.broadcast(sync: true);
  SfuSessionFailure? _failure;
  bool _closed = false;
  RTCIceConnectionState? _iceState;
  Timer? _iceDisconnectedTimer;

  final Map<String, LocalTrackPublication> _publications = {};
  final Set<RemoteTrackSubscription> _subscriptions = {};

  /// DataChannels (M7), created on first use.
  DataChannelManager? _dataChannels;
  DataChannelManager get _data =>
      _dataChannels ??= DataChannelManager(SfuSessionPort._(this));

  /// The connection state, replaying the current value to each new
  /// listener. Completes after [close].
  Stream<SfuConnectionState> get connectionStateChanges => _connectionState.stream;

  /// The current connection state.
  SfuConnectionState get connectionState => _connectionState.value;

  /// Why the session failed, or null if it hasn't.
  SfuSessionFailure? get failure => _failure;

  /// Emits the session's failure, at most once, then completes. A listener
  /// that subscribes after the failure receives it immediately. Also
  /// completes on [close].
  Stream<SfuSessionFailure> get failures => Stream.multi((controller) {
    final failure = _failure;
    if (failure != null || _failures.isClosed) {
      if (failure != null) controller.add(failure);
      controller.close();
      return;
    }
    final subscription = _failures.stream.listen(
      controller.add,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Whether operations can still run: not closed and not failed.
  bool get isUsable => !_closed && _failure == null;

  /// Whether an SDP exchange has completed on this session (a push, a pull
  /// or [establishConnection]), so its peer connection has something to
  /// connect. Until then [connectionStateChanges] stays
  /// [SfuConnectionState.initial] and the SFU may expire the session.
  bool get hasNegotiated => _negotiated;
  bool _negotiated = false;

  /// The publications on this session, including ones still being pushed.
  List<LocalTrackPublication> get publications =>
      List.unmodifiable(_publications.values);

  /// The subscriptions on this session, including ones still being pulled.
  List<RemoteTrackSubscription> get subscriptions =>
      List.unmodifiable(_subscriptions);

  // ---------------------------------------------------------------------------
  // Public operations
  // ---------------------------------------------------------------------------

  /// Publishes [track] (push): adds a `sendonly` transceiver, sends the
  /// offer with `tracks/new`, and applies the SFU's answer.
  ///
  /// Video uses [PublishOptions.sendEncodings] or
  /// [SfuSessionDefaults.videoEncodings] (simulcast `a`/`b`/`c` by default).
  /// Codec preferences default to VP8 on every platform.
  ///
  /// Completes with the publication once the SFU accepted the track. Call
  /// [LocalTrackPublication.whenSending] before advertising it. Throws an
  /// [SfuTrackException] if the SFU rejected this track, or the broker's
  /// exception if the request failed. Nothing stays on the session then, so
  /// publishing again (even under the same name) is safe.
  Future<LocalTrackPublication> publish(
    MediaStreamTrack track, {
    PublishOptions options = const PublishOptions(),
  }) {
    final publication = _newPublication(track.kind, track, options);
    return _push(publication).then((_) => publication);
  }

  /// Publishes whatever [tracks] currently holds, following it from then on:
  /// each new track replaces the sent one without renegotiation, and null
  /// mutes (nothing is sent; the transceiver stays). [kind] (`audio` or
  /// `video`) fixes the transceiver's kind; values of another kind are
  /// ignored.
  ///
  /// Meant for a media source's track stream, for example
  /// `source.broadcastTrack.map((t) => t?.track)`. A stream that replays
  /// its current value (like the media layer's) is read before the push
  /// goes out; if it has no track yet, the push carries none and media
  /// starts with the first track.
  ///
  /// The publication stops following [tracks] when it closes. If the push
  /// fails, the publication is closed and the error thrown, as for
  /// [publish].
  Future<LocalTrackPublication> publishTrackStream(
    Stream<MediaStreamTrack?> tracks, {
    required String kind,
    PublishOptions options = const PublishOptions(),
  }) {
    final publication = _newPublication(kind, null, options);
    final pushed = _push(publication);
    publication._follow(tracks);
    return pushed.then(
      (_) => publication,
      onError: (Object error, StackTrace stackTrace) {
        // The caller never got the publication: stop following the source.
        publication._close();
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  LocalTrackPublication _newPublication(
    String? kind,
    MediaStreamTrack? track,
    PublishOptions options,
  ) {
    if (kind != 'audio' && kind != 'video') {
      throw ArgumentError.value(kind, 'kind', 'must be audio or video');
    }
    final trackName = options.trackName ?? generateTrackName();
    if (trackName.isEmpty) {
      throw ArgumentError.value(trackName, 'options.trackName', 'is empty');
    }
    final defaults = this.options.defaults;
    return LocalTrackPublication._(
      trackName: trackName,
      kind: kind!,
      track: track,
      sendEncodings: List.unmodifiable(
        options.sendEncodings ??
            (kind == 'video' ? defaults.videoEncodings : const []),
      ),
      codecPreferences: List.unmodifiable(
        options.codecPreferences ??
            (kind == 'video'
                ? defaults.videoCodecPreferences ??
                      defaultVideoCodecPreferences()
                : defaults.audioCodecPreferences),
      ),
    );
  }

  /// Pushes an existing [publication] to this session under the same
  /// [LocalTrackPublication.trackName], with its current track, encodings
  /// and codec preferences. Use it after the publication's previous session
  /// failed or closed, or to retry a failed push.
  ///
  /// Throws a [StateError] if the publication is closed or still on a
  /// session.
  Future<void> republish(LocalTrackPublication publication) {
    if (publication.state == SfuTrackState.closed) {
      throw StateError('The publication is closed.');
    }
    if (publication._session != null) {
      throw StateError(
        'The publication is still on a session. Unpublish it first.',
      );
    }
    return _push(publication);
  }

  Future<void> _push(LocalTrackPublication publication) {
    _throwIfUnusable();
    if (_publications.containsKey(publication.trackName)) {
      throw StateError(
        'A track named "${publication.trackName}" is already published on '
        'this session.',
      );
    }
    _publications[publication.trackName] = publication;
    publication._bind(this);
    final item = _PushItem(publication);
    _pushes.add(item);
    return item.done.future;
  }

  /// Subscribes to (pulls) the track [trackName] published by the session
  /// [remoteSessionId].
  ///
  /// For a simulcast track, pass [preferredRid] (`a` is the highest layer).
  /// [ridNotAvailable] defaults to [SimulcastOrdering.asciibetical], so the
  /// SFU falls back to another layer when the preferred one stops.
  /// [priorityOrdering] is left to the SFU default (`none`) unless given.
  /// Without [preferredRid], no simulcast preferences are sent.
  ///
  /// Completes once the track is pulled and its [MediaStreamTrack] is
  /// available. Throws an [SfuTrackException] if the SFU rejected this
  /// track, or the broker's exception if the request failed.
  Future<RemoteTrackSubscription> subscribe({
    required String remoteSessionId,
    required String trackName,
    String? preferredRid,
    SimulcastOrdering? priorityOrdering,
    SimulcastOrdering ridNotAvailable = SimulcastOrdering.asciibetical,
  }) {
    if (remoteSessionId.isEmpty || trackName.isEmpty) {
      throw ArgumentError('remoteSessionId and trackName must not be empty');
    }
    final subscription = RemoteTrackSubscription._(
      remoteSessionId: remoteSessionId,
      trackName: trackName,
      simulcast: preferredRid == null
          ? null
          : SimulcastOptions(
              preferredRid: preferredRid,
              priorityOrdering: priorityOrdering,
              ridNotAvailable: ridNotAvailable,
            ),
    );
    return _pull(subscription).then((_) => subscription);
  }

  /// Pulls an existing [subscription] on this session, from
  /// [remoteSessionId] if given (the publisher moved to a new session) or
  /// from its current [RemoteTrackSubscription.remoteSessionId]. Its
  /// [RemoteTrackSubscription.trackChanges] then emits the new track.
  ///
  /// Throws a [StateError] if the subscription is closed or still on a
  /// session.
  Future<void> resubscribe(
    RemoteTrackSubscription subscription, {
    String? remoteSessionId,
  }) {
    if (subscription.state == SfuTrackState.closed) {
      throw StateError('The subscription is closed.');
    }
    if (subscription._session != null) {
      throw StateError(
        'The subscription is still on a session. Unsubscribe it first.',
      );
    }
    if (remoteSessionId != null) {
      if (remoteSessionId.isEmpty) {
        throw ArgumentError.value(remoteSessionId, 'remoteSessionId');
      }
      subscription._remoteSessionId = remoteSessionId;
    }
    return _pull(subscription);
  }

  Future<void> _pull(RemoteTrackSubscription subscription) {
    _throwIfUnusable();
    _subscriptions.add(subscription);
    subscription._bind(this);
    final item = _PullItem(subscription);
    _pulls.add(item);
    return item.done.future;
  }

  /// Asks the SFU to forward simulcast layer [rid] of [subscription]
  /// (`tracks/update`), keeping its other simulcast preferences.
  ///
  /// Updates in the same event-loop turn go out in one request; for a
  /// subscription updated more than once, the last [rid] wins. Throws an
  /// [SfuTrackException] if the SFU rejected the update, and leaves
  /// [RemoteTrackSubscription.preferredRid] unchanged.
  ///
  /// Right after a pull, the SFU rejects layer changes until it forwards the
  /// track; such an update is retried for up to
  /// [SfuSessionOptions.layerUpdateRetryTimeout].
  Future<void> setPreferredRid(
    RemoteTrackSubscription subscription,
    String rid,
  ) {
    if (rid.isEmpty) throw ArgumentError.value(rid, 'rid', 'is empty');
    if (!identical(subscription._session, this)) {
      throw StateError('The subscription is not on this session.');
    }
    _throwIfUnusable();
    return _updateLayer(subscription, subscription._withRid(rid));
  }

  /// Sends [config] for [subscription] through the update queue, retrying
  /// while the SFU isn't forwarding the track yet (see
  /// [SfuSessionOptions.layerUpdateRetryTimeout]).
  ///
  /// A newer [setPreferredRid] for the same subscription supersedes a retry:
  /// this one then completes without sending again, as an earlier update in
  /// the same batch does.
  Future<void> _updateLayer(
    RemoteTrackSubscription subscription,
    SimulcastOptions config,
  ) async {
    final request = ++subscription._layerRequests;
    var waited = Duration.zero;
    var delay = _layerRetryFirstDelay;
    while (true) {
      final item = _UpdateItem(subscription, config);
      _updates.add(item);
      final SfuTrackException rejection;
      try {
        return await item.done.future;
      } on SfuTrackException catch (e) {
        if (!_isNotForwardingYet(e) ||
            waited >= options.layerUpdateRetryTimeout) {
          rethrow;
        }
        rejection = e;
      }
      await Future<void>.delayed(delay);
      waited += delay;
      delay = delay * 2 > _layerRetryMaxDelay ? _layerRetryMaxDelay : delay * 2;
      if (request != subscription._layerRequests) return; // Superseded.
      if (!isUsable ||
          !identical(subscription._session, this) ||
          subscription.state != SfuTrackState.active) {
        // Unsubscribed or moved meanwhile: this update no longer applies.
        throw rejection;
      }
    }
  }

  static const _layerRetryFirstDelay = Duration(milliseconds: 100);
  static const _layerRetryMaxDelay = Duration(seconds: 1);

  /// Whether [e] is the SFU's `tracks/update` answer for a pulled track it
  /// isn't forwarding yet: "The track is not configured for simulcast, no
  /// updates applicable." It gives the same answer for a track published
  /// without simulcast.
  static bool _isNotForwardingYet(SfuTrackException e) =>
      e.operation == 'tracks/update' &&
      e.errorCode == 'update_track_error' &&
      (e.errorDescription ?? '').contains('not configured for simulcast');

  /// Unpublishes [publication] (`tracks/close`): stops its transceiver,
  /// sends a new offer with the close request, and applies the answer.
  /// Unpublishes in the same event-loop turn share one request.
  ///
  /// The publication is [SfuTrackState.closed] afterwards, even if the
  /// request fails. The track itself isn't stopped. On a failed or closed
  /// session, only the local state changes.
  Future<void> unpublish(LocalTrackPublication publication) =>
      _close(_CloseItem.publication(publication));

  /// Unsubscribes [subscription] (`tracks/close`), like [unpublish].
  Future<void> unsubscribe(RemoteTrackSubscription subscription) =>
      _close(_CloseItem.subscription(subscription));

  Future<void> _close(_CloseItem item) {
    final owner = item.owner;
    if (owner == null) {
      item.closeLocally();
      return Future.value();
    }
    if (!identical(owner, this)) {
      throw StateError('The track is not on this session.');
    }
    if (!isUsable) {
      // Nothing to negotiate on a dead session.
      item.forget(this);
      item.closeLocally();
      return Future.value();
    }
    _closes.add(item);
    return item.done.future;
  }

  // ---------------------------------------------------------------------------
  // DataChannels (docs/design.md §9)
  // ---------------------------------------------------------------------------

  /// Publishes the DataChannel [name] from this session
  /// (`datachannels/new` with `location: local`), and opens the local end
  /// as a negotiated channel with the ID the SFU returns.
  ///
  /// The first DataChannel operation on a session sets up the SCTP
  /// transport first (`datachannels/establish`, answering the SFU's offer),
  /// inside the same queued operation.
  ///
  /// The SFU forwards what this side sends to every subscriber. Messages
  /// received on it are replies from the one subscriber that holds
  /// `canReply` ([DataChannelMessage.fromSessionId] is null for them).
  /// For general two-way traffic, both sides publish.
  ///
  /// Completes once the SFU accepted the channel; wait for
  /// [SfuDataChannel.whenOpen] before sending. Throws a
  /// [SfuDataChannelException] if the SFU rejected this channel, or the
  /// broker's exception if the request failed. Names are unique per session.
  Future<LocalDataChannel> publishDataChannel(
    String name, {
    DataChannelProfile profile = DataChannelProfile.reliable,
  }) => _data.publish(name, profile);

  /// Subscribes to the DataChannel [name] published by the session
  /// [remoteSessionId] (`datachannels/new` with `location: remote`).
  ///
  /// [profile] must match the publisher's: the SFU requires every
  /// subscriber to mirror the publisher's delivery policy.
  ///
  /// With [canReply], this subscriber can send back to the publisher on
  /// the channel. **Only one subscriber per published channel can reply**:
  /// granting it to another replaces this one. Change it later with
  /// [RemoteDataChannel.setCanReply].
  ///
  /// Every message received carries [DataChannelMessage.fromSessionId] =
  /// [remoteSessionId], taken from the channel, never from the payload.
  Future<RemoteDataChannel> subscribeDataChannel(
    String remoteSessionId,
    String name, {
    DataChannelProfile profile = DataChannelProfile.reliable,
    bool canReply = false,
  }) => _data.subscribe(remoteSessionId, name, profile, canReply);

  /// Publishes an existing [channel] on this session under the same name
  /// and profile, after its previous session failed or closed, or to retry
  /// a failed publish. Its [SfuDataChannel.messages] stream carries on.
  ///
  /// Throws a [StateError] if the channel is closed or still on a session.
  Future<void> republishDataChannel(LocalDataChannel channel) =>
      _data.republish(channel);

  /// Subscribes an existing [channel] on this session, from
  /// [remoteSessionId] if given (the publisher moved to a new session) or
  /// from its current [RemoteDataChannel.remoteSessionId].
  ///
  /// Throws a [StateError] if the channel is closed or still on a session.
  Future<void> resubscribeDataChannel(
    RemoteDataChannel channel, {
    String? remoteSessionId,
  }) => _data.resubscribe(channel, remoteSessionId: remoteSessionId);

  /// The DataChannels on this session, published and subscribed, including
  /// ones still being set up.
  List<SfuDataChannel> get dataChannels => _dataChannels?.channels ?? const [];

  /// Connects the peer connection now, before anything is published or
  /// subscribed, so the SFU keeps the session.
  ///
  /// The SFU expires a session whose peer connection never connected:
  /// about ten seconds after `sessions/new` (9 to 13 seconds observed),
  /// the next call fails with a `SessionGoneException` (HTTP 410). Nothing
  /// connects until the first SDP exchange, so a first publish that waits
  /// on a permission prompt or a screen-share picker fails. This sets up
  /// the session's DataChannel transport (`datachannels/establish`,
  /// answering the SFU's offer: one `application` m-line and no media),
  /// after which ICE and DTLS connect and the session stays. Later
  /// DataChannels use the same transport; publishing and subscribing work
  /// as before.
  ///
  /// Runs on the operation queue. Does nothing if something was negotiated
  /// already ([hasNegotiated]) or the transport is set up. Completes once
  /// the SFU's offer is answered, not when the peer connection connects
  /// (watch [connectionStateChanges]). Throws the broker's exception or an
  /// [SfuRequestException] if that fails; a `SessionGoneException` also
  /// fails the session, like any call.
  Future<void> establishConnection() {
    _throwIfUnusable();
    return _data.establishTransport();
  }

  /// The peer connection's WebRTC statistics (`getStats()`): every
  /// sender's and receiver's reports, such as `inbound-rtp` with
  /// `audioLevel`, `frameWidth` and `framesPerSecond`, or `outbound-rtp`
  /// per simulcast layer.
  ///
  /// Runs outside the operation queue, so it can be called at any time; it
  /// may fail briefly during renegotiation. Throws an
  /// [SfuSessionClosedException] after [close].
  Future<List<StatsReport>> getStats() {
    if (_closed) return Future.error(const SfuSessionClosedException());
    return _pc.getStats();
  }

  /// Closes the peer connection and releases the session.
  ///
  /// Queued operations fail with an [SfuSessionClosedException]. Active
  /// publications and subscriptions become [SfuTrackState.interrupted], so
  /// they can move to another session. Local tracks aren't stopped.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _iceDisconnectedTimer?.cancel();
    for (final s in _pcSubscriptions) {
      unawaited(s.cancel());
    }
    _detachAll(SfuTrackState.interrupted, const SfuSessionClosedException());
    _connectionState.set(SfuConnectionState.closed);
    await _connectionState.close();
    await _failures.close();
    _broker.forgetSession(sessionId);
    try {
      await _pc.close();
    } catch (_) {
      // Already closed, or the platform failed to close it: nothing to do.
    }
  }

  /// **Tests and demos only:** fails the session as if its peer connection
  /// had failed ([PeerConnectionFailureKind.simulated]), then closes the
  /// peer connection so media stops, as in a network drop.
  ///
  /// It exercises the real failure path: [failures] reports it,
  /// publications and subscriptions become [SfuTrackState.interrupted], and
  /// a `Room` replaces the session. Does nothing on a failed or closed
  /// session. Never needed in production code.
  void debugSimulateFailure() {
    if (!isUsable) return;
    _fail(const SfuPeerConnectionFailed(PeerConnectionFailureKind.simulated));
    unawaited(_pc.close().catchError((Object _) {}));
  }

  // ---------------------------------------------------------------------------
  // Queue plumbing
  // ---------------------------------------------------------------------------

  void _enqueue<T extends _OpItem>(
    List<T> batch,
    Future<void> Function(List<T> batch) run, {
    required bool requireAlive,
  }) {
    unawaited(
      _queue.schedule(() async {
        Object? error;
        StackTrace? stackTrace;
        try {
          if (requireAlive) _throwIfUnusable();
          // Heal anything a previous operation left half-negotiated.
          await _recoverSignaling();
          if (requireAlive) _throwIfUnusable();
          await run(batch);
        } catch (e, s) {
          error = e;
          stackTrace = s;
        }
        if (error != null) {
          // A failed exchange can leave `have-local-offer` or
          // `have-remote-offer` behind, which would reject the next one.
          await _recoverSignaling();
          // A platform error from a peer connection closed under the
          // operation reads better as "closed".
          final reported =
              _closed &&
                  error is! SfuSessionException &&
                  error is! BrokerException
              ? const SfuSessionClosedException()
              : error;
          for (final item in batch) {
            item.fail(this, reported, stackTrace);
          }
        } else {
          for (final item in batch) {
            item.fail(
              this,
              const SfuSessionException('the operation had no result'),
            );
          }
        }
        // Clean up inside the queue, so the next operation starts clean.
        for (final item in batch) {
          try {
            await item.cleanUp(this);
          } catch (_) {
            // Best effort.
          }
        }
        for (final item in batch) {
          item.settle();
        }
      }),
    );
  }

  /// Rolls back a half-finished SDP exchange so the signaling state is
  /// `stable` again. If that fails, the session is failed with
  /// [PeerConnectionFailureKind.signalingStuck] rather than left wedged.
  Future<void> _recoverSignaling() async {
    if (!isUsable) return;
    try {
      if (await _pc.signalingState() == _stable) return;
      await _pc.rollback();
      if (await _pc.signalingState() == _stable) return;
    } catch (_) {
      // Rollback unsupported or rejected: fall through.
    }
    _fail(
      const SfuPeerConnectionFailed(PeerConnectionFailureKind.signalingStuck),
    );
  }

  static const _stable = RTCSignalingState.RTCSignalingStateStable;

  void _throwIfUnusable() {
    if (_closed) throw const SfuSessionClosedException();
    final failure = _failure;
    if (failure != null) throw SfuSessionFailedException(failure);
  }

  /// Runs a broker call, turning a [SessionGoneException] into a session
  /// failure before rethrowing it.
  Future<T> _call<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on SessionGoneException catch (e) {
      _fail(SfuSessionGone(e));
      rethrow;
    }
  }

  /// Runs a broker call whose request names **other** sessions: a pull
  /// (`tracks/new` with remote tracks) or a DataChannel subscribe
  /// (`datachannels/new` with remote channels).
  ///
  /// A [SessionGoneException] from such a call may be about a publisher's
  /// expired session rather than this one: the broker maps a 410 or
  /// `session_error` to the session in the path, whatever the SFU meant. So
  /// this session is confirmed first ([_confirmAlive], `GET sessions/{id}`):
  ///
  /// - gone (or no longer ours): the session fails as with [_call], and the
  ///   original exception is rethrown;
  /// - alive, or unknown: a [RemoteSessionGoneException] is thrown, and the
  ///   caller fails only the batch's items, as per-item errors.
  Future<T> _callNamingRemotes<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on SessionGoneException catch (gone, stackTrace) {
      if (!await _confirmAlive()) {
        _fail(SfuSessionGone(gone));
        Error.throwWithStackTrace(gone, stackTrace);
      }
      _throwIfUnusable();
      throw RemoteSessionGoneException(gone);
    }
  }

  /// Asks the broker whether this session still exists, after a request
  /// that names other sessions was answered with "session gone".
  ///
  /// `false` when the session is closed or failed meanwhile, when the SFU
  /// reports it gone, or when the broker no longer lets us use it (403).
  /// Any other failure (network, timeout, 5xx) proves nothing either way:
  /// the session is kept, the batch's items fail on their own and are
  /// retried, and a real outage still shows on the peer connection.
  Future<bool> _confirmAlive() async {
    if (!isUsable) return false;
    try {
      final state = await _broker.getSessionState(sessionId);
      return state.errorCode != _sessionErrorCode;
    } on SessionGoneException {
      return false;
    } on BrokerForbiddenException {
      return false;
    } catch (_) {
      return true;
    }
  }

  static const _sessionErrorCode = 'session_error';

  // ---------------------------------------------------------------------------
  // Push
  // ---------------------------------------------------------------------------

  Future<void> _runPushBatch(List<_PushItem> batch) async {
    // Transceivers are added inside the queued operation (partytracks adds
    // them before queueing), so an unrelated offer in flight never carries
    // an undeclared m-line.
    final added = <_PushItem>[];
    for (final item in batch) {
      final publication = item.publication;
      if (!identical(publication._session, this)) {
        item.fail(this, const SfuSessionException('unpublished before push'));
        continue;
      }
      try {
        final track = publication.track;
        final transceiver = await _pc.addSendTransceiver(
          kind: publication.kind,
          track: track,
          sendEncodings: publication.kind == 'video'
              ? publication.sendEncodings
              : const [],
        );
        item.transceiver = transceiver;
        publication._transceiver = transceiver;
        if (!identical(publication.track, track)) {
          // replaceTrack() ran while the transceiver was being added.
          await transceiver.replaceTrack(publication.track);
        }
        if (publication.codecPreferences.isNotEmpty) {
          try {
            await transceiver.setCodecPreferences(
              publication.kind,
              publication.codecPreferences,
            );
          } catch (_) {
            // Not supported on this platform: keep the default order.
          }
        }
        added.add(item);
      } catch (error, stackTrace) {
        item.fail(this, error, stackTrace);
      }
    }
    if (added.isEmpty) return;
    _throwIfUnusable();

    final offer = await _pc.createOffer();
    await _pc.setLocalDescription(offer);
    final requested = <_PushItem>[];
    for (final item in added) {
      final mid = await item.transceiver!.mid();
      if (mid == null) {
        item.fail(
          this,
          const SfuSessionException('the transceiver has no mid'),
        );
      } else {
        item.mid = mid;
        requested.add(item);
      }
    }
    if (requested.isEmpty) return;

    final response = await _call(
      () => _broker.newTracks(
        sessionId,
        TracksRequest(
          sessionDescription: offer,
          tracks: [
            for (final item in requested)
              TrackObject.local(
                mid: item.mid!,
                trackName: item.publication.trackName,
              ),
          ],
        ),
      ),
    );
    _throwIfUnusable();
    _throwIfRequestError('tracks/new', response);
    final answer = response.sessionDescription;
    if (answer == null) {
      throw const SfuSessionException('tracks/new returned no answer');
    }
    await _setRemoteDescription(answer);
    _throwIfUnusable();

    final results = _TrackResults(response.tracks);
    for (final item in requested) {
      final publication = item.publication;
      final result =
          results.take((r) => r.mid == item.mid) ??
          results.take((r) => r.trackName == publication.trackName);
      if (result == null || result.hasError) {
        item.fail(
          this,
          SfuTrackException(
            operation: 'tracks/new',
            trackName: publication.trackName,
            errorCode: result?.errorCode,
            errorDescription: result?.errorDescription,
          ),
        );
        continue;
      }
      publication._activate(this, item.transceiver!, item.mid!);
      item.succeed();
    }
  }

  // ---------------------------------------------------------------------------
  // Pull
  // ---------------------------------------------------------------------------

  Future<void> _runPullBatch(List<_PullItem> batch) async {
    final requested = <_PullItem>[];
    for (final item in batch) {
      if (identical(item.subscription._session, this)) {
        requested.add(item);
      } else {
        item.fail(this, const SfuSessionException('unsubscribed before pull'));
      }
    }
    if (requested.isEmpty) return;

    final TracksResponse response;
    try {
      response = await _callNamingRemotes(
        () => _broker.newTracks(
          sessionId,
          TracksRequest(
            tracks: [
              for (final item in requested)
                TrackObject.remote(
                  sessionId: item.subscription.remoteSessionId,
                  trackName: item.subscription.trackName,
                  simulcast: item.subscription.simulcast,
                ),
            ],
          ),
        ),
      );
    } on RemoteSessionGoneException catch (e) {
      // A publisher's session is gone, not ours: fail just these pulls, as
      // per-track errors, so the Room's pull retries handle them.
      for (final item in requested) {
        item.fail(
          this,
          SfuTrackException(
            operation: 'tracks/new',
            trackName: item.subscription.trackName,
            errorCode: e.errorCode,
            errorDescription: e.errorDescription,
          ),
        );
      }
      return;
    }
    _throwIfUnusable();
    _throwIfRequestError('tracks/new', response);

    final results = _TrackResults(response.tracks);
    final pulled = <_PullItem>[];
    for (final item in requested) {
      final subscription = item.subscription;
      final result = results.take(
        (r) =>
            r.trackName == subscription.trackName &&
            (r.sessionId == null ||
                r.sessionId == subscription.remoteSessionId),
      );
      if (result == null || result.hasError || result.mid == null) {
        item.fail(
          this,
          SfuTrackException(
            operation: 'tracks/new',
            trackName: subscription.trackName,
            errorCode: result?.errorCode,
            errorDescription: result?.errorDescription,
          ),
        );
        continue;
      }
      item.mid = result.mid;
      pulled.add(item);
    }

    if (response.requiresImmediateRenegotiation) {
      await _renegotiate('tracks/new', response.sessionDescription);
      _throwIfUnusable();
    }

    for (final item in pulled) {
      final transceiver = await _pc.transceiverForMid(
        item.mid!,
        timeout: options.remoteTrackTimeout,
      );
      _throwIfUnusable();
      if (transceiver == null) {
        item.fail(
          this,
          SfuTrackException(
            operation: 'tracks/new',
            trackName: item.subscription.trackName,
            errorDescription: 'no transceiver for the returned mid',
          ),
        );
        continue;
      }
      item.subscription._activate(this, transceiver, item.mid!);
      item.succeed();
    }
  }

  /// Applies an SFU offer or answer, after repairing its RTX payload types
  /// against the local description ([repairRtxAssociations]): once the
  /// session has pulled a video, the SFU's answer to a later video push
  /// names an RTX `apt` the answer doesn't contain, which libwebrtc rejects.
  Future<void> _setRemoteDescription(SessionDescription description) async {
    final local = await _pc.localDescription();
    final sdp = repairRtxAssociations(description.sdp, localSdp: local?.sdp);
    await _pc.setRemoteDescription(
      identical(sdp, description.sdp)
          ? description
          : SessionDescription(type: description.type, sdp: sdp),
    );
    _negotiated = true;
  }

  /// Applies an SFU offer, answers it, and sends the answer with
  /// `renegotiate`.
  Future<void> _renegotiate(String operation, SessionDescription? offer) async {
    if (offer == null || offer.type != SdpType.offer) {
      throw SfuSessionException(
        '$operation asked for renegotiation without an offer',
      );
    }
    await _setRemoteDescription(offer);
    final answer = await _pc.createAnswer();
    await _pc.setLocalDescription(answer);
    _throwIfUnusable();
    final response = await _call(
      () => _broker.renegotiate(
        sessionId,
        RenegotiateRequest(sessionDescription: answer),
      ),
    );
    if (response.hasError) {
      throw SfuRequestException(
        operation: 'renegotiate',
        errorCode: response.errorCode!,
        errorDescription: response.errorDescription,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Update
  // ---------------------------------------------------------------------------

  Future<void> _runUpdateBatch(List<_UpdateItem> batch) async {
    // The last update per subscription wins; earlier ones share its result.
    final latest = <RemoteTrackSubscription, List<_UpdateItem>>{};
    for (final item in batch) {
      final subscription = item.subscription;
      if (subscription.state != SfuTrackState.active ||
          !identical(subscription._session, this)) {
        // Not pulled here (any more): remember the layer for the next pull.
        if (subscription.state != SfuTrackState.closed) {
          subscription._simulcast = item.config;
        }
        item.succeed();
        continue;
      }
      (latest[subscription] ??= []).add(item);
    }
    if (latest.isEmpty) return;

    final response = await _call(
      () => _broker.updateTracks(
        sessionId,
        UpdateTracksRequest(
          tracks: [
            for (final MapEntry(key: sub, value: items) in latest.entries)
              TrackObject.remote(
                sessionId: sub.remoteSessionId,
                trackName: sub.trackName,
                mid: sub.mid,
                simulcast: items.last.config,
              ),
          ],
        ),
      ),
    );
    _throwIfUnusable();
    _throwIfRequestError('tracks/update', response);
    if (response.requiresImmediateRenegotiation) {
      await _renegotiate('tracks/update', response.sessionDescription);
    }

    final results = _TrackResults(response.tracks);
    for (final MapEntry(key: sub, value: items) in latest.entries) {
      final result =
          results.take((r) => r.mid != null && r.mid == sub.mid) ??
          results.take((r) => r.trackName == sub.trackName);
      // The SFU may omit results for successful updates: only an explicit
      // error fails the update.
      if (result != null && result.hasError) {
        for (final item in items) {
          item.fail(
            this,
            SfuTrackException(
              operation: 'tracks/update',
              trackName: sub.trackName,
              errorCode: result.errorCode,
              errorDescription: result.errorDescription,
            ),
          );
        }
        continue;
      }
      sub._simulcast = items.last.config;
      for (final item in items) {
        item.succeed();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Close
  // ---------------------------------------------------------------------------

  Future<void> _runCloseBatch(List<_CloseItem> batch) async {
    final closing = <(_CloseItem, PeerTransceiver)>[];
    for (final item in batch) {
      final transceiver = item.transceiverOn(this);
      final mid = item.midOn(this);
      item.forget(this);
      item.closeLocally();
      if (transceiver == null || mid == null) {
        item.succeed(); // Never pushed or pulled here: nothing to close.
        continue;
      }
      item.mid = mid;
      closing.add((item, transceiver));
    }
    if (closing.isEmpty) return;
    if (!isUsable) {
      // As in partytracks, don't negotiate on a dead connection.
      for (final (item, transceiver) in closing) {
        await _stop(transceiver);
        item.succeed();
      }
      return;
    }

    // Rejecting every m-line of the session doesn't work: with
    // `max-bundle`, libwebrtc refuses the offer ("max-bundle configured but
    // session description has no BUNDLE group"), and with other policies
    // the transport closes and the SFU drops the session. So when these are
    // the session's last live m-lines, close them without negotiation
    // (`force`) and park their transceivers instead of stopping them: the
    // SFU stops forwarding, a parked sender sends nothing, and the m-lines
    // keep the transport up. See `docs/design.md` §4.2.
    final mids = {for (final (item, _) in closing) item.mid!};
    final live = _liveMids((await _pc.localDescription())?.sdp ?? '');
    final force = live.isNotEmpty && live.every(mids.contains);

    final TracksResponse response;
    if (force) {
      for (final (item, transceiver) in closing) {
        if (item.publication != null) await transceiver.replaceTrack(null);
      }
      response = await _call(
        () => _broker.closeTracks(
          sessionId,
          CloseTracksRequest(mids: mids.toList(), force: true),
        ),
      );
      _throwIfUnusable();
      _throwIfRequestError('tracks/close', response);
    } else {
      for (final (_, transceiver) in closing) {
        await _stop(transceiver);
      }
      final offer = await _pc.createOffer();
      await _pc.setLocalDescription(offer);
      response = await _call(
        () => _broker.closeTracks(
          sessionId,
          CloseTracksRequest(mids: mids.toList(), sessionDescription: offer),
        ),
      );
      _throwIfUnusable();
      _throwIfRequestError('tracks/close', response);
      final description = response.sessionDescription;
      if (description != null && description.type == SdpType.answer) {
        await _setRemoteDescription(description);
      } else if (response.requiresImmediateRenegotiation) {
        // The SFU answered our offer with an offer of its own: withdraw ours
        // (we are in `have-local-offer`) and answer theirs.
        await _pc.rollback();
        await _renegotiate('tracks/close', description);
      }
    }

    final results = _TrackResults(response.tracks);
    for (final (item, _) in closing) {
      final result = results.take((r) => r.mid == item.mid);
      // `close_track_error` means already closed: the goal is reached.
      if (result != null &&
          result.hasError &&
          result.errorCode != 'close_track_error') {
        item.fail(
          this,
          SfuTrackException(
            operation: 'tracks/close',
            trackName: item.trackName,
            errorCode: result.errorCode,
            errorDescription: result.errorDescription,
          ),
        );
      } else {
        item.succeed();
      }
    }
  }

  static Future<void> _stop(PeerTransceiver transceiver) async {
    try {
      await transceiver.stop();
    } catch (_) {
      // Already stopped.
    }
  }

  /// The `mid`s of the m-lines [sdp] doesn't reject (port other than 0).
  static Set<String> _liveMids(String sdp) {
    final live = <String>{};
    var rejected = true;
    for (final line in const LineSplitter().convert(sdp)) {
      if (line.startsWith('m=')) {
        final fields = line.split(' ');
        rejected = fields.length > 1 && fields[1] == '0';
      } else if (line.startsWith('a=mid:') && !rejected) {
        live.add(line.substring('a=mid:'.length).trim());
      }
    }
    return live;
  }

  void _throwIfRequestError(String operation, TracksResponse response) {
    if (response.hasError) {
      throw SfuRequestException(
        operation: operation,
        errorCode: response.errorCode!,
        errorDescription: response.errorDescription,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Connection state and failures
  // ---------------------------------------------------------------------------

  void _onConnectionState(RTCPeerConnectionState state) {
    if (_closed) return;
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _fail(
          const SfuPeerConnectionFailed(
            PeerConnectionFailureKind.connectionFailed,
          ),
        );
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _fail(
          const SfuPeerConnectionFailed(
            PeerConnectionFailureKind.closedUnexpectedly,
          ),
        );
      case _:
        if (_failure == null) _connectionState.set(_mapState(state));
    }
  }

  void _onIceConnectionState(RTCIceConnectionState state) {
    if (_closed) return;
    _iceState = state;
    _iceDisconnectedTimer?.cancel();
    _iceDisconnectedTimer = null;
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        _fail(
          const SfuPeerConnectionFailed(PeerConnectionFailureKind.iceFailed),
        );
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _fail(
          const SfuPeerConnectionFailed(
            PeerConnectionFailureKind.closedUnexpectedly,
          ),
        );
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        final timeout = options.iceDisconnectedTimeout;
        if (timeout == null) return;
        _iceDisconnectedTimer = Timer(timeout, () {
          if (_iceState ==
              RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
            _fail(
              const SfuPeerConnectionFailed(
                PeerConnectionFailureKind.iceDisconnectedTimeout,
              ),
            );
          }
        });
      case _:
        break;
    }
  }

  static SfuConnectionState _mapState(RTCPeerConnectionState state) =>
      switch (state) {
        RTCPeerConnectionState.RTCPeerConnectionStateNew =>
          SfuConnectionState.initial,
        RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
          SfuConnectionState.connecting,
        RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
          SfuConnectionState.connected,
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
          SfuConnectionState.disconnected,
        RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
          SfuConnectionState.failed,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
          SfuConnectionState.closed,
      };

  /// Marks the session dead, once.
  void _fail(SfuSessionFailure failure) {
    if (_closed || _failure != null) return;
    _failure = failure;
    _iceDisconnectedTimer?.cancel();
    _connectionState.set(SfuConnectionState.failed);
    _detachAll(SfuTrackState.interrupted, SfuSessionFailedException(failure));
    _failures.add(failure);
    unawaited(_failures.close());
  }

  void _detachAll(SfuTrackState state, Object error) {
    for (final publication in _publications.values.toList()) {
      publication._detach(this, state, error);
    }
    _publications.clear();
    for (final subscription in _subscriptions.toList()) {
      subscription._detach(this, state, error);
    }
    _subscriptions.clear();
    // DataChannels become interrupted, like tracks.
    _dataChannels?.detachAll(error);
  }

  @override
  String toString() =>
      'SfuSession($sessionId, ${connectionState.name}'
      '${_failure == null ? '' : ', $_failure'})';
}

/// A request that names other sessions (a pull, or a DataChannel
/// subscribe) was answered with "session gone", but this session is still
/// alive: the gone session is one of the publishers'.
///
/// Internal: not exported from the package barrel. The session catches it
/// and fails the request's items with per-item errors ([SfuTrackException],
/// `SfuDataChannelException`) carrying [errorCode].
class RemoteSessionGoneException implements Exception {
  /// Wraps the broker's [cause].
  const RemoteSessionGoneException(this.cause);

  /// The broker's exception, about the session in the request's path.
  final SessionGoneException cause;

  /// The per-item error code: the SFU's, or `session_error` (a bare 410).
  String get errorCode => cause.errorCode ?? SfuSession._sessionErrorCode;

  /// The per-item error description.
  String get errorDescription =>
      cause.errorDescription ?? 'a session named in the request is gone';

  @override
  String toString() => 'RemoteSessionGoneException($cause)';
}

/// The internal hooks that layers built on an [SfuSession] (DataChannels)
/// use to share its op queue, broker and peer connection.
///
/// Internal: not exported from the package barrel.
class SfuSessionPort {
  SfuSessionPort._(this.session);

  /// The session.
  final SfuSession session;

  /// The session's broker.
  BrokerClient get broker => session._broker;

  /// The session's peer connection.
  PeerConnection get peerConnection => session._pc;

  /// Whether operations can still run.
  bool get isUsable => session.isUsable;

  /// Throws an [SfuSessionClosedException] or [SfuSessionFailedException]
  /// if the session can't run operations.
  void throwIfUnusable() => session._throwIfUnusable();

  /// Runs a broker call, failing the session on a [SessionGoneException].
  Future<T> callBroker<T>(Future<T> Function() call) => session._call(call);

  /// Runs a broker call whose request names other sessions (remote
  /// DataChannels). On a [SessionGoneException], the session is confirmed
  /// first: it fails only if it is gone itself; otherwise a
  /// [RemoteSessionGoneException] is thrown, for the caller to fail the
  /// batch's items one by one.
  Future<T> callBrokerNamingRemotes<T>(Future<T> Function() call) =>
      session._callNamingRemotes(call);

  /// Applies an SFU [offer], answers it, and sends the answer with
  /// `renegotiate`.
  Future<void> renegotiate(String operation, SessionDescription? offer) =>
      session._renegotiate(operation, offer);

  /// Runs [task] on the session's serialized op queue, like the session's
  /// own operations: the signaling state is healed before it and after a
  /// failure. When [task] throws (or [requireAlive] and the session is
  /// unusable), [onError] is called inside the queue with the error, and
  /// the returned future still completes normally.
  Future<void> runQueued(
    Future<void> Function() task, {
    required void Function(Object error, StackTrace stackTrace) onError,
    bool requireAlive = true,
  }) => session._queue.schedule(() async {
    try {
      if (requireAlive) session._throwIfUnusable();
      await session._recoverSignaling();
      if (requireAlive) session._throwIfUnusable();
      await task();
    } catch (error, stackTrace) {
      await session._recoverSignaling();
      final reported =
          session._closed &&
              error is! SfuSessionException &&
              error is! BrokerException
          ? const SfuSessionClosedException()
          : error;
      onError(reported, stackTrace);
    }
  });
}

/// [SfuSession.connect] with an injectable [PeerConnectionFactory].
///
/// Internal: not exported from the package barrel. Tests and higher layers
/// (such as `Room`) use it to substitute a fake peer connection.
Future<SfuSession> connectSfuSession({
  required BrokerClient broker,
  SfuSessionOptions options = const SfuSessionOptions(),
  PeerConnectionFactory createPeerConnection =
      createFlutterWebrtcPeerConnection,
}) async {
  // Two chains at once: `sessions/new`, and the ICE servers followed by the
  // peer connection. partytracks requests the session and the ICE servers
  // together (`forkJoin`) and creates the peer connection after both; here
  // the peer connection doesn't wait for `sessions/new`, because
  // flutter_webrtc's first `createPeerConnection` can take seconds on a
  // loaded machine, and the SFU expires a session whose peer connection
  // hasn't connected (docs/design.md §4.2, Connect).
  final configuredIceServers = options.iceServers;
  final NewSessionResponse session;
  final PeerConnection peerConnection;
  try {
    (session, peerConnection) = await (
      broker.newSession(
        NewSessionRequest(correlationId: options.correlationId),
      ),
      (configuredIceServers == null
              ? broker.getIceServers()
              : Future.value(configuredIceServers))
          .then(
            (iceServers) => createPeerConnection({
              'iceServers': iceServers,
              'bundlePolicy': 'max-bundle',
              'sdpSemantics': 'unified-plan',
            }),
          ),
    ).wait;
  } on ParallelWaitError<
    (NewSessionResponse?, PeerConnection?),
    (AsyncError?, AsyncError?)
  > catch (e) {
    // `wait` lets both chains finish, so whatever one of them created is
    // released here: nothing leaks when the other fails.
    final created = e.values.$1;
    if (created != null) broker.forgetSession(created.sessionId);
    final opened = e.values.$2;
    if (opened != null) await _closeQuietly(opened);
    final error = e.errors.$1 ?? e.errors.$2!;
    Error.throwWithStackTrace(error.error, error.stackTrace);
  }

  if (session.hasError) {
    broker.forgetSession(session.sessionId);
    await _closeQuietly(peerConnection);
    throw SfuRequestException(
      operation: 'sessions/new',
      errorCode: session.errorCode!,
      errorDescription: session.errorDescription,
    );
  }
  return SfuSession._(
    broker: broker,
    sessionId: session.sessionId,
    peerConnection: peerConnection,
    options: options,
  );
}

Future<void> _closeQuietly(PeerConnection peerConnection) async {
  try {
    await peerConnection.close();
  } catch (_) {
    // Never used: nothing else to release.
  }
}

// -----------------------------------------------------------------------------
// Queue items
// -----------------------------------------------------------------------------

/// One queued request. Its outcome is decided during the operation
/// ([succeed] or [fail]); [done] completes only at [settle], after the
/// queue has cleaned up, so callers see a consistent peer connection.
abstract class _OpItem {
  final Completer<void> done = Completer<void>();
  bool _succeeded = false;
  Object? _error;
  StackTrace? _stackTrace;

  bool get isPending => !_succeeded && _error == null;

  bool get failed => _error != null;

  void succeed() {
    if (isPending) _succeeded = true;
  }

  void fail(SfuSession session, Object error, [StackTrace? stackTrace]) {
    if (!isPending) return;
    _error = error;
    _stackTrace = stackTrace;
    onFailed(session, error);
  }

  /// Updates local state after a failure. Runs synchronously in [fail].
  void onFailed(SfuSession session, Object error) {}

  /// Releases peer-connection resources after the operation, inside the
  /// queue and before [settle].
  Future<void> cleanUp(SfuSession session) async {}

  void settle() {
    if (done.isCompleted) return;
    final error = _error;
    if (error != null) {
      done.completeError(error, _stackTrace);
    } else {
      done.complete();
    }
  }
}

class _PushItem extends _OpItem {
  _PushItem(this.publication);

  final LocalTrackPublication publication;
  PeerTransceiver? transceiver;
  String? mid;

  @override
  Future<void> cleanUp(SfuSession session) async {
    final t = transceiver;
    if (!failed || t == null || !session.isUsable) return;
    // A stopped transceiver is left out of later offers (or rejected with
    // port 0 if it was negotiated), so it never sends again. A retry with
    // `republish` adds a fresh one.
    await t.stop();
  }

  @override
  void onFailed(SfuSession session, Object error) {
    if (identical(publication._session, session)) {
      session._publications.remove(publication.trackName);
      publication._detach(session, SfuTrackState.failed, error);
    }
  }
}

class _PullItem extends _OpItem {
  _PullItem(this.subscription);

  final RemoteTrackSubscription subscription;
  String? mid;

  @override
  void onFailed(SfuSession session, Object error) {
    if (identical(subscription._session, session)) {
      session._subscriptions.remove(subscription);
      subscription._detach(session, SfuTrackState.failed, error);
    }
  }
}

class _UpdateItem extends _OpItem {
  _UpdateItem(this.subscription, this.config);

  final RemoteTrackSubscription subscription;
  final SimulcastOptions config;
}

class _CloseItem extends _OpItem {
  _CloseItem.publication(LocalTrackPublication this.publication)
    : subscription = null;

  _CloseItem.subscription(RemoteTrackSubscription this.subscription)
    : publication = null;

  final LocalTrackPublication? publication;
  final RemoteTrackSubscription? subscription;
  String? mid;

  String get trackName => publication?.trackName ?? subscription!.trackName;

  SfuSession? get owner => publication?._session ?? subscription?._session;

  PeerTransceiver? transceiverOn(SfuSession session) {
    if (!identical(owner, session)) return null;
    return publication?._transceiver ?? subscription?._transceiver;
  }

  String? midOn(SfuSession session) {
    if (!identical(owner, session)) return null;
    return publication?._mid ?? subscription?._mid;
  }

  /// Removes the track from [session]'s bookkeeping.
  void forget(SfuSession session) {
    final p = publication;
    if (p != null && identical(p._session, session)) {
      session._publications.remove(p.trackName);
    }
    final s = subscription;
    if (s != null && identical(s._session, session)) {
      session._subscriptions.remove(s);
    }
  }

  void closeLocally() {
    publication?._close();
    subscription?._close();
  }
}

/// Matches track results to requests, using each result at most once.
class _TrackResults {
  _TrackResults(List<TrackResult> results) : _remaining = [...results];

  final List<TrackResult> _remaining;

  TrackResult? take(bool Function(TrackResult result) test) {
    final index = _remaining.indexWhere(test);
    if (index < 0) return null;
    return _remaining.removeAt(index);
  }
}
