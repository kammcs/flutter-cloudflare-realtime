# Cloudflare Realtime SFU: what this package builds on

- **Summary date:** 2026-09-30.
- **Source of truth:** Cloudflare's docs and OpenAPI schema. Re-check them when implementing; the links are in the Sources section at the end.

## Components

| Component | What it is | Relevance here |
|---|---|---|
| **SFU** (formerly "Calls") | Plain WebRTC media forwarding, controlled by an HTTPS sessions/tracks API. Each session is one PeerConnection. You push tracks, pull tracks and renegotiate. **The API must be called server-side with the App Secret.** | The core of this package. No official Flutter client exists; we use `flutter_webrtc`. |
| **TURN** | Managed TURN. It is free when used with the SFU. | Credentials come from the broker's `generate-ice-servers` endpoint. |
| **RealtimeKit** (from the Dyte acquisition) | A higher-level meetings SDK | **Discontinued for Flutter** (`realtimekit_core`/`realtimekit_ui`, 2026-08-07). It was Android/iOS only, with no desktop support. |

**The SFU has no rooms or presence.** Cloudflare's docs call a room "application state", and the SFU "does not supply a room-presence protocol". Apps provide these.

## HTTPS API

- **Base URL:** `https://rtc.live.cloudflare.com/v1`
- **Headers:** `Authorization: Bearer <APP_SECRET>` and `Content-Type: application/json`

| Operation | Endpoint |
|---|---|
| Create session | `POST /apps/{appId}/sessions/new` |
| Push/pull tracks | `POST /apps/{appId}/sessions/{sessionId}/tracks/new` |
| Update tracks (e.g. `preferredRid`) | `PUT /apps/{appId}/sessions/{sessionId}/tracks/update` |
| Send a renegotiation answer | `PUT /apps/{appId}/sessions/{sessionId}/renegotiate` |
| Close tracks | `PUT /apps/{appId}/sessions/{sessionId}/tracks/close` |
| Read session state | `GET /apps/{appId}/sessions/{sessionId}` |
| DataChannel transport | `POST /apps/{appId}/sessions/{sessionId}/datachannels/establish` |
| Publish/subscribe DataChannels | `POST /apps/{appId}/sessions/{sessionId}/datachannels/new` |
| Update DataChannel subscriptions | `PUT /apps/{appId}/sessions/{sessionId}/datachannels/update` |
| Close DataChannels | `PUT /apps/{appId}/sessions/{sessionId}/datachannels/close` |
| WebSocket adapters (not planned here) | `POST /apps/{appId}/adapters/websocket/new` and `…/close` |
| TURN credentials (separate TURN key) | `POST /turn/keys/{turnKeyId}/credentials/generate-ice-servers` with body `{ttl}` |

### Shapes

These are taken from partytracks' `callsTypes.ts`. Verify them against the OpenAPI schema.

```ts
SessionDescription   { type: "offer" | "answer"; sdp: string }
ErrorResponse        { errorCode?: string; errorDescription?: string }

NewSessionRequest    { sessionDescription?: SessionDescription }        // body optional
NewSessionResponse   { sessionId: string; sessionDescription?: ... } & ErrorResponse

TrackMetadata        { location?: "local" | "remote"; trackName?: string;
                       sessionId?: string;          // publisher's session, for pulls
                       mid?: string | null;
                       simulcast?: { preferredRid: string;
                                     priorityOrdering?: "none" | "asciibetical";
                                     ridNotAvailable?: "none" | "asciibetical" } }
TracksRequest        { tracks: TrackMetadata[]; sessionDescription?: SessionDescription }
TracksResponse       { sessionDescription: SessionDescription;
                       requiresImmediateRenegotiation: boolean;
                       tracks?: (TrackMetadata & ErrorResponse)[] } & ErrorResponse
RenegotiateRequest   { sessionDescription: SessionDescription }
CloseTracksRequest   { tracks: TrackMetadata[]; sessionDescription?: ...; force: boolean }
```

### Rules that shape the client

