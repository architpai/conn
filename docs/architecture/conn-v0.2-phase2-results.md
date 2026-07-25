# Conn v0.2 Phase 2 results

Status: implementation complete on `cdx/v0.2-provider-neutral`.

Phase 2 establishes the neutral domain and Integration port beside the legacy
App Server-shaped domain. No production composition or runtime wiring changes
in this phase.

## Added contract

- Stable `HarnessID` and opaque `IntegrationID`.
- Composite `ConnSessionID` from Integration identity and upstream identity.
- Optional evidence-backed `RunID`; Activities may remain Session-scoped.
- Runtime-only, non-Codable Integration connection generation and response
  authority.
- Immutable Sendable snapshots, semantic updates, capabilities, availability
  inputs, actions, and action outcomes.
- Atomic `ConnIntegrationFeed` with a snapshot `throughSequence` watermark and
  a bounded ordered update stream.
- Typed `ConnIntegrationError`; provider errors and response tokens cannot
  cross the port.
- Bounded runtime-only action text, Workspace paths, and structured answers.
- Deterministic per-Integration projection reduction with complete versus
  partial inventory authority, Session-specific current authority, duplicate
  suppression, stale-generation rejection, and fail-stale sequence-gap
  handling.
- Neutral checkpoint values and structural validation without restoring
  connection generation, capabilities, Attention Requests, or action
  authority.

The legacy `AppServer*` domain remains compileable as migration evidence for
the Phase 2 through Phase 5 coexistence window.

## Contract evidence

The Domain suite grew from the Phase 1 denominator of 83 assertions to 142:
59 Phase 2 assertions cover:

- identical upstream IDs in simultaneous Integrations;
- the test-only non-Codex monitor-only Integration;
- Session-scoped Activities without synthetic Runs;
- UTF-8, line, collection, inventory, and action-payload bounds;
- complete inventory removal versus partial inventory retention;
- non-authoritative Sessions omitted from a partial snapshot;
- ordered update application, duplicate suppression, and consumed no-op
  watermark advancement;
- stale-generation isolation and forward-gap fail-stale behavior;
- capability and authority inputs scoped to one Integration;
- evidence-backed Run references and Attention pruning;
- malformed scope, identity, Run, bounds, and checkpoint rejection;
- a post-watermark update racing feed creation being delivered exactly once;
- unavailable outcomes for unsupported synthetic actions.

`scripts/check-conn-domain-boundary.sh` fails if ConnDomain imports AppCore,
adapter, AppKit, or SwiftUI modules, and distinguishes a clean no-match result
from an `rg` scan failure.

## Review corrections

The Phase 2 review identified and regression-tested:

1. consumed missing-entity updates must advance the sequence watermark;
2. complete snapshots cannot validate Attention against a Run removed from the
   incoming inventory;
3. Session replacement prunes Attention tied to removed Runs;
4. every fail-stale bounds path clears Session authority;
5. leading-newline presentation input preserves an empty first line;
6. dependency scans fail closed when their search cannot run.

The reviewer also reported a pre-existing Compact Shelf documentation concern.
That file remains outside the Phase 2 checkpoint and was not changed.

## Phase 2 gate

The checkpoint requires:

```sh
swift build
swift run conn-domain-tests
./scripts/check-conn-domain-boundary.sh
swift run conn-app-server-adapter-tests
swift run conn-app-core-tests
./scripts/generate-codex-app-server-schemas.sh verify
./scripts/test-inspect-release.sh
./scripts/build-app.sh --debug
codesign --verify --deep --strict .build/conn-app/Conn.app
plutil -lint .build/conn-app/Conn.app/Contents/Info.plist
git diff --check
```

The required Phase 2 checkpoint is
`refactor: add provider-neutral Conn domain`.
