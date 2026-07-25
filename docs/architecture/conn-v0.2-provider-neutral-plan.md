# Conn v0.2 provider-neutral foundation

Status: Accepted for implementation planning; implementation not started

## Release intent

Conn v0.2.0 will continue to support Codex only at runtime while replacing the
Codex App Server-shaped application boundary with provider-neutral Conn domain
and integration contracts. Existing supported Codex behavior must remain
available through a Codex adapter.

The release lays the foundation for later Claude Code, Pi, OpenCode, and other
harness integrations. It does not claim those harnesses are supported in v0.2.

## Resolved decisions

### The v0.2 integration API is internal

The Conn Integration API will be an internal Swift module boundary. It will not
be a public plugin API, stable binary ABI, IPC protocol, or drop-in adapter
contract in v0.2.

Future integrations can validate and evolve the semantic contract in source
before Conn commits to third-party compatibility. An external plugin mechanism
may be designed later from evidence gathered across multiple working adapters.

### Conn aggregates integrations simultaneously

The Conn domain will model a collection of active integrations rather than one
selected harness. Future Codex, Claude Code, Pi, OpenCode, and other sessions
may appear together in the same supervision surface. Conn v0.2 will compose
only the Codex integration, but must not restore a singleton-provider
assumption above the adapter boundary.

Upstream session identifiers are scoped by their integration identity so that
identical provider-issued values cannot collide.

Each session row will use the harness logo as its primary visual attribution.
The attribution must also have a text or accessibility representation and a
fallback for integrations without a bundled logo; provider identity cannot be
communicated by an image alone.

### Session is Conn's cross-harness work term

A `ConnSession` is the provider-neutral conversation or continuing unit of
work shown by Conn. Each adapter maps its upstream concept into a Conn Session:
for example, a Codex Thread maps to a Conn Session without making Thread part
of the shared domain contract.

The generic UI language will change from Threads to Sessions in v0.2. Codex
adapter code and Codex-specific diagnostics may continue to use Codex Thread
where that upstream distinction matters.

### Normal integrations do not own harness work

Conn remains a non-owning companion across harnesses. Closing, crashing, or
disconnecting Conn must not terminate a supervised session or its running
process.

Session creation origin, lifecycle ownership, and retention are modeled
independently. Current New Chat behavior maps to a Conn-originated,
harness-owned, ephemeral Session: Conn requests creation, Codex App Server
acknowledges and owns the resulting Thread, and the upstream `ephemeral` flag
describes retention rather than ownership.

Any future Conn-owned harness mode requires a separate product and architecture
decision and cannot masquerade as a normal adapter.

### Identity follows Harness, Integration, then Session

A Harness identifies the external product family and supplies brand-level
metadata such as its name and logo. An Integration identifies one independently
connected and qualified source with its own authority, freshness, capabilities,
configuration, and failure state.

Each Conn Session identity is scoped by its Integration and upstream session
identity. The domain permits multiple Integrations for one Harness even though
v0.2 composes exactly one Codex Integration.

Shared Desktop qualification remains mode and evidence state on the existing
Codex Integration when it observes the same managed daemon; it does not create
a second Integration merely because another client shares that source.

### Capabilities and current action availability are separate

An Integration advertises only capabilities proven for its current version and
mode. Conn never infers support from the Harness brand or assumes that every
Integration of the same Harness has identical authority.

For a consequential action, the application additionally derives dynamic
Session Action Availability from the Integration capability, current
connection authority, freshness, Session state, active Run, pending request,
and any action-specific preconditions. UI controls consume this availability
rather than consulting adapter or protocol details.

### The action catalog is a semantic superset

The internal API defines the union of meaningful Conn Actions rather than only
the intersection supported by every Harness. Initial actions include creating a
Session, following up, steering an active Run, interrupting a Run, answering a
question, resolving an approval, and opening a Session in its Harness.

Each Integration supports a proven subset. The shared contract has no arbitrary
provider method, raw JSON command, or similar escape hatch. Provider protocol
methods remain inside adapters, and a new operation enters the shared catalog
only after its Conn-domain meaning is defined.

### Runs are optional and evidence-backed

A Conn Session may contain Runs, Activities, and Attention Requests. A Run is a
bounded interval of harness work, such as a Codex Turn, but exists only when an
Integration has upstream evidence for its boundary and identity.

Activities and Attention Requests always belong to a Conn Session and may
reference a Run. If an Integration cannot prove a stable Run boundary, it emits
Session-scoped facts instead of inventing synthetic Runs. Run-targeted actions
require a grounded active Run or equivalent explicit upstream authority.

### Raw provider payloads do not cross the adapter boundary

Provider envelopes, method names, event structures, schema details,
authentication state, transport state, raw hooks, and provider-specific errors
remain inside their adapter. ConnDomain, ConnAppCore, UI presentation, logs, and
checkpoints accept only bounded provider-neutral facts and results.

