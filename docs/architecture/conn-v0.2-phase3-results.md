# Conn v0.2 Phase 3 results

Status: implementation complete on `cdx/v0.2-provider-neutral`.

Phase 3 replaces the `ConnAppServerAdapter` product and target with
`ConnCodexAdapter`, moves Codex-only runtime mechanics under that target, and
implements the provider-neutral `ConnIntegration` port. The legacy AppCore
presentation path remains wired during the named Phase 2–4 coexistence window;
the atomic production cutover remains Phase 5.

## Target and ownership changes

- `ConnCodexAdapter` depends only on `ConnDomain`.
- `ConnAppCore` temporarily retains its documented legacy dependency on
  `ConnCodexAdapter` until Phase 5.
- `ConnApp` composes AppCore and the Codex adapter.
- The old adapter source, test target, product, and executable names no longer
  exist.
- Shared Desktop diagnostics, evaluation, setup, rollback, and host inspection
  are CodexAdapter-owned.
- App Server observation parsing, monitoring/recovery, control execution,
  legacy projection checkpoint coordination, and legacy plugin retirement are
  CodexAdapter-owned.
- Legacy hook retirement remains outside the adapter and is injected by the
  ConnApp composition edge.

## Neutral Codex Integration

`CodexIntegration` is a Swift 6 actor conforming to the Sendable asynchronous
`ConnIntegration` port. It:

- owns one reserved stable Integration identity with OpenAI Harness
  attribution;
- establishes a qualified atomic feed only after App Server connection
  evidence is live;
- maps Codex Threads, Turns, Items, requests, capabilities, Workspaces, and
  outcomes into bounded Conn Sessions, Runs, Activities, Attention Requests,
  actions, and outcomes;
- scopes Session identity by Integration;
- records acknowledged New Chat Sessions as Conn-originated, Codex-owned, and
  ephemeral;
- maps follow-up, steer, interrupt, New Chat, structured-answer, and approval
  actions through the existing commit gates;
- preserves acknowledgement uncertainty without automatic replay;
- terminates feed authority on disconnect, reconnect, connection replacement,
  unsafe overflow, or runtime failure;
- maps complete versus partial inventory independently;
- retains App Server request authority in an adapter-internal registry;
- generates opaque Conn Attention IDs so provider response tokens never cross
  the port.

The update stream uses the Domain buffer bound. A dropped non-replaceable
update terminates the stream; consumers must fail stale and requalify.

## Test reconciliation

All Phase 1 CodexAdapter-assigned tests now execute from
`ConnCodexAdapterTests`.

| Evidence | Assertions |
| --- | ---: |
| Phase 1 assigned CodexAdapter denominator | 984 |
| Migrated and passing | 984 |
| Intentionally retired | 0 |
| Denominator reconciliation assertion | 1 |
| New Phase 3 semantic and hardening assertions | 17 |
| Current `conn-codex-adapter-tests` total | 1,002 |

The remaining AppCore suite is exactly its assigned 765 assertions:
541 AppCore, 210 ConnUI, and 14 ConnApp composition/retirement assertions.

Golden mapping tests cover:

- stable OpenAI/Codex Harness and Integration attribution;
- composite Session identity;
- complete inventory and snapshot watermark;
- qualified capability mapping;
- New Chat origin, ownership, and retention;
- Workspace, status, Run, Activity, unknown Item, and Attention mapping;
- internal provider request retention with opaque external Attention identity;
- absence of provider session and response tokens from the neutral snapshot.

Existing migrated parity cases continue to cover pinned 0.144.5/0.144.6
qualification, full pagination across empty pages with a non-null cursor,
mapping and privacy bounds, controls, acknowledgement outcomes, reconnect and
overload recovery, hooks, legacy plugin retirement, and Shared Desktop.

## Automated boundary

`scripts/check-conn-codex-adapter-boundary.sh` verifies:

- ConnCodexAdapter does not import AppCore, UI, AppKit, or SwiftUI;
- neutral ConnIntegration domain files contain no App Server, JSON-RPC,
  transport, or Shared Desktop names;
- legacy adapter target directories are gone;
- the production Codex actor conforms to `ConnIntegration`.

## Review corrections

The Phase 3 review produced regression-tested corrections for:

- bounded feed qualification and explicit invalidation of replaced feeds;
- partial-inventory Attention retention;
- action-generation advancement only at dispatch;
- fail-closed adapter and stale-name boundary scans;
- child-process completion when descendants inherit output descriptors;
- one-shot descriptor close handling;
- vanished-process tolerance during Shared Desktop inspection;
- isolated unexpected-error reporting in hook adapter tests;
- exact assertion reconciliation.

A suggestion to replace the accepted Unix-socket WebSocket transport was not
applied. The production transport remains the already validated
`codex app-server proxy --sock` boundary; changing it requires contrary runtime
evidence rather than a speculative review substitution.

## Phase 3 gate

```sh
swift build
swift run conn-codex-adapter-tests
swift run conn-domain-tests
swift run conn-app-core-tests
./scripts/check-conn-domain-boundary.sh
./scripts/check-conn-codex-adapter-boundary.sh
./scripts/generate-codex-app-server-schemas.sh verify
./scripts/test-inspect-release.sh
./scripts/build-app.sh --debug
codesign --verify --deep --strict .build/conn-app/Conn.app
plutil -lint .build/conn-app/Conn.app/Contents/Info.plist
git diff --check
```

The required Phase 3 checkpoint is
`refactor: implement Codex integration adapter`.
