# Conn v0.2 Phase 1 parity contract

Status: frozen on `cdx/v0.2-provider-neutral` on 2026-07-24.

This document is the numeric and behavioral baseline for the provider-neutral
refactor. Later phases must reconcile against the assigned owner totals below,
not merely keep a combined suite green.

## Validation baseline

The following passed before structural source movement:

| Check | Frozen result |
| --- | --- |
| `swift build` | Pass |
| `swift run conn-app-server-adapter-tests` | Pass, 227 assertions |
| `swift run conn-domain-tests` | Pass, 83 assertions |
| `swift run conn-app-core-tests` | Pass, 1,510 assertions |
| `./scripts/test-inspect-release.sh` | Pass |
| `./scripts/generate-codex-app-server-schemas.sh verify` | Pass for pinned 0.144.5 and 0.144.6 schemas |
| `./scripts/build-app.sh --debug` | Pass |
| `codesign --verify --deep --strict .build/conn-app/Conn.app` | Pass |
| `plutil -lint .build/conn-app/Conn.app/Contents/Info.plist` | Pass |
| `git diff --check` | Pass |

The working tree already contained the agreed v0.2 planning documents and the
user's Compact Shelf edits in `docs/architecture/domain-model.md`. They are
preserved as intentional inputs to this branch.

Phase 1 then added 12 checkpoint privacy assertions. The post-canary suite is
1,522 AppCore assertions and 1,832 assertions overall.

## Allowed parity differences

Only these intentional changes are excluded from strict Codex parity:

1. Thread-facing copy becomes Session terminology.
2. Sessions gain visible Harness attribution, using the OpenAI mark for Codex
   when cleared and a neutral/text fallback otherwise.
3. Product framing becomes Harness and Integration based.
4. Persistence makes one clean, atomic reset to the neutral schema.

All other supported Codex behavior remains equivalent through the cutover.

## Behavior matrix

| Behavior | Frozen evidence | v0.2 owner | Required parity |
| --- | --- | --- | --- |
| Connection, discovery, compatibility, daemon lifecycle | Adapter Phase 6, endpoint, transport, protocol tests | ConnCodexAdapter | Preserve qualification, non-ownership, reconnect, and pinned-schema behavior |
| Monitoring and semantic observation | Phase8StructuredMonitoring, Phase85Adapter, Phase87ProjectionPrivacy | ConnCodexAdapter | Map bounded semantic facts; raw payloads never cross the adapter |
| Full pagination and inventory authority | Phase85RuntimeRecovery | ConnCodexAdapter | Follow every cursor, distinguish complete/partial inventory, fail stale on loss |
| Projection, ordering, reduction | Phase7AppServerProjection | ConnDomain | Preserve deterministic ordering, freshness, identity, and bounded state |
| Runtime qualification and recovery | Phase8RuntimePolicy, Phase85RuntimeRecovery | ConnAppCore and ConnCodexAdapter | Preserve generation checks, recovery, and no false-live claims |
| Follow-up, steer, interrupt, new Session | Phase9ThreadControl, Phase9ThreadControlRuntime | ConnAppCore and ConnCodexAdapter | Preserve exact target/precondition authority and never replay uncertainty |
| Attention requests, approvals, questions | Phase8PresentationPayload, Phase9 control cases | ConnAppCore and ConnCodexAdapter | Preserve scope, typed choices, structured answers, and response authority |
| Outcomes and review | Phase92OutcomeReview | ConnAppCore | Preserve evidence-backed outcome and review policy |
| Checkpoint persistence and restore | Phase7PersistenceMigration, Phase88Durability, Phase87ProjectionPrivacy | ConnAppCore and ConnCodexAdapter | Clean schema cut; restore stale and non-actionable; retain bounded presentation only |
| Notifications | Phase115NotificationPolicy | ConnAppCore | Preserve suppression, freshness, and user-facing notification policy |
| Shared Desktop | Phase10 Shared Desktop cases and host inspector | ConnCodexAdapter; typed slot composed by ConnApp | Preserve diagnosis, setup, runtime proof, rollback, and Codex-only framing |
| Shell, accessibility, keyboard, motion | Phase4ShellPolicy, Phase8ShellRegression, Phase87Shell, Phase115 UI and motion | ConnUI and ConnAppCore | Preserve geometry, interaction, accessibility, and Reduce Motion behavior |
| Legacy hook retirement | Phase11HookVisibility, Phase11LegacyHookRetirement | ConnCodexAdapter and ConnApp | Preserve migration evidence; do not generalize it into the neutral domain |
| Legacy plugin retirement | Phase11LegacyPluginRetirement | ConnCodexAdapter with confirmation UI composed by ConnApp | Preserve detection and explicit confirmation |
| Session selection | Phase115ThreadPickerPolicy | ConnAppCore | Translate to neutral `SessionPickerPolicy` without behavior loss |

