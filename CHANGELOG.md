# Changelog

Notable changes to Conn are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) beginning with its
public alpha releases.

## [Unreleased]

### Planned

- Broader Codex App Server version compatibility.
- Continued accessibility, interaction, and release-hardening work.

## [0.2.0] - 2026-07-25

Continued alpha release.

### Added

- An internal provider-neutral Integration API covering Harnesses,
  Integrations, Sessions, Runs, Activities, Attention Requests, capabilities,
  action authority, and ordered updates.
- Multi-Integration aggregation and isolation contract tests using the real
  Codex-shaped fixture and a synthetic monitor-only Integration.
- Provider-neutral `ConnUI`, a typed Integration-settings composition slot,
  clean v0.2 projection persistence, and explicit Harness attribution.
- Exact-identity confirmation UI for removing the retired Sidequest plugin.

### Changed

- Generic product language now uses Sessions rather than Threads.
- App Server protocol, projection, control, and Shared Desktop types are
  confined to `ConnCodexAdapter`; Domain, AppCore, and UI no longer import it.
- The disposable v0.1 projection and outcome baseline are intentionally reset.
- The compact notification shelf is again one integrated notch surface with a
  visible countdown and automatic expiry.
- The built-in display header now preserves physical-notch safe wings while
  external displays retain the full compact status wording.
- Session history now presents Turns oldest-first while preserving canonical
  user, reasoning, tool, and assistant Item order inside each Turn.
- Clicking unused space in the expanded Conn header now collapses the surface
  without stealing clicks from its embedded controls.
- Chronological Session history now opens at its newest tail and resets to the
  tail when switching Sessions.

### Fixed

- Anchor Conn to the physical notch edge on built-in notched MacBook displays
  while retaining menu-bar clearance on external displays.
- Make every Shared Desktop diagnosis visibly confirm completion, show the
  bounded host-version tuple, and explain when the tuple is candidate-only.

### Known limitations

- Codex is the only supported Harness in v0.2. Claude Code, Pi, OpenCode, and
  other adapters are foundation work only, not product claims.
- This remains alpha software. The local ad-hoc artifact is not notarized.

## [0.1.1] - 2026-07-22

### Fixed

- Prevent resuming an idle thread in Conn or Codex from replaying previous
  assistant completions as duplicate notifications.

## [0.1.0] - 2026-07-21

Initial alpha release.

### Fixed

- Recover the Codex-managed daemon after a reboot when its exact control socket
  is absent and the version probe reports the corresponding `ENOENT` failure.

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

[Unreleased]: https://github.com/architpai/conn/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/architpai/conn/releases/tag/v0.2.0
[0.1.1]: https://github.com/architpai/conn/releases/tag/v0.1.1
[0.1.0]: https://github.com/architpai/conn/releases/tag/v0.1.0
