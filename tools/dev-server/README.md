# Dev server (DEV ONLY)

> **DEV ONLY, NOT FOR PRODUCTION.** One shared token authenticates everybody, callers name themselves, and every room is open to everyone who has the token. Run it on your own machine and a trusted network, and stop it when you're done.

A local stack for running real multi-device calls with the example app, using only your Cloudflare SFU credentials:

- **A broker.** It mounts the shared broker core from [`broker/`](../../broker/) (imported, not copied) on a Node HTTP server, with an in-memory session store. It enforces the same session-binding and same-room rules as the reference brokers.
- **Presence signaling.** A WebSocket endpoint at `/signaling`. It speaks a small protocol that maps 1:1 to the Dart `Signaling` interface; see [Protocol](#protocol). The example app's client is [`example/lib/ws_signaling.dart`](../../example/lib/ws_signaling.dart).

Everything runs from one process and one port.

| Path | What |
|---|---|
| `/sessions/…`, `/generate-ice-servers` | The broker. `BrokerConfig.baseUrl` is the server's root URL. |
| `/signaling` | Presence WebSocket (`ws://`, `?token=<dev token>`). |
| `/healthz` | Unauthenticated `{"ok":true}`. Open it in a phone's browser to check it can reach your laptop. |

**Auth:**

- Broker requests carry `Authorization: Bearer <dev token>` and `X-Dev-User: <user name>`. The user name becomes the caller ID that SFU sessions are bound to. It must be printable ASCII (up to 128 characters), with no leading or trailing spaces.
- Room membership: allow all.

## Run a multi-device call locally

### 1. Set up credentials

You need Node 22.12 or later and a Cloudflare Realtime **SFU app** (Cloudflare dashboard → Realtime → SFU: App ID and App Secret). A **TURN key** is optional; it helps when a device is behind a strict NAT or firewall.

```sh
cd tools/dev-server
npm ci
cp .env.example .env      # then edit .env
```

`.env` is git-ignored. Set:

| Variable | |
|---|---|
| `REALTIME_DEV_SERVER=1` | Required. The server refuses to start without it. |
| `CF_REALTIME_APP_ID`, `CF_REALTIME_APP_SECRET` | Required. |
| `CF_TURN_KEY_ID`, `CF_TURN_API_TOKEN` | Optional. Without them, clients get Cloudflare STUN only. |
| `DEV_TOKEN` | Optional, at least 16 characters. Without it, a random token is generated at each start. |
| `DEV_CORS_ORIGINS` | Optional, for Flutter Web: a comma-separated list of origins, or `*` (the default). |

Real environment variables override the file. The server prints which variables are set, never their values. The one exception is a generated dev token: the server prints it, because it's random and local.

### 2. Start the server

Same machine only (desktop app on the laptop that runs the server):

```sh
npm start
```

With phones or other computers on your LAN:

```sh
npm start -- --host 0.0.0.0
```

It prints a DEV ONLY banner, a warning when it binds beyond loopback, the dev token, and a `Server URL` for each LAN address, such as `http://192.168.1.10:8787`. Other options: `--port`, `--env-file` and `--heartbeat-ms`; see `npm start -- --help`.

The default bind is `127.0.0.1`, which other devices can't reach. Only use `--host 0.0.0.0` on a network you trust: anyone there who learns the dev token can use your SFU app.

### 3. Point each device at it

On each device, run the example app and enter these on the join screen:

- the **server URL**: use the LAN address, not `127.0.0.1`, on phones and other computers;
- the **dev token**;
- a **user name**.

Use the same room on every device.

To skip typing, pass them as `--dart-define`s, which `DevServerConfig.fromEnvironment()` reads:

```sh
cd example
flutter run -d windows \
  --dart-define=DEV_SERVER_URL=http://192.168.1.10:8787 \
  --dart-define=DEV_TOKEN=<dev token> \
  --dart-define=DEV_USER=ada
```

**Android emulator:** `http://10.0.2.2:8787` reaches the host's loopback, so the default bind works.

### LAN, firewall and platform notes

- **Find the LAN IP.** The server prints it. Otherwise, use `ipconfig` on Windows, or `ipconfig getifaddr en0` on macOS. Pick the address on the same Wi-Fi or LAN as the other devices, not a VPN, WSL or VirtualBox adapter.
- **Windows firewall.** The first `--host 0.0.0.0` start opens a Windows Defender Firewall prompt for `node.exe`. Allow it on **Private** networks, and make sure the Wi-Fi network's profile is Private. Or add a rule from an elevated prompt:

  ```sh
  netsh advfirewall firewall add rule name="cloudflare_realtime dev server" dir=in action=allow protocol=TCP localport=8787 profile=private
  ```

  Remove the rule when you're done.
- **macOS firewall.** If the server runs on a Mac with the firewall on, allow incoming connections for `node` when prompted (System Settings → Network → Firewall).
- **Check reachability first.** Open `http://<LAN IP>:8787/healthz` in the phone's browser. If it doesn't load, fix the network before debugging the app. Guest Wi-Fi and some office networks isolate clients from each other.
- **Android: cleartext HTTP.** Android blocks cleartext (`http://`, `ws://`) traffic to hosts by default. The example allows it **in debug builds only**, through [`example/android/app/src/debug/res/xml/network_security_config.xml`](../../example/android/app/src/debug/res/xml/network_security_config.xml), which only the debug manifest references. Release and profile builds keep Android's default. Use `flutter run` (debug) against the dev server.
- **macOS: entitlements.** The example already has `com.apple.security.network.client` (and `network.server` in debug) in `example/macos/Runner/*.entitlements`, so the sandboxed app can reach the dev server. On macOS 15 and later, the first connection to a LAN address may trigger a **Local Network** permission prompt; allow it. You can change it later in System Settings → Privacy & Security → Local Network.
- **iOS** (not part of the week-6 checkpoint): a LAN connection triggers the Local Network prompt, which needs `NSLocalNetworkUsageDescription` in `Info.plist`.
- **Media still goes through Cloudflare.** Devices only talk to the dev server for broker calls and presence. Audio and video flow between each device and the Cloudflare SFU, so each device needs internet access. It also needs TURN if UDP is blocked.

### Testing a network drop

The server pings every socket every 2 seconds (`--heartbeat-ms`), and drops a socket that misses a round. A device that loses its network therefore leaves the room within about 4 seconds, and the others see it go.

`WsSignaling` in the app pings every 4 seconds. It treats 10 seconds of silence as a dead socket. It then reconnects with backoff (0.5 s, doubling, up to 10 s) and rejoins with its latest state. If it reconnects before the server has evicted the old socket, the new connection replaces the old one (see `replaced` below).

**Drop the client's network, not the server's.** Cutting the network of the machine that runs the dev server (unplugging it, disabling its adapter) also cuts the broker's own path to Cloudflare. The client on that machine still reaches the broker over loopback, but every `sessions/new` fails with `502` until the machine's internet is back, including whatever it depends on (DHCP, DNS, a VPN that reconnects). Each of those failures can take up to Node's 10-second connect timeout, which stretches the client's backoff. So the recovery time you measure is mostly that machine's network coming back, not the app's reconnection; in production the broker is somewhere else and stays reachable.

For a clean measurement, drop only a client's network while the broker stays reachable, for example:

- a phone on USB with `adb reverse tcp:8787 tcp:8787` and the server URL `http://127.0.0.1:8787`: turn the phone's Wi-Fi off and on (and mobile data off, or it falls over to it). Broker and signaling calls still go over USB, while the media path to Cloudflare is gone;
- or a second computer whose network you drop, with the dev server on a machine that stays online.

When an upstream call fails, the log line names why, by error code only, and how long it took, for example `[broker] sessions/new: SFU request failed (TypeError: UND_ERR_CONNECT_TIMEOUT, after 10012 ms)`. `ENOTFOUND` or `EAI_AGAIN` is DNS; `UND_ERR_CONNECT_TIMEOUT` is no answer within 10 s (Node's fetch reports a DNS lookup that hangs this way too); `ECONNRESET` or `UND_ERR_SOCKET` is a connection that broke. Every request line ends with its duration (`-> 502 in 10012 ms`); the line is written when the response is ready, so the request arrived that long before the timestamp.

## Protocol

It's JSON text frames over one WebSocket per participant.

**Connect** to `ws://<host>:<port>/signaling?token=<dev token>`, or send `Authorization: Bearer <dev token>` on the upgrade. With a missing or wrong token, the server sends `{"type":"error","code":"unauthorized",...}` and closes with code **4401**. Don't retry after that.

**Client → server.** `id` is optional; when present (a number or a string), the server echoes it in the `ack` or `error`.

| Message | Meaning |
|---|---|
| `{"type":"join","id":1,"roomId":"r","participant":{…}}` | `Signaling.join`. One room per connection. |
| `{"type":"update","id":2,"participant":{…}}` | `Signaling.update`. It must keep the joined `participantId`. |
| `{"type":"leave","id":3}` | `Signaling.leave`. The connection can join again afterwards. |
| `{"type":"ping","id":4}` | Application-level keepalive. The server answers `pong`. |

`participant` is `ParticipantState.toJson()` (see `lib/src/signaling/participant_state.dart`), for example `{"participantId":"ada:3f9a1c","sessionId":null,"tracks":{},"metadata":{"displayName":"Ada"}}`. The server checks a few things, then relays the object as-is, unknown fields included:

- `participantId` is a non-empty string of up to 256 characters;
- `sessionId` is a string, `null` or absent;
- `tracks` is an object.

A message may be up to 64 KiB.

**Server → client:**

| Message | Meaning |
|---|---|
| `{"type":"ack","id":1}` | The request with that `id` succeeded. |
| `{"type":"error","id":1,"code":"…","message":"…"}` | It failed. `id` is absent for unparseable messages. |
| `{"type":"participants","roomId":"r","participants":[…]}` | The **full** room list, **including the receiver**, in join order. It's sent to every member after each join, update, leave or disconnect. On your own join it comes right after the `ack`. Clients drop their own entry. |
| `{"type":"pong","id":4}` | Reply to `ping`. |

**Error codes:**

| Code | Meaning |
|---|---|
| `bad_request` | Malformed message or participant. |
| `already_joined` | `join` while in a room. |
| `not_joined` | `update` before `join`. |
| `participant_id_changed` | `update` with a different `participantId`. |
| `unauthorized` | Bad dev token. Closes with 4401. |
| `replaced` | Another connection joined the same room with your `participantId`, usually your own reconnect. Closes with **4409**. Don't reconnect, or two connections will keep replacing each other. |

**Liveness.** Disconnects count as leaves. The server also sends WebSocket protocol pings every `--heartbeat-ms` (2000 by default) and terminates a socket that hasn't answered, or sent anything, since the previous ping. Rooms are independent; an empty room is forgotten.

## Development

```sh
npm ci
npm run typecheck   # tsc for the server, its tests, and the broker core it imports
npm test            # vitest: broker mounting and dev auth, config, the presence protocol
```

CI runs both (the `dev-server` job in `.github/workflows/ci.yml`).