## Test ownership and denominators

The frozen v0.1 total is 1,820 assertions. After the 12 Phase 1 privacy
assertions, the migration denominator is:

| Assigned v0.2 owner | v0.1 assertions | Phase 1 additions | Required denominator |
| --- | ---: | ---: | ---: |
| ConnCodexAdapter | 972 | 12 | 984 |
| ConnDomain | 83 | 0 | 83 |
| ConnAppCore | 541 | 0 | 541 |
| ConnUI | 210 | 0 | 210 |
| ConnApp composition and retirement edge | 14 | 0 | 14 |
| **Total** | **1,820** | **12** | **1,832** |

The ConnCodexAdapter total includes all 227 assertions currently in
`ConnAppServerAdapterTests` plus the adapter-owned cases currently housed in
`ConnAppCoreTests`.

### ConnAppCoreTests case assignment

| Test case | Owner | Assertions after Phase 1 |
| --- | --- | ---: |
| Phase3AppCore | ConnAppCore | 105 |
| Phase4ShellPolicy | ConnAppCore | 32 |
| Phase7PersistenceMigration | ConnAppCore | 42 |
| Phase8StructuredMonitoring | ConnCodexAdapter | 92 |
| Phase8RuntimePolicy | ConnAppCore | 14 |
| Phase8ShellRegression | ConnUI | 35 |
| Phase8PresentationPayload | ConnAppCore | 68 |
| Phase85Adapter | ConnCodexAdapter | 54 |
| Phase85ProjectPresentation | ConnAppCore | 14 |
| Phase85RuntimeRecovery | ConnCodexAdapter | 177 |
| Phase87ProjectionPrivacy | ConnCodexAdapter | 41 |
| Phase87Presentation | ConnAppCore | 58 |
| Phase87Shell | ConnUI | 68 |
| Phase88Durability | ConnAppCore | 38 |
| Phase9ThreadControl | ConnAppCore | 80 |
| Phase9ThreadControlRuntime | ConnCodexAdapter | 128 |
| Phase92OutcomeReview | ConnAppCore | 27 |
| Phase10SharedDesktopMode | ConnCodexAdapter | 57 |
| Phase10SharedDesktopDiagnostics | ConnCodexAdapter | 55 |
| Phase10SharedDesktopSetup | ConnCodexAdapter | 52 |
| Phase10SharedDesktopRuntime | ConnCodexAdapter | 37 |
| Phase11HookVisibility | ConnCodexAdapter | 48 |
| Phase11LegacyHookRetirement | ConnApp composition/retirement | 14 |
| Phase11LegacyPluginRetirement | ConnCodexAdapter | 16 |
| Phase115UIOverhaul | ConnUI | 91 |
| Phase115CompactShelfMotion | ConnUI | 16 |
| Phase115NotificationPolicy | ConnAppCore | 46 |
| Phase115ThreadPickerPolicy | ConnAppCore | 17 |

All seven `ConnAppServerAdapterTests` case files are assigned to
ConnCodexAdapter: EndpointDiscovery, Phase10SharedDesktopHostInspector,
Phase6Connection, Phase6Lifecycle, Phase7InboundEnvelope, Protocol, and
Transport. `Phase7AppServerProjectionTestCases` is assigned to ConnDomain.
Runner and test-support files follow their owning test target and do not add
behavioral cases.

