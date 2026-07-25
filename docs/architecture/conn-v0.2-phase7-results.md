# Conn v0.2 Phase 7 release-candidate results

Status: Offline gate complete; live acceptance and public release pending.

The local candidate is Conn `0.2.0` build `4`, a continued Alpha release.
Codex is the only supported Harness. Claude Code, Pi, OpenCode, and other
Harness adapters are not included.

## Offline evidence

The following pass on 2026-07-25:

- `swift build`;
- all four required owner executables: 1,469 Codex-adapter assertions, 67
  Domain assertions, 217 AppCore assertions, and 196 UI assertions;
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
CFBundleVersion = 4
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

## Required manual acceptance

The candidate must still be exercised in the running app for ordinary Session
inventory and selection, ephemeral Session creation, follow-up, steer,
interrupt, Attention handling when available, reconnect, sleep/wake, daemon
recovery, Shared Desktop rollback, privacy canaries, and survival of Harness
work after Conn quits.

Do not tag `v0.2.0`, publish an artifact, or claim stable/notarized release
status until that evidence is recorded.
