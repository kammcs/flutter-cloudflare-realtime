// DataChannels over the Cloudflare SFU (docs/design.md §9).
//
// partytracks has no DataChannel support to port. The negotiation sequence
// follows Cloudflare's DataChannels docs and OpenAPI schema; the batching,
// queueing and lifecycle mirror this package's track code, which is ported
// from partytracks (see THIRD_PARTY_NOTICES.md).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCDataChannelMessage, RTCDataChannelState;

import '../broker/models/common.dart';
import '../broker/models/data_channels.dart';
import '../session/op_queue.dart';
import '../session/peer_connection.dart';
import '../session/sfu_session.dart';
import '../session/sfu_session_events.dart';
import '../util/state_stream.dart';

part 'data_channel_message.dart';
part 'data_channel_profile.dart';
part 'sfu_data_channel.dart';

/// Runs one [SfuSession]'s DataChannel operations.
///
/// Every operation goes through the session's op queue. Publishes,
/// subscribes, `canReply` updates and closes that arrive in the same
/// event-loop turn are each batched into one request. The first publish or
/// subscribe on the session sets up the SCTP transport first
/// (`datachannels/establish`, answering the SFU's offer).
///
/// Internal: not exported from the package barrel. The public API is on
/// [SfuSession] and the channel objects.
class DataChannelManager {
  /// Creates the manager for the session behind [port].
  DataChannelManager(this._port) {
    _publishes = BatchDispatcher((batch) => _enqueue(batch, _runPublishBatch));
    _subscribes = BatchDispatcher(
      (batch) => _enqueue(batch, _runSubscribeBatch),
    );
    _updates = BatchDispatcher((batch) => _enqueue(batch, _runUpdateBatch));
    _closes = BatchDispatcher(
      (batch) => _enqueue(batch, _runCloseBatch, requireAlive: false),
    );
  }

  final SfuSessionPort _port;
  late final BatchDispatcher<_NewItem> _publishes;
  late final BatchDispatcher<_NewItem> _subscribes;
  late final BatchDispatcher<_UpdateItem> _updates;
  late final BatchDispatcher<_CloseItem> _closes;

  final Map<String, LocalDataChannel> _published = {};
  final Map<(String, String), RemoteDataChannel> _subscribed = {};
  bool _established = false;

  /// The session.
  SfuSession get session => _port.session;

  String get _sessionId => _port.session.sessionId;

  /// Whether `datachannels/establish` has completed on this session.
  bool get isEstablished => _established;

  /// The channels on the session, published first.
  List<SfuDataChannel> get channels =>
      List.unmodifiable([..._published.values, ..._subscribed.values]);

  // ---------------------------------------------------------------------------
  // Operations
  // ---------------------------------------------------------------------------

  /// See [SfuSession.publishDataChannel].
  Future<LocalDataChannel> publish(String name, DataChannelProfile profile) {
    _checkName(name);
    final channel = LocalDataChannel._(name, profile);
    return _publish(channel).then((_) => channel);
  }

  /// See [SfuSession.republishDataChannel].
  Future<void> republish(LocalDataChannel channel) {
    _checkMovable(channel);
    return _publish(channel);
  }

  Future<void> _publish(LocalDataChannel channel) {
    _port.throwIfUnusable();
    if (_published.containsKey(channel.name)) {
      throw StateError(
        'A data channel named "${channel.name}" is already published on '
        'this session.',
      );
    }
    _published[channel.name] = channel;
    channel._bind(this);
    final item = _NewItem(channel);
    _publishes.add(item);
    return item.done.future;
  }

  /// See [SfuSession.subscribeDataChannel].
  Future<RemoteDataChannel> subscribe(
    String remoteSessionId,
    String name,
    DataChannelProfile profile,
    bool canReply,
  ) {
    if (remoteSessionId.isEmpty) {
      throw ArgumentError.value(remoteSessionId, 'remoteSessionId', 'is empty');
    }
    _checkName(name);
    final channel = RemoteDataChannel._(
      remoteSessionId: remoteSessionId,
      name: name,
      profile: profile,
      canReply: canReply,
    );

    return _subscribe(channel, remoteSessionId).then((_) => channel);
  }

