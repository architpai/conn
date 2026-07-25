# Conn v0.2 Phase 5 results

Status: Complete

Phase 5 atomically replaces the legacy application edge with the
provider-neutral Integration path. The built application now creates one
`CodexIntegration`, supervises it through `ConnIntegrationCoordinator`, and
presents it through `ConnUI`.

## Implemented

- created the `ConnUI` production module for the generic view model, SwiftUI
  surface, panel, hot key, accessibility, Reduce Motion, display geometry, and
  interaction policy;
- removed Codex, App Server, Shared Desktop, wire-format, and control-endpoint
  names and imports from the generic UI;
- added a statically typed `@ViewBuilder` Integration-settings slot and
  composed `CodexIntegrationSettingsView` only at the `ConnApp` edge;
- switched generic product language from Threads to Sessions;
- exposed semantic approval choices and structured questions through bounded
  Domain values while retaining provider tokens and envelopes in the adapter;
- switched production startup to the neutral projection root and quarantined
  the disposable v0.1 App Server projection;
- retained Conn as the primary brand and used the documented accessible
  `Codex` text badge fallback pending clearance for the exact OpenAI logo
  placement;
- moved the assigned 210 generic shell and UI assertions into the required
  `conn-ui-tests` executable;
- moved the former application UI sources out of production and retained them
  temporarily under `MigrationEvidence/ConnLegacyUI` for Phase 6 deletion.

## Gate

```sh
swift build
swift run conn-ui-tests
./scripts/check-conn-ui-boundary.sh
git diff --check
```

Result: all commands pass; `conn-ui-tests` reports 210 of 210 assertions.

Checkpoint: `refactor: cut Conn over to integration architecture`
