# Conn v0.2 Phase 7 release-candidate results

Status: Offline gate complete; live acceptance and public release pending.

The local candidate is Conn `0.2.0` build `7`, a continued Alpha release.
Codex is the only supported Harness. Claude Code, Pi, OpenCode, and other
Harness adapters are not included.

## Offline evidence

The following pass on 2026-07-25:

- `swift build`;
- all four required owner executables: 1,469 Codex-adapter assertions, 67
  Domain assertions, 217 AppCore assertions, and 208 UI assertions;
- 14 ConnApp migration-edge assertions;
- provider-boundary and schema-provenance verification;
- release-inspection self-tests;
- frozen-lockfile website build and lint;
- debug app assembly, strict deep code-sign verification, Info.plist lint, and
  built-app privacy inspection.

The built candidate is:

```text
.build/conn-app/Conn.app
CFBundleShortVersionString = 0.2.0
CFBundleVersion = 7
signature = local ad-hoc
notarization = not claimed
```

The installed standalone CLI reports `codex-cli 0.144.6`, which is inside the
two-version pinned compatibility set.

## Local candidate corrections

The first live v0.2 candidate exposed two UI regressions:

- the Phase 5 panel rewrite calculated every frame from `visibleFrame.maxY - 8`,
  bypassing the physical-notch anchor even when the display was correctly
  identified as built-in and notched;
- Shared Desktop diagnosis completed but repeated results had no visible
  completion marker or host-version explanation.

Build 4 routes built-in and external frame calculation through one tested
policy. The live built-in display now produces a top-origin window bound of
`Y = 0`, and the external-display branch retains its eight-point clearance.
Diagnosis now changes to `Diagnose again`, updates a `Checked` timestamp, shows
the bounded Desktop/bundled-Codex/App Server versions, and explains
candidate-only qualification.

Build 5 restores the compact activity shelf as one clipped surface continuous
with the Conn bar. It removes the obsolete eight-point inter-surface height,
restores the countdown ring, and gives each notification ID one cancellable
five-to-ten-second lifetime. Expiry and manual dismissal both collapse the
panel back to compact-bar height; repeated projection refreshes cannot restart
the same notification timer.
The packaged build was then exercised on the built-in MacBook display: the
notification appeared as one continuous surface with a visible countdown ring,
disappeared after its bounded lifetime, and left a `350 × 44` compact window at
top-origin `Y = 0`.

Build 6 restores the physical-notch compact width to 404 points, keeps the
Conn wordmark inside the safe left wing, omits compact Integration status text
that would render behind the camera housing, and reserves a tested 184-point
center gap. External capsules retain their 350-point width and full status
wording.

Build 7 restores chronological Session history. The Codex projection remains
newest-first for inventory and outcome decisions, but the Integration mapper
now emits oldest-first Run blocks while retaining each Turn's authoritative
Item order. This avoids the incorrect flat-array reversal that would put tool
calls, reasoning, and assistant messages ahead of the user message that caused
them.

## Required manual acceptance

The candidate must still be exercised in the running app for ordinary Session
inventory and selection, ephemeral Session creation, follow-up, steer,
interrupt, Attention handling when available, reconnect, sleep/wake, daemon
recovery, Shared Desktop rollback, privacy canaries, and survival of Harness
work after Conn quits.

Do not tag `v0.2.0`, publish an artifact, or claim stable/notarized release
status until that evidence is recorded.