There are 36 behavioral `*TestCases.swift` files: 28 in ConnAppCoreTests,
seven in ConnAppServerAdapterTests, and one in ConnDomainTests.

## Source inventory and migration disposition

The source baseline is:

| Current target | Swift files | Lines |
| --- | ---: | ---: |
| ConnDomain | 3 | 3,761 |
| ConnAppCore | 18 | 14,435 |
| ConnApp | 5 | 5,425 |
| ConnAppServerAdapter | 19 | 5,007 |
| ConnPackagingProbe | 1 | 3 |

Every production source has the following named disposition:

- `ConnDomain/AppServerDomainModels.swift`,
  `AppServerHookProjection.swift`, and `AppServerProjectionStore.swift` remain
  as compileable migration evidence through Phase 5, while neutral domain
  types are added beside them in Phase 2; Phase 6 removes the App Server-shaped
  surface after parity reconciliation.
- All 19 files currently under `ConnAppServerAdapter` move into or are
  restructured under ConnCodexAdapter: AppServerCompatibility,
  ConnAppServerConnection, ProductionConnectionFactory, BoundedProcessRunner,
  CodexExecutableDiscovery, ControlEndpoint, ControlTransport,
  EndpointDiscovery, ManagedDaemonLifecycle, ProxyStdioTransport,
  UnixWebSocketTransport, ConnConnectionTrace, ControlTransportObservation,
  SharedDesktopHostInspector, InitializeModels, JSONRPCWireMessage, JSONValue,
  RequestCorrelationStore, and RequestID.
- From current ConnAppCore, AppServerMonitoringRuntime,
  AppServerObservationAdapter, AppServerThreadControlRuntime,
  SharedDesktopDiagnosticsCoordinator, SharedDesktopLaunchAgentManager,
  SharedDesktopModeModels, and SharedDesktopSetupCoordinator move to
  ConnCodexAdapter.
- AppServerDomainCheckpointFileStore, AppServerDomainCoordinator,
  AppServerHookPresentation, AppServerMonitoringPresentation,
  AppServerOutcomeReview, AppServerThreadControlModels, ShellModels, and
  ShellUserFacingNotificationPolicy are translated into provider-neutral
  ConnAppCore responsibilities; App Server-shaped names and dependencies are
  removed at the Phase 5/6 cut.
- `ThreadPickerPolicy.swift` becomes neutral
  `SessionPickerPolicy.swift` in ConnAppCore.
- `LegacyHookRetirementStore.swift` moves to the ConnApp migration edge.
- `LegacyPluginRetirementRuntime.swift` moves to ConnCodexAdapter, while its
  confirmation UI is composed by ConnApp.
- `ConnPanelController.swift`, `ConnSurfaceView.swift`, `ConnViewModel.swift`,
  and `GlobalHotKey.swift` move to ConnUI after provider state is removed.
  `ConnApplication.swift` remains the ConnApp composition root.
- `ConnPackagingProbe/main.swift` remains packaging-only.

No file is assigned to an unspecified compatibility layer or future Harness
stub.

## Privacy canaries

Phase 1 tests place distinct canaries at runtime-only boundaries for raw
provider values, prompt drafts, structured answers, approval decisions,
response tokens, and authentication material. Each canary is proven present in
its runtime fixture and absent from the encoded projection checkpoint.

The existing canaries continue to cover patch text, plan explanations, image
URLs, skill paths, Git origin and SHA, branch, token usage, plan text, and user
text. Phase 7 must additionally verify the sensitive canaries are absent from
logs, notices, and diagnostics in the built application.

## Reconciliation rule

A later phase may relocate or translate a test, but it must preserve its
assigned owner and assertion evidence until an explicit retirement rationale
is recorded here. Whole-suite equality cannot compensate for a missing owner
denominator. The clean persistence reset is the sole planned retirement of old
durable data behavior; privacy, authority, no-replay, and non-ownership tests
may not be retired.
