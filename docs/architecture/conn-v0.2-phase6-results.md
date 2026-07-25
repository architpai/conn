# Conn v0.2 Phase 6 results

Status: Complete

Phase 6 removes the legacy production architecture. Provider-shaped protocol,
projection, control, diagnostics, and migration code now lives only inside
`ConnCodexAdapter`, Codex composition, or adapter parity-test support.

## Production boundary

- `ConnDomain` contains only Integration, Session, Run, Activity, Attention,
  action, and neutral checkpoint semantics.
- `ConnAppCore` depends only on `ConnDomain` and owns aggregation,
  presentation, persistence, outcomes, notifications, Session selection, and
  generic shell policy.
- `ConnUI` depends only on Domain and AppCore.
- `ConnCodexAdapter` owns the App Server protocol and Codex implementation.
- `ConnApp` is the composition and migration edge, including
  `LegacyHookRetirementStore` and the exact-identity legacy-plugin
  confirmation UI.
- the Phase 5 legacy UI migration evidence is deleted.

Provider-shaped v0.1 presentation helpers remain compileable only under
`Tests/ConnCodexAdapterTests/LegacySupport`; they do not ship in the app.

## Assertion reconciliation

No assertion was silently discarded. The exact frozen total was reassigned by
the owner of the behavior:

| Owner | Reconciled assertions |
| --- | ---: |
| ConnDomain | 67 |
| ConnAppCore | 217 |
| ConnUI | 192 |
| ConnApp composition migration edge | 14 |
| ConnCodexAdapter, including provider-shaped parity | 1,451 |

The 83 provider-projection assertions formerly compiled in Domain, 366
provider presentation/control assertions formerly compiled in AppCore, and 18
Codex-specific UI-policy assertions now run under the Codex adapter suite.
Neutral additions remain with their current owners.

## Gate

```sh
swift build
swift run conn-domain-tests
swift run conn-app-core-tests
swift run conn-ui-tests
swift run conn-codex-adapter-tests
./scripts/test-conn-migration-edge.sh
./scripts/check-provider-boundaries.sh
git diff --check
```

Checkpoint: `refactor: remove App Server-shaped core`
