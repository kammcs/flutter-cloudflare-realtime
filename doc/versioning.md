# Versions

## Before 0.1.0: pin a dev tag

Until 0.1.0 is on pub.dev, depend on the package from git and pin a tag:

```yaml
dependencies:
  cloudflare_realtime:
    git:
      url: https://github.com/kammcs/flutter-cloudflare-realtime
      ref: v0.1.0-dev.1
```

- **Dev tags** are named `v0.1.0-dev.N`, with N counting up. They mark commits that are ready to pin: every check passes, and the changes in them were tested as described in the changelog. Semver orders them before `v0.1.0`.
- **The changelog says what each tag brings.** In `CHANGELOG.md`, under "Unreleased", the "Development history" list has a heading for each dev tag. The entries under a heading, down to the next one, are what that tag added. Entries above the newest heading are not in any tag yet. Breaking changes are listed first under a heading and start with **Breaking**.
- **Moving to a newer tag:** read the entries between your tag and the new one. A breaking change names what to change in your code.
- The `version` in `pubspec.yaml` stays as it is until the 0.1.0 release.

## From 0.1.0: semantic versions

Releases follow [semantic versioning](https://semver.org) as Dart applies it to 0.x versions:

- a breaking change bumps the minor version (0.1.x to 0.2.0);
- anything else bumps the patch version (0.1.0 to 0.1.1).

So `cloudflare_realtime: ^0.1.0` takes fixes and additions, never a breaking change. Each release has its own `CHANGELOG.md` section, with breaking changes first.

## The `flutter_webrtc` fork

Some fixes in this package's docs (`docs/design.md`) need `flutter_webrtc` changes that upstream hasn't released yet. They live in a fork, [kammcs/flutter-webrtc](https://github.com/kammcs/flutter-webrtc), offered upstream as pull requests. An app that wants them overrides `flutter_webrtc` with a commit of that fork.

- The fork tags the commits meant to be pinned `pin-YYYY-MM-DD`, with `b`, `c` and so on for further pins on the same day. A tag keeps its commit reachable when the fork's branches are rebased for upstream review.
- Some of those commits also use a patched libwebrtc build. It is published as a release of [kammcs/libwebrtc](https://github.com/kammcs/libwebrtc), and the fork's `third_party/libwebrtc_version.ini` points at it.
- Once upstream releases a fix, the override can go. The package then raises its `flutter_webrtc` lower bound to that release.
