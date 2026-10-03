/// The plumbing under `Room`: the broker client, the Cloudflare Realtime
/// SFU API's wire models, and the low-level SFU session.
///
/// Most apps only need `package:cloudflare_realtime/cloudflare_realtime.dart`.
/// Import this library as well to:
///
/// - **implement [BrokerClient]** for a transport other than HTTP, or wrap
///   [HttpBrokerClient] (the request and response models, the header names
///   in [BrokerHeaders]);
/// - **use an [SfuSession] directly**, for something `Room` doesn't do.
///   `Room.session` is the room's current session; `SfuSession.connect`
///   opens one without a room.
///
/// The options and errors these share with the room API (`BrokerOptions`,
/// `BrokerException`, `SfuSessionOptions`, `SfuSessionException`,
/// `SfuTrackState`, `SendEncoding`, and `SimulcastOrdering`, which
/// `LayerSelectionOptions` uses) are in the main library. See
/// `docs/design.md` §4.1, §4.2 and §5.
library;

export 'src/broker/broker_client.dart';
export 'src/broker/broker_config.dart' show BrokerHeaders;
export 'src/broker/http_broker_client.dart';
export 'src/broker/models/common.dart' hide putErrorFields;
export 'src/broker/models/data_channels.dart';
export 'src/broker/models/ice_servers.dart';
export 'src/broker/models/session.dart';
export 'src/broker/models/tracks.dart' hide SimulcastOrdering;
export 'src/session/publish_options.dart'
    show PublishOptions, defaultVideoCodecPreferences;
export 'src/session/sfu_session.dart'
    show LocalTrackPublication, RemoteTrackSubscription, SfuSession;
export 'src/session/sfu_session_events.dart' show SfuConnectionState;