An unmapped upstream event may become a conservative bounded unknown Activity
or aggregate diagnostic, but arbitrary JSON and provider objects cannot be
carried through a generic payload field. Supporting a new meaningful fact
requires an explicit domain mapping and tests.

The Codex migration therefore moves App Server observation parsing and mapping
behind the Codex adapter rather than merely wrapping the existing
AppServer-shaped AppCore runtime.

### Integrations deliver snapshots and ordered semantic updates

Each Integration exposes its identity, one atomic feed containing a qualified
watermarked snapshot and ordered stream of bounded semantic updates, semantic
action execution, and explicit connection lifecycle operations.

Updates carry Integration identity, connection generation, monotonic sequence
within that generation, the semantic change, and authority or freshness
evidence. The snapshot carries the greatest sequence it already reflects, and
the feed buffers later updates so snapshot-to-stream handoff cannot race. A
reconnect changes generation; older updates cannot regain current authority,
and previously live state remains stale until requalified.

Adapters own connection lifecycle, retries, pagination, provider parsing,
qualification, and semantic mapping. ConnAppCore aggregates Integrations,
reduces semantic updates, persists bounded neutral checkpoints, derives action
availability, and produces presentation. The UI consumes presentation and
submits Conn Actions without importing an adapter.

### v0.2 makes a clean persistence cut

Provider-neutral preferences such as appearance, display selection, workspace,
grouping, and applicable Shared Desktop settings remain in place.

The provider-neutral projection uses a new root, discriminator, and schema. The
disposable App Server projection cache is quarantined or ignored, and Codex
rehydrates authoritative state through the new Integration. Provider-shaped
Session ordering and outcome-review ledgers are not decoded into the new
domain: manual Session order resets once, and outcome review begins from a
fresh baseline so historical completions do not appear new.

No legacy `AppServer*` decoder or compatibility representation enters the new
Conn domain. The old cache remains disposable and recoverable only as migration
evidence until the v0.2 release process explicitly retires it.

### Integration failures and freshness are isolated

Connection health, authority, freshness, inventory completeness, capability
loss, authentication failure, and repair state belong to one Integration.
Failure or reconnect of one Integration cannot make unrelated Sessions stale,
unavailable, or globally offline.

Sessions from an affected Integration remain rehydrated or stale with
consequential actions unavailable while other Integrations continue normally.
The aggregate surface summarizes partial health but retains exact
Integration-level evidence.

A Session is removed only after its Integration supplies authoritative complete
membership evidence that it is absent, or when the user removes that
Integration. Disconnects, partial inventories, truncation, and failed refreshes
never authorize removal.

### v0.2 exposes only the real Codex Integration

The generic UI language changes from Threads to Sessions. Subject to brand
clearance, Session rows show the official OpenAI mark as compact visual
attribution with the accessible and text Harness label `Codex`. Conn's own logo
remains the application and product identity. Connection state appears through
a generic Integration status presentation. Codex-specific daemon, version,
schema, transport, and Shared Desktop diagnostics remain available under that
Codex Integration.

