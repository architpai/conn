# Changelog

Notable changes to Conn are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) beginning with its
public alpha releases.

## [Unreleased]

### Fixed

- Prevent resuming an idle thread in Conn or Codex from replaying its previous
  assistant completion as a duplicate notification.
- Recover the Codex-managed daemon after a reboot when its exact control socket
  is absent and the version probe reports the corresponding `ENOENT` failure.

### Planned

- Broader Codex App Server version compatibility.
- Continued accessibility, interaction, and release-hardening work.

## [0.1.0] - 2026-07-21

Initial alpha release.

### Added

- A native, notch-anchored macOS surface for supervising connected Codex
  threads.
- Collapsed status indicators and an expanded workspace for thread selection,
  activity, transcript presentation, and supported controls.
- App Server-backed follow-up, steer, interrupt, approval, and structured
  question flows with conservative capability gating.
- Managed Daemon Mode and an explicitly experimental Shared Desktop Mode.
- Version-pinned compatibility for Codex App Server 0.144.5 and 0.144.6.
- Bounded local projection persistence, reconnect qualification, and stale-state
  presentation.
- Reduce Motion support, keyboard access, display-aware notch geometry, and
  completion and attention notifications.
- Ad-hoc development build and DMG packaging validation scripts.

### Known limitations

- Conn is alpha software and supports only its explicitly allowlisted Codex App
  Server versions.
- Shared Desktop Mode depends on an experimental integration and is not an
  OpenAI-supported public configuration contract.
- Ad-hoc artifacts are for local testing only; public distribution requires a
  Developer ID signature and notarization.

[Unreleased]: https://github.com/architpai/conn/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/architpai/conn/releases/tag/v0.1.0