- **One `tracks/new` call is all `local` or all `remote`.** A remote batch can reference several publishers.
- **The SDP exchange must finish before the next mutation on the same session.** So the client needs a serialized operation queue.
- **A successful HTTP response can still carry per-track errors.**
- **Track status** is one of `active`, `inactive` or `initializing`.
- **Expired sessions** return HTTP `410` with `session_error`. An unconnected session can expire before its first track or DataChannel operation.
- **Reconnection:** replace the connection. Create a new session and re-subscribe. ICE restart is not documented.
- `sessions/new` accepts an optional `correlationId` for diagnostics.

## Simulcast

- RID-based. The publisher defines encodings (`rid`s). A subscriber requests one with `simulcast.preferredRid` when pulling.
- **`priorityOrdering`**:
  - `none` (default) keeps the chosen layer regardless of bandwidth;
  - `asciibetical` treats 'a' as the most desirable and 'z' as the least, and lets the SFU step down.
- **`ridNotAvailable`**:
  - `none` (default) means don't switch when the preferred layer disappears;
  - `asciibetical` falls back to the next available RID.
- **Changing layer:** `PUT tracks/update` with the subscription's `mid` and the new `preferredRid`. Check the per-track result before updating app state.
- **Automatic layer fallback is off by default, so the client picks layers.**

## DataChannels

- **Publisher:**

  ```json
  {"dataChannels":[{"location":"local","dataChannelName":"input","ordered":true}]}
  ```

  Optional fields: `maxRetransmits` **or** `maxPacketLifeTime` (at most one). Omit both for reliable delivery.
- **Subscriber:**

  ```json
  {"dataChannels":[{"location":"remote","sessionId":"<publisher>","dataChannelName":"input","canReply":false}]}
  ```

- **Direction:** publisher to subscribers. One subscriber with `canReply: true` can reply on the publisher's channel.
- **Channels are negotiated.** Use the returned `id` in `createDataChannel(name, negotiated: true, id: id)`. The publisher's and subscriber's IDs can differ.
- Call `datachannels/establish` first to set up the SCTP transport.

## Pricing (for context)

- **SFU and TURN egress:** $0.05/GB, with the **first 1 TB per month free** (shared by the SFU and TURN). Ingress is free.
- **Why simulcast matters:** it cuts egress to about a third. See [design.md §6](design.md#6-simulcast).

## `flutter_webrtc` baseline

- **Version:** 1.6.2+hotfix.3 (2026-09-15, libwebrtc m150).
- **Supports:** audio and video, data channels, screen capture, simulcast and E2EE on Android, iOS, Web, macOS and Windows.
- **Maturity:** production-grade. LiveKit and Stream sponsor it and build their SDKs on it.
- **macOS:** 1.6.0 removed a private API so apps pass App Store review.

## Sources

1. Sessions and tracks: https://developers.cloudflare.com/realtime/sfu/sessions-tracks/
2. Architecture (rooms are app state): https://developers.cloudflare.com/realtime/sfu/concepts/architecture/
3. Negotiation: https://developers.cloudflare.com/realtime/sfu/concepts/negotiation/
4. HTTPS API: https://developers.cloudflare.com/realtime/sfu/https-api/
5. Simulcast: https://developers.cloudflare.com/realtime/sfu/simulcast/
6. DataChannels: https://developers.cloudflare.com/realtime/sfu/features/datachannels/
7. Pricing: https://developers.cloudflare.com/realtime/sfu/pricing
8. TURN: https://developers.cloudflare.com/realtime/turn/what-is-turn/
9. RealtimeKit Flutter discontinued: https://developers.cloudflare.com/realtime/realtimekit/release-notes/flutter-core/ · https://pub.dev/packages/realtimekit_core
10. partytracks (ISC): https://github.com/cloudflare/partykit/tree/main/packages/partytracks
11. Cloudflare Meet reference app: https://github.com/cloudflare/meet
12. flutter_webrtc: https://pub.dev/packages/flutter_webrtc · https://github.com/flutter-webrtc/flutter-webrtc (issues #982, #1085, #1539, #1952, #2200, #2205)
13. Chrome screen-sharing controls: https://developer.chrome.com/docs/web-platform/screen-sharing-controls