  /// See [SfuSession.resubscribeDataChannel].
  Future<void> resubscribe(
    RemoteDataChannel channel, {
    String? remoteSessionId,
  }) {
    _checkMovable(channel);
    if (remoteSessionId != null && remoteSessionId.isEmpty) {
      throw ArgumentError.value(remoteSessionId, 'remoteSessionId', 'is empty');
    }
    return _subscribe(channel, remoteSessionId ?? channel.remoteSessionId);
  }

  Future<void> _subscribe(RemoteDataChannel channel, String remoteSessionId) {
    _port.throwIfUnusable();
    final key = (remoteSessionId, channel.name);
    if (_subscribed.containsKey(key)) {
      throw StateError(
        'This session already subscribes to "${channel.name}" from that '
        'session.',
      );
    }
    channel._remoteSessionId = remoteSessionId;
    _subscribed[key] = channel;
    channel._bind(this);
    final item = _NewItem(channel);
    _subscribes.add(item);
    return item.done.future;
  }

  /// See [RemoteDataChannel.setCanReply].
  Future<void> setCanReply(RemoteDataChannel channel, bool canReply) {
    _port.throwIfUnusable();
    final item = _UpdateItem(channel, canReply);
    _updates.add(item);
    return item.done.future;
  }

  /// See [SfuDataChannel.close].
  Future<void> close(SfuDataChannel channel) {
    final id = channel._id;
    _forget(channel);
    channel._closeLocally();
    // Not set up yet: an in-flight publish or subscribe notices and
    // releases the SFU's channel itself.
    if (id == null || !_port.isUsable) return Future.value();
    final item = _CloseItem(id, channel.name);
    _closes.add(item);
    return item.done.future;
  }

  /// Interrupts every channel: the session failed or closed.
  void detachAll(Object error) {
    for (final channel in channels) {
      channel._detach(SfuDataChannelState.interrupted, error);
    }
    _published.clear();
    _subscribed.clear();
  }

  /// The underlying channel of [channel] closed without [close]: the SFU
  /// (or the other end) dropped it.
  void _lost(SfuDataChannel channel) {
    final id = channel._id;
    _forget(channel);
    channel._detach(
      SfuDataChannelState.interrupted,
      const SfuSessionException('the data channel closed'),
    );
    if (id == null || !_port.isUsable) return;
    // Release the SFU's side too, best effort.
    final item = _CloseItem(id, channel.name);
    _closes.add(item);
    unawaited(item.done.future.catchError((Object _) {}));
  }

  void _forget(SfuDataChannel channel) {
    switch (channel) {
      case LocalDataChannel():
        if (identical(_published[channel.name], channel)) {
          _published.remove(channel.name);
        }
      case RemoteDataChannel():
        final key = (channel.remoteSessionId, channel.name);
        if (identical(_subscribed[key], channel)) _subscribed.remove(key);
    }
  }

