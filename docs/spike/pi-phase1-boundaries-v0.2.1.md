# External Pi Phase 1 boundary results

Date: 2026-07-29

Status: passed

## Established seams

- Added `ConnPiAdapter -> ConnDomain` and its independent executable test
  suite.
- Removed the stale `ConnAppCoreTests -> ConnCodexAdapter` package edge.
- Added the pinned `@earendil-works/pi-coding-agent` 0.82.1 TypeScript
  workspace. The exact extension resource packaged by SwiftPM is the file
  type-checked against Pi's supported extension types.
- Added the stable `pi` Harness and `pi.external` Integration identities.
- Added a closed, bounded, authenticated registration handshake. Oversized,
  malformed, unknown, stale-generation, and wrong-secret inputs fail closed.
- Removed `open` from `ConnActionKind` and `ConnAction`. Opening is now a
  typed, composition-owned route with synchronous pre-click availability.
  Codex retains its qualified app route; external Pi advertises none.
- Added Pi-aware provider, Domain, AppCore, UI, and adapter mechanical boundary
  checks.

## Verification

- `swift build`
- `swift run conn-domain-tests` — 76 assertions
- `swift run conn-app-core-tests` — 243 assertions
- `swift run conn-codex-adapter-tests` — 1,470 assertions
- `swift run conn-pi-adapter-tests` — 9 assertions
- `swift run conn-ui-tests` — 250 assertions
- pinned Pi extension TypeScript check
- all five provider/module boundary checks
- `git diff --check`

The original tagged baseline failure in `check-conn-ui-boundary.sh` was an
obsolete exact formatting assertion for a one-entry Codex asset dictionary.
Phase 1 replaced it with ownership and typed-opener assertions; the script now
passes without weakening the provider-neutral scan.
