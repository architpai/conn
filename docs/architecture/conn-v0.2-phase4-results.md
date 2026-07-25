# Conn v0.2 Phase 4 results

Status: Complete

Phase 4 replaces the singleton-provider application seam with one deep
provider-neutral AppCore module. `ConnIntegrationCoordinator` owns Integration
supervision, ordered reduction, requalification, action routing, persistence,
and aggregate publication behind a small asynchronous interface.

## Implemented

- simultaneous Integration aggregation with Integration-scoped generation,
  freshness, inventory, capability, and membership;
- exact ordered-update handling with duplicate suppression and fail-stale
  requalification after gaps or rejected semantic state;
- failure and partial-inventory isolation between Integrations;
- action availability derived from local capability, live Session authority,
  active Run evidence, and exact Attention response authority;
- action dispatch routed only by opaque Integration and composite Session
  identity;
- explicit adapter disconnect that cancels Conn feed/transport work without
  stopping Harness-owned Sessions or daemon work;
- a neutral checkpoint discriminator and restore path that cannot recreate
  generation, capability, Attention, or action authority;
- a new owner-only `Conn/IntegrationProjection/v1` two-slot checkpoint store
  with atomic generations, bounded trimming, corruption fallback, and no
  provider-shaped root reuse;
- neutral Integration, Session, Project, Activity, Attention, Harness
  attribution, picker, outcome-review, and user-facing notification
  presentation;
- a clean `connOutcomeReviewLedger.v2` baseline rather than decoding the
  provider-shaped v0.1 outcome ledger.

## Provider-neutral seam proof

The Phase 4 contract test composes two live fixtures simultaneously:

- a controllable Codex-shaped Integration with an evidence-backed Run; and
- a monitor-only synthetic Integration with a Session-scoped Activity and no
  Run.

The test proves:

- identical upstream Session IDs cannot collide or retarget actions;
- capability and action authority cannot be borrowed across Integrations;
- actions reach only the exact target Integration;
- partial inventory and sequence-gap failure remain isolated;
- proven Workspace equivalence groups Sessions across Harnesses while retaining
  row-level Harness attribution;
- restored state stays visible but non-actionable;
- first hydration does not replay notifications or historical outcomes.

## Assertion reconciliation

| Surface | Phase 3 | Phase 4 additions | Phase 4 total |
| --- | ---: | ---: | ---: |
| ConnDomain | 142 | 8 | 150 |
| ConnAppCore owner | 541 | 42 | 583 |
| ConnUI assigned migration evidence | 210 | 0 | 210 |
| ConnApp composition evidence | 14 | 0 | 14 |
| ConnCodexAdapter parity | 1,002 | 0 | 1,002 |

The frozen Phase 1 owner denominators remain intact. Phase 4 additions are
contract evidence above those denominators and do not retire legacy tests
before the atomic cutover.

## Gate

```sh
swift build
swift run conn-domain-tests
swift run conn-app-core-tests
swift run conn-codex-adapter-tests
./scripts/check-conn-domain-boundary.sh
./scripts/check-conn-codex-adapter-boundary.sh
git diff --check
```

Checkpoint: `refactor: add neutral integration aggregation`
