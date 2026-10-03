# Platform setup

What your app needs, per platform, to use `cloudflare_realtime`. Start with the [README](../README.md) for the overview and the quick start.

| Platform | Guide |
|---|---|
| Android | [android.md](android.md): permissions, the foreground services (calls, screen share, `phoneCall`), `BLUETOOTH_CONNECT`, Telecom, Google Play declarations |
| iOS | [ios.md](ios.md): `Info.plist` keys, background modes, the Broadcast Upload Extension and its signing, CallKit and VoIP pushes |
| macOS | [macos.md](macos.md): entitlements, usage descriptions, the Screen Recording permission |
| Windows | [windows.md](windows.md): build tools, what differs on Windows |
| Web | [web.md](web.md): HTTPS, the broker's CORS origins, autoplay, browsers |

Coming from the pre-release API? [migrating-to-0.1.md](migrating-to-0.1.md) lists every rename of the 0.1.0 cleanup.

Your broker needs setting up on every platform: see [broker/README.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/broker/README.md).