  static void _checkName(String name) {
    if (name.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
    if (name == EstablishDataChannelsRequest.serverEventsChannelName) {
      throw ArgumentError.value(name, 'name', 'is reserved by the SFU');
    }
  }

  static void _checkMovable(SfuDataChannel channel) {
    if (channel.state == SfuDataChannelState.closed) {
      throw StateError('The data channel is closed.');
    }
    if (channel._manager != null) {
      throw StateError('The data channel is still on a session.');
    }
  }

  // ---------------------------------------------------------------------------
  // Queue plumbing
  // ---------------------------------------------------------------------------

  void _enqueue<T extends _DataChannelItem>(
    List<T> batch,
    Future<void> Function(List<T> batch) run, {
    bool requireAlive = true,
  }) {
    unawaited(
      _port
          .runQueued(
            () => run(batch),
            requireAlive: requireAlive,
            onError: (error, stackTrace) {
              for (final item in batch) {
                item.fail(this, error, stackTrace);
              }
            },
          )
          .then((_) {
            for (final item in batch) {
              item
                ..fail(
                  this,
                  const SfuSessionException('the operation had no result'),
                )
                ..settle();
            }
          }),
    );
  }

  /// See [SfuSession.establishConnection]: sets up the transport now, on
  /// the queue, unless something was negotiated on the session already.
  Future<void> establishTransport() {
    final done = Completer<void>();
    unawaited(
      _port.runQueued(
        () async {
          if (!_port.session.hasNegotiated) await _establish();
          done.complete();
        },
        onError: (error, stackTrace) {
          if (!done.isCompleted) done.completeError(error, stackTrace);
        },
      ),
    );
    return done.future;
  }

  /// Sets up the SCTP transport, once per session.
  ///
  /// `datachannels/establish` is sent without an offer, so no local channel
  /// has to exist first: the SFU offers an `application` m-line (and the
  /// `server-events` channel, ID 0, which it opens in-band), and the answer
  /// goes back through `renegotiate`. Cloudflare's `echo-datachannels`
  /// example does the same.
  Future<void> _establish() async {
    if (_established) return;
    final response = await _port.callBroker(
      () => _port.broker.establishDataChannels(
        _sessionId,
        EstablishDataChannelsRequest(),
      ),
    );
    _port.throwIfUnusable();
    if (response.hasError) {
      throw SfuRequestException(
        operation: 'datachannels/establish',
        errorCode: response.errorCode!,
        errorDescription: response.errorDescription,
      );
    }
    final description = response.sessionDescription;
    if (response.requiresImmediateRenegotiation ||
        description?.type == SdpType.offer) {
      await _port.renegotiate('datachannels/establish', description);
      _port.throwIfUnusable();
    } else if (description != null) {
      throw const SfuSessionException(
        'datachannels/establish returned an answer to no offer',
      );
    }
    _established = true;
  }

  // ---------------------------------------------------------------------------
  // Publish and subscribe
  // ---------------------------------------------------------------------------

  Future<void> _runPublishBatch(List<_NewItem> batch) async {
    final requested = _stillBound(batch, 'publish');
    if (requested.isEmpty) return;
    await _establish();
    final response = await _port.callBroker(
      () => _port.broker.newDataChannels(
        _sessionId,
        DataChannelsRequest(
          dataChannels: [
            for (final item in requested)
              DataChannelObject.local(
                item.channel.name,
                ordered: item.channel.profile.ordered,
                maxRetransmits: item.channel.profile.maxRetransmits,
              ),
          ],
        ),
      ),
    );
    await _open(
      requested,
      response,
      (item, result) =>
          result.dataChannelName == item.channel.name &&
          result.location != TrackLocation.remote,
    );
  }

  Future<void> _runSubscribeBatch(List<_NewItem> batch) async {
    final requested = _stillBound(batch, 'subscribe');
    if (requested.isEmpty) return;
    await _establish();
    final DataChannelsResponse response;
    try {
      response = await _port.callBrokerNamingRemotes(
        () => _port.broker.newDataChannels(
          _sessionId,
          DataChannelsRequest(
            dataChannels: [
              for (final item in requested)
                if (item.channel case final RemoteDataChannel channel)
                  DataChannelObject.remote(
                    sessionId: channel.remoteSessionId,
                    dataChannelName: channel.name,
                    ordered: channel.profile.ordered,
                    maxRetransmits: channel.profile.maxRetransmits,
                    canReply: channel.canReply ? true : null,
                  ),
            ],
          ),
        ),
      );
    } on RemoteSessionGoneException catch (e) {
      // A publisher's session is gone, not ours: fail just these
      // subscriptions, as per-channel errors.
      for (final item in requested) {
        item.fail(
          this,
          SfuDataChannelException(
            operation: 'datachannels/new',
            name: item.channel.name,
            errorCode: e.errorCode,
            errorDescription: e.errorDescription,
          ),
        );
      }
      return;
    }
    await _open(
      requested,
      response,
      (item, result) =>
          result.dataChannelName == item.channel.name &&
          (result.sessionId == null ||
              result.sessionId ==
                  (item.channel as RemoteDataChannel).remoteSessionId),
    );
  }

  /// The items whose channel is still waiting on this manager; the others
  /// were closed (or their session failed) before the request.
  List<_NewItem> _stillBound(List<_NewItem> batch, String operation) {
    final bound = <_NewItem>[];
    for (final item in batch) {
      if (identical(item.channel._manager, this)) {
        bound.add(item);
      } else {
        item.fail(this, _unboundError(operation));
      }
    }
    return bound;
  }

  Object _unboundError(String operation) {
    try {
      _port.throwIfUnusable();
    } catch (error) {
      return error;
    }
    return SfuSessionException('closed before $operation');
  }

  /// Matches `datachannels/new` results to [requested] and opens a
  /// negotiated channel for each accepted one. IDs the SFU allocated for
  /// channels that can't be used (closed meanwhile, or the local channel
  /// failed) are closed again, best effort.
  Future<void> _open(
    List<_NewItem> requested,
    DataChannelsResponse response,
    bool Function(_NewItem item, DataChannelResult result) matches,
  ) async {
    _port.throwIfUnusable();
    if (response.hasError) {
      throw SfuRequestException(
        operation: 'datachannels/new',
        errorCode: response.errorCode!,
        errorDescription: response.errorDescription,
      );
    }
    final remaining = [...response.dataChannels];
    final orphans = <int>[];
    for (final item in requested) {
      final channel = item.channel;
      final index = remaining.indexWhere((r) => matches(item, r));
      final result = index < 0 ? null : remaining.removeAt(index);
      final id = result?.id;
      if (result == null || result.hasError || id == null) {
        item.fail(
          this,
          SfuDataChannelException(
            operation: 'datachannels/new',
            name: channel.name,
            errorCode: result?.errorCode,
            errorDescription:
                result?.errorDescription ??
                (result == null ? null : 'no channel id'),
          ),
        );
        continue;
      }
      if (!identical(channel._manager, this)) {
        orphans.add(id);
        item.fail(this, _unboundError('datachannels/new'));
        continue;
      }
      try {
        final opened = await _port.peerConnection.createDataChannel(
          channel.name,
          id: id,
          ordered: channel.profile.ordered,
          maxRetransmits: channel.profile.maxRetransmits,
        );
        if (!identical(channel._manager, this)) {
          orphans.add(id);
          unawaited(opened.close().catchError((Object _) {}));
          item.fail(this, _unboundError('datachannels/new'));
          continue;
        }
        channel._activate(this, opened, id);
        item.succeed();
      } catch (error, stackTrace) {
        orphans.add(id);
        item.fail(this, error, stackTrace);
      }
    }
    if (orphans.isEmpty || !_port.isUsable) return;
    try {
      await _port.callBroker(
        () => _port.broker.closeDataChannels(
          _sessionId,
          DataChannelsRequest(
            dataChannels: [
              for (final id in orphans) DataChannelObject.withId(id),
            ],
          ),
        ),
      );
    } catch (_) {
      // Best effort: the channels are already failed locally.
    }
  }

  // ---------------------------------------------------------------------------
  // Update (canReply)
  // ---------------------------------------------------------------------------

  Future<void> _runUpdateBatch(List<_UpdateItem> batch) async {
    // The last update per channel wins; earlier ones share its result.
    final latest = <RemoteDataChannel, List<_UpdateItem>>{};
    for (final item in batch) {
      final channel = item.channel;
      if (channel._id == null || !identical(channel._manager, this)) {
        // Not subscribed here (any more): keep it for the next subscribe.
        if (channel.state != SfuDataChannelState.closed) {
          channel._canReply = item.canReply;
        }
        item.succeed();
        continue;
      }
      (latest[channel] ??= []).add(item);
    }
    if (latest.isEmpty) return;

    final response = await _port.callBroker(
      () => _port.broker.updateDataChannels(
        _sessionId,
        DataChannelsRequest(
          dataChannels: [
            for (final MapEntry(key: channel, value: items) in latest.entries)
              DataChannelObject.remote(
                sessionId: channel.remoteSessionId,
                dataChannelName: channel.name,
                canReply: items.last.canReply,
              ),
          ],
        ),
      ),
    );
    _port.throwIfUnusable();
    if (response.hasError) {
      throw SfuRequestException(
        operation: 'datachannels/update',
        errorCode: response.errorCode!,
        errorDescription: response.errorDescription,
      );
    }
    final remaining = [...response.dataChannels];
    for (final MapEntry(key: channel, value: items) in latest.entries) {
      final index = remaining.indexWhere(
        (r) =>
            (r.id != null && r.id == channel._id) ||
            (r.dataChannelName == channel.name &&
                (r.sessionId == null ||
                    r.sessionId == channel.remoteSessionId)),
      );
      final result = index < 0 ? null : remaining.removeAt(index);
      // Only an explicit error fails the update.
      if (result != null && result.hasError) {
        for (final item in items) {
          item.fail(
            this,
            SfuDataChannelException(
              operation: 'datachannels/update',
              name: channel.name,
              errorCode: result.errorCode,
              errorDescription: result.errorDescription,
            ),
          );
        }
        continue;
      }
      channel._canReply = items.last.canReply;
      for (final item in items) {
        item.succeed();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Close
  // ---------------------------------------------------------------------------

  Future<void> _runCloseBatch(List<_CloseItem> batch) async {
    if (!_port.isUsable) {
      // Nothing to release on a dead session.
      for (final item in batch) {
        item.succeed();
      }
      return;
    }
    final response = await _port.callBroker(
      () => _port.broker.closeDataChannels(
        _sessionId,
        DataChannelsRequest(
          dataChannels: [
            for (final item in batch) DataChannelObject.withId(item.id),
          ],
        ),
      ),
    );
    if (response.hasError) {
      throw SfuRequestException(
        operation: 'datachannels/close',
        errorCode: response.errorCode!,
        errorDescription: response.errorDescription,
      );
    }
    final remaining = [...response.dataChannels];
    for (final item in batch) {
      final index = remaining.indexWhere((r) => r.id == item.id);
      final result = index < 0 ? null : remaining.removeAt(index);
      if (result != null && result.hasError) {
        item.fail(
          this,
          SfuDataChannelException(
            operation: 'datachannels/close',
            name: item.name,
            errorCode: result.errorCode,
            errorDescription: result.errorDescription,
          ),
        );
      } else {
        item.succeed();
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Queue items
// -----------------------------------------------------------------------------

/// One queued DataChannel request. Its outcome is decided during the
/// operation ([succeed] or [fail]); [done] completes at [settle].
abstract class _DataChannelItem {
  final Completer<void> done = Completer<void>();
  bool _succeeded = false;
  Object? _error;
  StackTrace? _stackTrace;

  bool get isPending => !_succeeded && _error == null;

  void succeed() {
    if (isPending) _succeeded = true;
  }

  void fail(
    DataChannelManager manager,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    if (!isPending) return;
    _error = error;
    _stackTrace = stackTrace;
    onFailed(manager, error);
  }

  /// Updates local state after a failure. Runs synchronously in [fail].
  void onFailed(DataChannelManager manager, Object error) {}

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

/// A publish or subscribe (`datachannels/new`).
class _NewItem extends _DataChannelItem {
  _NewItem(this.channel);

  final SfuDataChannel channel;

  @override
  void onFailed(DataChannelManager manager, Object error) {
    if (!identical(channel._manager, manager)) return;
    manager._forget(channel);
    channel._detach(SfuDataChannelState.failed, error);
  }
}

class _UpdateItem extends _DataChannelItem {
  _UpdateItem(this.channel, this.canReply);

  final RemoteDataChannel channel;
  final bool canReply;
}

class _CloseItem extends _DataChannelItem {
  _CloseItem(this.id, this.name);

  final int id;
  final String name;
}
