# Changelog

Notable changes to Conn are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) beginning with its
public alpha releases.

## [Unreleased]

## [0.2.1] - 2026-08-01

### Added

- An opt-in external Pi `0.83.0` Integration using Pi's standard global
  extension, a bounded current-user local broker, and acknowledged commands.
- Pi Session discovery, live transcript projection, reconnect handling,
  completion outcomes, follow-up, steer, interrupt, model visibility, and idle
  model switching.
- Independent Codex and Pi activation controls. Both Integrations are off by
  default and can be enabled or disabled without stopping harness-owned work.
- User-controlled Session dismissal. Dismissed Sessions stay outside the
  visible set until new activity arrives, while explicit search can still find
  them.
- Official upstream Pi and OpenAI harness marks with packaged-asset,
  attribution, and release-inspection coverage.

### Changed

- Codex discovery now admits only qualified standalone CLI and Codex Desktop
  Sessions, excluding unrelated clients that happen to use Codex infrastructure.
- Transcript presentation removes the UI-only 40-entry cap, renders the
  Integration-provided bounded history lazily, and filters internal lifecycle
  events from user-visible activity.
- Pi tool calls remain ordinary transcript activity; only non-standard
  approval and question concepts remain unsupported.
- Session rows now contain their dismiss controls, center harness marks against
  the full card, and center empty states in the usable detail viewport.
- The landing page and interactive product mock now represent Codex and Pi,
  functional dismissal, accurate visible-set counts, model visibility, and the
  v0.2.1 Integration boundary.

### Fixed

- Resume and reconnect projection for Pi Sessions no longer marks every exited
  Session as reconnecting or loses an active resumed Session.
- Pi completion notifications clear when inspected without erasing the Session
  or changing its underlying settled outcome.
- Pi transcript updates continue live after the initial notification sync.
- Completed and disconnected Pi Sessions settle to bounded idle/completed
  presentation instead of remaining permanently active.
- Session transcript rendering no longer leaks internal agent/turn lifecycle
  markers or introduces the same noise into Codex Sessions.
- Official harness marks and empty-state content now render centered in the
  native Session workspace.

### Known limitations

- Pi support is for independently launched external TUIs. Conn does not launch,
  restart, stop, or create Pi Sessions.
- Pi has no standard approval or structured-question concepts. Conn does not
  guess at user-customized tool implementations.
- Pi TUIs that were already open when the extension was installed need one
  `/reload`.
- This remains alpha software. The local ad-hoc artifact is not notarized.

## [0.2.0] - 2026-07-29

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
- Model selection is restored for new Sessions and idle follow-ups through a
  provider-neutral, Integration-supplied model catalog.
- Model and reasoning are separate composer controls; each model exposes only
  its Integration-advertised reasoning choices.
- User messages use the trailing transcript lane while Harness messages,
  reasoning, and tool activity use the leading lane.
- The compact Conn bar now uses the same full-width toggle target as the
  expanded bar.
- User and Harness messages now use directional speech bubbles while reasoning,
  tool calls, and other operational Activities remain distinct cards.
- Completed Runs collapse into provider-neutral summary blocks and expand to
  reveal their complete chronological Activity sequence.
- Collapsed Runs retain a compact preview of the User message that initiated
  them and show their elapsed work time when the Integration supplies both
  start and completion timestamps.
- The follow-up composer combines Model and Reasoning into one compact control;
  a small popover retains independent, model-filtered selectors.
- Refreshed the landing page, repository banner, and public documentation to
  match the current provider-neutral v0.2 Session UI.
- The public product mock now demonstrates visible-set status counts, harness
  attribution, grouped Run summaries, elapsed work time, the compact
  model-and-reasoning picker, and draft-first New Session flow.
- The native Conn mark now carries the same slow orbit as the landing page and
  becomes static when Reduce Motion is enabled.
- The landing-page mock now uses OpenAI's supplied monochrome mark and synthetic
  Aurora and Beacon fixtures instead of private project references.
- Documented that the ad-hoc alpha cannot register Launch Conn at login; that
  capability requires the planned Developer ID-signed distribution.

### Fixed

- Anchor Conn to the physical notch edge on built-in notched MacBook displays
  while retaining menu-bar clearance on external displays.
- Make every Shared Desktop diagnosis visibly confirm completion, show the
  bounded host-version tuple, and explain when the tuple is candidate-only.
- Preserve the selected opaque model ID across Conn's action boundary and
  revalidate it against the current Codex App Server catalog before sending.
- Show the current Session's actual model and reasoning effort instead of the
  ambiguous `Current model` placeholder.
- Preserve multiline user and Harness message content through the neutral
  Domain and show the full Harness answer in a completed Run summary.
- Replace speech-bubble tails with clean asymmetric continuous corners so long
  messages no longer produce a lower-edge geometry artifact.
- Restore standard macOS Edit responder commands so copy, paste, cut, undo,
  redo, and select-all work in the follow-up composer and other text fields.
- Replace the ambiguous `C` Harness fallback with the installed OpenAI
  Codex/ChatGPT application icon while retaining `Codex` as the accessible
  Integration label.

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

[Unreleased]: https://github.com/architpai/conn/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/architpai/conn/releases/tag/v0.2.1
[0.2.0]: https://github.com/architpai/conn/releases/tag/v0.2.0
[0.1.1]: https://github.com/architpai/conn/releases/tag/v0.1.1
[0.1.0]: https://github.com/architpai/conn/releases/tag/v0.1.0