The preferred OpenAI mark must be sourced from official OpenAI brand resources,
used without redrawing or modification, and validated against the current
[OpenAI brand guidelines](https://openai.com/brand/) before release. Asset
provenance and trademark attribution are recorded with the release artifacts.
If brand review does not clear third-party in-product logo use, Conn ships a
`Codex` text badge or neutral Harness glyph with the same accessible label;
logo clearance cannot block the v0.2 architecture release.

v0.2 does not show Add Integration controls, disabled Claude/Pi/OpenCode cards,
or coming-soon provider affordances. Integration management arrives with the
second working adapter, when its workflow can be based on runtime evidence.

### Production cuts over atomically

Implementation may proceed incrementally on the v0.2 branch, with old code and
fixtures retained temporarily as migration evidence. The released application
has exactly one production path:

`Codex App Server -> Codex Integration adapter -> ConnAppCore -> Conn UI`

No feature flag, fallback reducer, duplicate projection, or legacy checkpoint
path may route production back through the App Server-shaped core. After parity
is proven, provider-shaped production code survives only inside the Codex
adapter and its tests.

### Compiler boundaries use five production targets

The streamlined target graph is:

- `ConnDomain`: neutral models, deterministic reducers, and the internal
  `ConnIntegration` port.
- `ConnAppCore`: multi-Integration aggregation, neutral persistence, action
  availability, and presentation.
- `ConnCodexAdapter`: App Server transport, daemon lifecycle, schemas, parsing,
  qualification, mapping, diagnostics, and semantic action execution.
- `ConnUI`: view model, AppKit/SwiftUI surface, and UI interaction policy.
- `ConnApp`: executable composition root that installs the Codex adapter and
  composes Codex-only integration settings for v0.2.

The integration port does not receive a separate target. `ConnDomain` and
`ConnAppCore` remain separate because their deterministic domain and
orchestration responsibilities are already substantial. `ConnUI` remains
separate from the executable so views cannot import `ConnCodexAdapter`; only
the composition root depends on both.

The exact SwiftPM production dependency edges are:

- `ConnDomain` has no Conn production-target dependency.
- `ConnAppCore -> ConnDomain`.
- `ConnCodexAdapter -> ConnDomain`.
- `ConnUI -> ConnDomain + ConnAppCore`.
- `ConnApp -> ConnDomain + ConnAppCore + ConnCodexAdapter + ConnUI`.

`ConnAppCore -> ConnCodexAdapter` and `ConnUI -> ConnCodexAdapter` are forbidden
even if a transitive or convenience dependency would make the package build.

### Shared Desktop remains a composed Codex feature

Shared Desktop Mode remains supported in v0.2 but is not generalized into the
Conn domain. `ConnCodexAdapter` owns its daemon inspection, setup, verification,
rollback, Session proof, compatibility, and mode state.

The neutral core observes only the resulting Integration scope, freshness,
capabilities, and Session evidence. Generic `ConnUI` contains no
`SharedDesktop*` types. The `ConnApp` composition target hosts the Codex-only
Labs and settings presentation and connects it to the adapter.

The composition seam is a typed SwiftUI content slot defined by `ConnUI`, such
as a generic `IntegrationSettingsContent: View` supplied with `@ViewBuilder`.
`ConnUI` owns only the placement, navigation, sizing, accessibility, and
dismissal behavior of that slot. `ConnApp` supplies a concrete
`CodexIntegrationSettingsView` and Codex settings model that may import
`ConnCodexAdapter`. The slot carries no `AnyView`, opaque action identifiers,
provider dictionaries, or generic JSON. The generic `ConnViewModel` and
`ConnSurfaceView` are split from the Codex settings model/view rather than
passing Shared Desktop state through neutral-looking bags.

Future adapters may compose source-level setup UI until multiple real
integrations justify a shared settings contract. v0.2 does not invent a generic
plugin or settings schema around one Codex-specific feature.

### Codex behavior remains at strict parity

Except for the agreed Session terminology, Harness attribution, generic
Integration framing, and clean persistence cut, v0.2 preserves existing Codex
behavior. This includes managed-daemon recovery, complete pagination and
inventory authority, reconnect and stale-state behavior, bounded overload
recovery, history and Activity presentation, outcomes, notifications, Compact
Shelf behavior, ephemeral Session creation, follow-up, steer, interrupt,
approvals, structured answers, acknowledgement uncertainty, Shared Desktop
setup and rollback, privacy bounds, accessibility, Reduce Motion, display
selection, and notch-shell behavior.

Existing tests are translated to the new boundaries rather than deleted because
their old types no longer compile. Any intentional behavior change requires a
separate documented v0.2 decision.

### Action outcomes preserve consequential uncertainty

The shared action contract distinguishes unavailable local preconditions,
definite provider rejection, exact acceptance, acknowledgement uncertainty,
connection invalidation, and resolution by another client. It never reduces a
consequential result to a Boolean.

Adapters map provider outcomes conservatively. A transport or decoding failure
after a consequential send is acknowledgement-uncertain unless upstream
evidence proves rejection. Conn never automatically retries an uncertain
action, and presentation explains the semantic outcome without exposing raw
provider errors.

### Attention Requests and Session Issues are distinct

Attention is the umbrella for conditions that warrant user awareness. An
Attention Request is an authoritative upstream request that Conn can answer or
resolve, such as an approval or structured question. A Session Issue is a
failure or degraded Session condition requiring inspection but carrying no
upstream response authority.

The Attention State may present both while preserving their different action
semantics. Integration repair is likewise an Integration issue, not a Session
request. The UI never presents a response control merely because a failure
needs attention.

### Projects group proven shared Workspaces across Harnesses

Project and Workspace remain the primary Session hierarchy. Sessions from
different Harnesses may appear in one Project when Conn has safe evidence that
their Integration-scoped Workspace identities refer to the same source
location. Harness logos remain row-level attribution.

Matching display names or ambiguous remote path strings never prove Workspace
equivalence. Unproven Workspaces remain separate. Harness-specific filtering
may be added later but does not become the primary navigation hierarchy.

### Checkpoints contain bounded presentation state only

The neutral checkpoint may retain Harness and Integration identifiers, scoped
Session and Run identifiers, titles, proven Workspace attribution, bounded
Activity presentation, timestamps, terminal outcome metadata, and ordering
under the new composite identities.

It never persists raw provider payloads, authentication or transport state,
connection generations, live authority, Attention Requests or response tokens,
action availability or capability proof, prompt and answer drafts, approval
decisions, uncertain actions, or unbounded transcripts.

Every restored Session begins rehydrated or stale and non-actionable. Fresh
Integration evidence is required to make it live, restore capabilities,
recreate an Attention Request, or enable a consequential action.

### Integration identity is stable and opaque

Harness IDs are well-known product-family identifiers. Integration IDs are
opaque Conn-controlled configuration identifiers and never encode account,
authentication, path, socket, or upstream Session information.

The sole built-in Codex Integration in v0.2 uses one reserved stable
Integration ID. Future configured Integrations receive generated stable IDs.
Reconnect preserves the Integration ID while changing its runtime connection
generation. Removing and recreating an Integration creates a new Integration
ID so stale checkpoints and authority cannot attach accidentally.

Conn Session identity combines Integration ID with the upstream Session ID.

### Update streams are bounded per Integration

Each Integration has independent bounded buffering so a noisy Harness cannot
starve other Integrations. Replaceable high-frequency Activity deltas may be
coalesced by Session and Activity identity.

Lifecycle transitions, terminal outcomes, inventory authority changes,
Attention Requests, and action reconciliation are non-droppable. If a
non-droppable update cannot be delivered safely, the Integration invalidates
that connection generation, marks its Sessions stale, and performs bounded
snapshot requalification. Conn never silently skips updates while continuing to
claim live authority.

Limits, coalescing rules, overflow isolation, and recovery are explicit
contract tests rather than implicit `AsyncStream` behavior.

### A test-only non-Codex Integration proves the seam

The v0.2 test suite includes a synthetic Integration that never ships or
appears in product UI. It deliberately differs from Codex by supporting
Session-scoped Activities without Runs and monitoring without consequential
control capabilities.

Contract tests compose it alongside Codex-shaped fixtures to prove simultaneous
Integrations, scoped identity collisions, optional Runs, capability subsets,
failure and overflow isolation, partial-inventory safety, Harness attribution,
and cross-Harness Project grouping. Passing only the Codex adapter tests is not
sufficient evidence of provider neutrality. Cross-Integration action routing is
proven with a controllable Codex-shaped fixture active beside the monitor-only
synthetic Integration, so capability and authority cannot be borrowed across
Integration boundaries.

### v0.2.0 remains an Alpha release

The final release tag is `v0.2.0` and the release title is
`Conn 0.2.0 Alpha`, following the existing tag convention without an `-alpha`
suffix. Release-candidate artifacts may be exercised before the final tag.

Final means the provider-neutral migration and its acceptance gates are
complete; it does not claim 1.0 stability or stable release-grade maturity.
README, changelog, installation guidance, and release notes state that v0.2
supports Codex only and that architectural readiness does not constitute
support for another Harness.

### Future Harness guidance is documentation-only

v0.2 contains no Claude Code, Pi, OpenCode, or other non-Codex production
target, stub, dependency, setup UI, or advertised support.

The release documents a future-adapter qualification checklist covering
official observation contracts, identity, optional Run evidence, lifecycle
ownership, retention, streaming and inventory authority, capabilities, action
mapping, approvals and questions, reconnect and acknowledgement uncertainty,
authentication and secrets, privacy and persistence, packaging dependencies,
fixtures, contract tests, and live acceptance evidence.

A future adapter begins only after research completes that checklist. Empty
targets and speculative protocol implementations do not count as architecture
validation.

## Target contract

The exact Swift spelling may be refined test-first, but the contract must
preserve these semantic roles:

- Identity: `HarnessID`, `IntegrationID`, `UpstreamSessionID`,
  `ConnSessionID`, optional `RunID`, `ActivityID`, and `AttentionRequestID`.
- Runtime authority: Integration connection generation and monotonically
  ordered update sequence, neither of which is Codable.
- State: Integration freshness, inventory authority, Session origin,
  ownership, retention, status, Activities, Runs, Attention Requests, Session
  Issues, and terminal outcomes.
- Capabilities: Integration-supported Conn Actions, distinct from dynamic
  Session Action Availability.
- Input: bounded provider-neutral Conn Actions with exact target identity and
  action-specific preconditions.
- Output: evidence-bearing Action Outcomes that preserve rejection,
  acknowledgement uncertainty, invalidation, and reconciliation.
- Delivery: one atomic feed containing a qualified, watermarked snapshot and
  its bounded ordered semantic update stream.

The internal `ConnIntegration` port must not expose provider methods, JSON,
transport objects, authentication values, or provider error types.

Every `IntegrationSnapshot` carries its Integration ID, connection generation,
and `throughSequence`: the greatest update sequence already reflected by that
snapshot. Establishing a feed atomically binds the snapshot and stream to the
same generation; the adapter buffers post-watermark updates before returning
the feed. AppCore ignores duplicate updates at or below the watermark, accepts
the next sequence, and treats any forward gap as loss of authority requiring
fail-stale requalification. A separately fetched snapshot and later-subscribed
stream do not satisfy the port.

Under Swift 6 strict concurrency, `ConnIntegration` is `Sendable` and exposes
only asynchronous operations. Implementations may be actors or internally
synchronized `Sendable` types, but each Integration must serialize connection
generation, feed publication, and action authority. Every boundary value,
snapshot, update, action, and result is an immutable `Sendable` value. A single
ConnAppCore aggregation actor owns update application and invokes pure
deterministic reducers in sequence; `@MainActor` is reserved for ConnUI
publication and interaction, never adapter or reducer execution.

## Target ownership map

| Target | Owns | Must not own |
| --- | --- | --- |
| `ConnDomain` | Neutral identities, vocabulary, integration port, reducers, bounds, checkpoint values | App Server schemas, transport, daemon lifecycle, UI |
| `ConnAppCore` | Integration aggregation, neutral persistence, freshness, inventory reconciliation, availability, notification and presentation policy | Provider parsing, provider methods, Codex setup |
| `ConnCodexAdapter` | Existing App Server transport/protocol, schemas, compatibility, daemon lifecycle, mapping, qualification, controls, Codex diagnostics, Shared Desktop mechanics | Generic UI policy, cross-Integration aggregation |
| `ConnUI` | Neutral view model, AppKit/SwiftUI shell, Session and Integration presentation, accessibility and interaction policy | Codex/App Server imports, Shared Desktop types, provider parsing |
| `ConnApp` | Application startup, concrete adapter installation, OpenAI/Codex asset wiring, Codex-only Labs/settings composition | Domain reduction, transport implementation |

These ownership rules are implemented by the exact Package.swift edges listed
above, not merely by source-folder naming.

The present sources migrate by responsibility:

- `Sources/ConnDomain/AppServer*` are replaced with neutral domain files; no
  provider-shaped aliases remain.
- `Sources/ConnAppCore/AppServerObservationAdapter.swift`,
  `AppServerMonitoringRuntime.swift`, App Server control execution, and
  Shared Desktop mechanics move into `ConnCodexAdapter`.
- Provider-neutral projection, persistence, review, notification,
  presentation, selection, and shell policy remain or are rebuilt in
  `ConnAppCore`.
- `ConnViewModel.swift`, `ConnSurfaceView.swift`, `ConnPanelController.swift`,
  and `GlobalHotKey.swift` move to `ConnUI` after provider dependencies are
  injected or removed.
- `ConnApplication.swift` becomes the composition root and retains only the
  Codex-specific settings/Labs composition that cannot belong to generic UI.
- `LegacyHookRetirementStore.swift` moves to `ConnApp` as fixed-path,
  product-migration cleanup; it does not enter Domain, AppCore, or generic UI.
- `LegacyPluginRetirementRuntime.swift` moves to `ConnCodexAdapter`, while its
  confirmation presentation is composed from `ConnApp`; Codex plugin cleanup
  is not generalized into a neutral Integration feature.
- `ThreadPickerPolicy.swift` becomes provider-neutral
  `SessionPickerPolicy.swift` in `ConnAppCore`, preserving its interaction and
  ordering behavior under composite Session identities.

## Execution plan

Implementation occurs on `cdx/v0.2-provider-neutral`. Each phase ends in one
reviewed checkpoint commit and must leave its owned test surface green. A later
phase may replace an earlier scaffold, but no phase may weaken privacy,
ownership, authority, or no-replay invariants.

During Phases 2–4, the neutral and legacy domain surfaces coexist and the
legacy AppCore production wiring may temporarily retain its adapter dependency
so every checkpoint builds. This is a named migration window, not the target
architecture: no new product behavior is added to the legacy surface, Phase 5
removes the old production edge atomically, and Phase 6 proves only the target
Package.swift graph remains.

### Phase 1 — Freeze the v0.1 parity contract

Evidence: [Conn v0.2 Phase 1 parity contract](conn-v0.2-phase1-parity-contract.md).

Tasks:

1. Record the current build, test assertion counts, schema verification, app
   packaging result, and working tree state.
2. Create a Codex behavior matrix covering monitoring, full pagination,
   qualification, controls, attention, outcomes, persistence, notifications,
   Shared Desktop, accessibility, and shell behavior.
3. Mark the four allowed v0.2 changes: Session terminology, Harness
   attribution, generic Integration framing, and clean persistence reset.
4. Inventory every existing test and assign it to Domain, AppCore,
   CodexAdapter, UI, composition, or retirement.
5. Add privacy canaries for raw provider values, drafts, answers, approval
   decisions, response tokens, and authentication material.
6. Record source-file counts, test-file counts, and assertion totals per
   assigned v0.2 owner. Observation, mapping, qualification, control, and
   Shared Desktop cases currently housed in `ConnAppCoreTests` count toward the
   future CodexAdapter denominator when their subject moves.
7. Verify the assigned edge ownership and parity tests for
   `LegacyHookRetirementStore.swift`, `LegacyPluginRetirementRuntime.swift`,
   `ThreadPickerPolicy.swift`, and every other migration candidate.

Gate:

- All current v0.1 validation passes before structural movement begins.
- Every current behavior/test has a named v0.2 owner; nothing is silently
  dropped.
- Each later phase has a numeric assigned-test and assertion denominator, so
  equivalence cannot be claimed from whole-suite totals alone.

Checkpoint intent: `docs: freeze Conn v0.2 parity contract`

### Phase 2 — Establish the neutral Domain and Integration port

Evidence: [Conn v0.2 Phase 2 results](conn-v0.2-phase2-results.md).

Tasks:

1. Introduce the neutral identity, projection, and integration vocabulary
   alongside the existing App Server-shaped ConnDomain types. The legacy types
   remain compileable migration evidence for the old AppCore path until the
   Phase 5 cutover and are deleted only in Phase 6.
2. Define opaque stable Integration identity, runtime-only generation,
   composite Session identity, optional Run identity, ordered update cursors,
   and the snapshot `throughSequence` watermark.
3. Define snapshots, updates, inventory authority, freshness, capabilities,
   Session Action Availability inputs, Conn Actions, and Action Outcomes.
4. Implement deterministic neutral reducers and bounds without importing the
   Codex adapter.
5. Add the test-only non-Codex Integration and simultaneous-Integration
   contract cases.
6. Add target/import guards so `ConnDomain` cannot acquire provider
   dependencies.
7. Define the Swift 6 concurrency contract: Sendable asynchronous port,
   immutable Sendable boundary values, serialized Integration authority, one
   AppCore aggregation actor, and MainActor-only UI publication.

Gate:

- Domain tests cover identity collisions, optional Runs, ordering,
  stale-generation rejection, complete versus partial inventory, bounded
  unknown Activities, and checkpoint validation.
- The synthetic Integration proves monitoring without controls and
  Session-scoped Activities without Runs.
- Snapshot/feed tests prove an update racing snapshot creation is delivered
  exactly once after the watermark, while duplicates and forward gaps are
  handled conservatively.
- No production wiring changes yet.
- Neutral and legacy domain types coexist only from Phase 2 through the Phase 5
  cutover; no new production feature may be added to the legacy model during
  that window.

Checkpoint intent: `refactor: add provider-neutral Conn domain`

### Phase 3 — Complete `ConnCodexAdapter`

Evidence: [Conn v0.2 Phase 3 results](conn-v0.2-phase3-results.md).

Tasks:

1. Rename/restructure `ConnAppServerAdapter` as `ConnCodexAdapter`.
2. Move App Server connection orchestration, observation parsing, pagination,
   hydration, qualification, reconnect, overload recovery, and control mapping
   behind `ConnIntegration`.
3. Map Codex Thread, Turn, Item, request, outcome, hook diagnostic, model
   catalog, and connection evidence into bounded Conn semantics.
4. Preserve exact version/schema qualification for 0.144.5 and 0.144.6.
5. Preserve New Chat as a Conn-originated, Codex-owned, ephemeral Session.
6. Preserve consequential commit gates and exact acknowledgement outcomes.
7. Move all Shared Desktop inspection/setup/rollback/proof mechanics into this
   target.
8. Retain raw protocol fixtures only in the adapter test surface.

Gate:

- Every Phase 1 assertion assigned to CodexAdapter has an equivalent passing
  test, including observation, mapping, qualification, control, runtime
  recovery, and Shared Desktop cases migrated out of `ConnAppCoreTests`; the
  gate reports assigned, migrated, passing, and intentionally retired totals.
- Golden mapping tests cover supported Items, controls, attention shapes,
  unknown events, privacy bounds, and errors.
- Full pagination follows every cursor, including empty pages.
- No raw App Server object crosses the adapter contract.

Checkpoint intent: `refactor: implement Codex integration adapter`

### Phase 4 — Build neutral AppCore aggregation and persistence

Evidence: [Conn v0.2 Phase 4 results](conn-v0.2-phase4-results.md).

Tasks:

1. Aggregate a collection of Integrations and isolate connection, failure,
   freshness, buffering, inventory, and repair state per Integration.
2. Reduce qualified snapshots and ordered updates while rejecting old
   generations and unsafe gaps.
3. Implement per-Integration bounded/coalesced delivery and fail-stale
   requalification on unsafe overflow.
4. Derive Session Action Availability from capability plus current authority
   and exact action preconditions.
5. Rebuild Session, Project, Attention, outcome-review, notification, Compact
   Shelf, selection, and presentation policies on neutral values.
6. Add the new neutral checkpoint root, discriminator, schema, two-slot
   durability, size bounds, owner-only path checks, and fresh outcome baseline.
7. Preserve provider-neutral preferences while intentionally resetting
   provider-shaped Session order and review ledgers.

Gate:

- Simultaneous Codex-shaped and synthetic Integrations pass aggregation tests.
- With both Integrations live, a harmless consequential action targets only the
  controllable Codex-shaped fixture Integration and Session; the monitor-only
  synthetic Integration contributes neither capability nor authority. Tests
  also prove availability cannot be borrowed from the wrong Integration and
  identical upstream Session IDs cannot retarget an action.
- One Integration's disconnect, partial inventory, overflow, or repair state
  cannot mutate another's authority or membership.
- Restored state is always non-actionable until requalified.
- Cache corruption and failed saves preserve the existing rollback and
  indeterminate-commit safety properties.

Checkpoint intent: `refactor: add neutral integration aggregation`

### Phase 5 — Cut the application over atomically

Evidence: [Conn v0.2 Phase 5 results](conn-v0.2-phase5-results.md).

Tasks:

1. Create `ConnUI` and move the generic view model, surface, panel, hot-key,
   accessibility, Reduce Motion, geometry, and interaction policy into it.
2. Split Codex Shared Desktop state and presentation out of
   `ConnViewModel.swift` and `ConnSurfaceView.swift`; remove every Codex/App
   Server import and type from `ConnUI`.
3. Wire the sole built-in Codex Integration from `ConnApp`.
4. Change generic copy and accessibility labels from Threads to Sessions.
5. Add the brand-cleared official OpenAI visual attribution with `Codex`
   text/accessibility identity while preserving Conn branding, or use the
   documented text/neutral-glyph fallback if clearance is unavailable.
6. Present generic Integration state and Session action availability.
7. Add the typed `@ViewBuilder` Integration-settings content slot to `ConnUI`
   and compose `CodexIntegrationSettingsView` from `ConnApp`, without
   `AnyView`, opaque action IDs, provider dictionaries, or Shared Desktop types
   in Domain, AppCore, or generic UI.
8. Switch production persistence to the neutral root and quarantine/ignore the
   disposable v0.1 projection cache.
9. Replace the old application wiring in one cutover commit.
10. Create the required `conn-ui-tests` executable and move all generic
    view-model, shell, interaction, accessibility, geometry, and presentation
    policy tests into its assigned Phase 1 denominator.

Gate:

- The built application has only the new production path.
- Existing Codex UI behavior passes translated tests and live smoke checks.
- No disabled or placeholder non-Codex UI is present.
- The preferred OpenAI asset has official provenance, unmodified geometry,
  accessible labeling, and current brand-guideline review, or the documented
  Codex text/neutral-glyph fallback is used without blocking release.
- `conn-ui-tests` exists and passes unconditionally.

Checkpoint intent: `refactor: cut Conn over to integration architecture`

### Phase 6 — Remove the legacy architecture

Evidence: [Conn v0.2 Phase 6 results](conn-v0.2-phase6-results.md).

Tasks:

1. Delete App Server-shaped Domain, AppCore, view-model, presentation, control,
   and checkpoint types after replacements pass.
2. Remove the old runtime wiring, reducers, duplicate persistence roots, and
   compatibility code.
3. Retain provider-shaped names only inside `ConnCodexAdapter`, its tests,
   protocol schemas/fixtures, Codex composition, and historical documentation.
4. Rename current test targets and finish assigning every translated test to
   the required `conn-codex-adapter-tests`, `conn-domain-tests`,
   `conn-app-core-tests`, or `conn-ui-tests` executable.
5. Add automated dependency and forbidden-name scans.
6. Update architecture, operations, contributing, security, issue templates,
   README, install, release, acknowledgements, and changelog documentation.
7. Move `LegacyHookRetirementStore.swift` to the `ConnApp` migration edge and
   `LegacyPluginRetirementRuntime.swift` to `ConnCodexAdapter`, with its
   confirmation UI composed by `ConnApp`; preserve their assigned parity tests
   without adding neutral compatibility wrappers.
8. Rename and translate `ThreadPickerPolicy.swift` to
   `SessionPickerPolicy.swift` in AppCore.

Gate:

```sh
! rg -n 'AppServer|JSONRPC|JSONValue|ControlEndpoint|SharedDesktop' \
  Sources/ConnDomain Sources/ConnAppCore Sources/ConnUI
! rg -n '^import ConnCodexAdapter' \
  Sources/ConnDomain Sources/ConnAppCore Sources/ConnUI
```

- `Package.swift` contains the five agreed production targets and no legacy
  adapter product, with exactly the documented dependency edges.
- No runtime fallback, provider payload box, public plugin API, or non-Codex
  production stub remains.
- Phase 1 per-owner test and assertion denominators are fully reconciled; every
  entry is passing under its target or explicitly retired with rationale.
- `git diff --check` passes.

Checkpoint intent: `refactor: remove App Server-shaped core`

### Phase 7 — Accept and release v0.2.0 Alpha

Candidate evidence:
[Conn v0.2 Phase 7 results](conn-v0.2-phase7-results.md).

Offline gate:

```sh
swift build
swift run conn-codex-adapter-tests
swift run conn-domain-tests
swift run conn-app-core-tests
swift run conn-ui-tests
./scripts/generate-codex-app-server-schemas.sh verify
./scripts/test-inspect-release.sh
./scripts/build-app.sh --debug
codesign --verify --deep --strict .build/conn-app/Conn.app
plutil -lint .build/conn-app/Conn.app/Contents/Info.plist
git diff --check
```

Run `pnpm install --frozen-lockfile`, `pnpm web:build`, and `pnpm web:lint` if
the website or shared public assets change.

Live Codex gate:

1. Prove managed-daemon absence recovery without Conn owning or stopping it.
2. Qualify supported CLI/App Server identity and reject unsupported versions.
3. Exercise complete inventory, selected Session history, live Activities,
   reconnect, rehydration, and stale-state recovery.
4. Create an ephemeral Session, start its first Run, follow up, steer, and
   interrupt using harmless prompts.
5. Exercise one approval and structured question where the installed protocol
   supplies them, preserving exact scope and response authority.
6. Inject or simulate post-send uncertainty and prove no automatic replay.
7. Exercise Compact Shelf, outcomes, review, notifications, keyboard,
   accessibility, Reduce Motion, display selection, and shell geometry.
8. Run Shared Desktop diagnosis, setup qualification, Session proof, and
   complete rollback on the supported host configuration.
9. Verify privacy canaries are absent from checkpoints, logs, notices, and
   diagnostics.
10. Quit Conn during active harness work and prove the work survives.

Release gate:

1. Exercise a release-candidate app long enough to cover reconnect, sleep/wake,
   daemon recovery, and ordinary daily supervision.
2. Update version metadata and public documentation to `0.2.0 Alpha`.
3. State plainly that Codex is the only supported Harness in v0.2.
4. Build the distribution artifact using the current signing/notarization
   policy; never imply notarization when using the ad-hoc alpha path.
5. Inspect the final app/DMG, generate checksums after final signing/stapling,
   and publish only after all acceptance evidence is recorded.
6. Tag the accepted commit `v0.2.0`.

Checkpoint intent: `release: Conn 0.2.0 Alpha`

## Cross-cutting acceptance invariants

- Conn remains a non-owning companion; quitting it never terminates Harness
  work.
- No provider payload or command method crosses the adapter boundary.
- No consequential action is inferred, retargeted, or automatically replayed.
- Capability support and current action availability remain distinct.
- Current authority is runtime-only and scoped by Integration generation.
- Partial, truncated, stale, or failed inventories never authorize removal.
- Failure and overload remain isolated per Integration.
- Attention Requests carry response authority; Session Issues do not.
- Cached state is bounded, presentation-only, and non-actionable.
- Conn branding remains primary; Harness attribution is explicit and
  accessible.
- Passing Codex-only tests is insufficient; the synthetic Integration contract
  must also pass.

## Future adapter qualification checklist

A proposed Harness adapter must document and prove:

1. Official supported APIs, SDKs, hooks, files, or processes used by the
   integration; undocumented reverse-engineered protocols cannot be the product
   contract.
2. Harness, Integration, upstream Session, optional Run, Activity, request, and
   action identity semantics and bounds.
3. Lifecycle owner, process owner, behavior when Conn disconnects, and whether
   any proposed managed mode requires a new ADR.
4. Retention semantics independent of lifecycle ownership.
5. Inventory completeness, pagination, deletion authority, atomic
   snapshot/stream watermark, streaming order, concurrency isolation,
   reconnect, and requalification behavior.
6. Workspace identity evidence. Canonical local filesystem identity may prove
   equivalence; display names and path strings alone do not. Remote Workspaces
   require a stable adapter-supplied repository/workspace identity and stated
   authority before cross-Integration Project merging.
7. Integration capabilities and dynamic Session Action Availability for every
   mode.
8. Exact mappings for questions, approvals, steering, interruption, follow-up,
   creation, open-in-Harness, and unsupported actions.
9. Definite rejection versus post-send acknowledgement uncertainty and
   reconciliation behavior.
10. Authentication, secret storage, account identity, logout, and repair
   boundaries.
11. Raw-payload containment, semantic bounds, checkpoint mapping, privacy
    canaries, and logging policy.
12. Runtime dependencies, packaging, updates, process supervision, resource
    limits, and host compatibility.
13. Deterministic fixtures, contract tests, overload tests, live acceptance,
    rollback, and honest unsupported UI copy.

## Definition of done

The v0.2 foundation is complete only when:

- all seven phase gates pass;
- the five-target graph is enforced by the compiler and automated scans;
- the production app has one neutral path through `ConnCodexAdapter`;
- strict Codex parity passes except for the four agreed changes;
- the synthetic Integration proves the seam is not Codex-shaped;
- the clean persistence cut and privacy boundaries are verified;
- architecture and public documentation agree;
- the release remains honestly labeled Alpha and Codex-only; and
- no implementation work for another Harness has been smuggled into scope.
