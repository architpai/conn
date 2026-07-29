# Conn v0.2.1 external Pi integration implementation plan

Status: Implemented with scope correction

Date: 2026-07-29

Target release: `v0.2.1`

## Release decision

Conn v0.2.1 ships **external Pi TUI supervision first**.

The release adds one Pi Harness Integration:

- `pi.external` supervises independently launched Pi TUIs through a
  user-approved global Pi extension and an in-process Conn broker.

Conn-originated Pi RPC Sessions, a persistent Pi host, background-item
registration, host crash recovery, managed-to-external handoff, and ad-hoc Pi
Session creation are explicitly deferred to a second product milestone. They
do not block external Pi support and do not enter v0.2.1 production targets,
settings, packaging, or release claims.

This release shape follows the strongest existing evidence:

- the parity spike proved external follow-up, steer, interrupt,
  model/thinking changes, broker restart, reload, new, fork, exit, and resume
  in the original independently launched TUI;
- an in-process broker is sufficient because Conn quitting correctly
  disconnects supervision while the user-owned TUI continues; and
- the persistent host is needed only for managed RPC work and carries a
  distinct ownership, signing, update, recovery, and uninstall posture.

The v0.2.1 user-visible goal is parity for the actions that are meaningful for
a live external Pi Session:

- monitor Session, Run, Activity, model, and thinking state;
- follow up while idle or busy;
- steer an active Run;
- interrupt an active Run;
- expose the currently qualified model and thinking state.

`createSession` is unavailable for `pi.external`. External Pi support is still
valuable and honest without pretending that Conn can create a new independent
TUI Session.

## Evidence and authoritative contracts

Implementation is grounded in:

- the accepted provider-neutral vocabulary in
  [`CONTEXT.md`](../../CONTEXT.md);
- [ADR 0001](../adr/0001-conn-does-not-own-codex-work.md);
- [ADR 0005](../adr/0005-provider-neutral-conn-integration-boundary.md);
- the completed
  [Pi RPC spike](../spike/pi-rpc-v0.2.1.md);
- the completed
  [Pi behavioral parity spike](../spike/pi-behavioral-parity-v0.2.1.md);
- Pi's official
  [Extension documentation](https://pi.dev/docs/latest/extensions);
- Pi's official [RPC documentation](https://pi.dev/docs/latest/rpc); and
- Pi's official [security model](https://pi.dev/docs/latest/security).

The production contract uses only documented Pi Extension surfaces. Session
files may be used in isolated tests or explicit Pi-supported resume flows, but
undocumented session-file decoding is not a live authority source.

The first supported tuple is:

- Pi Coding Agent `0.82.1`;
- macOS 15 on Apple Silicon; and
- a Pi installation whose launcher, Node runtime, package entry point, and
  extension interface can all be qualified.

The supported Pi range widens only after the complete compatibility and live
parity suite passes for every added version.

## Review corrections incorporated

This revision resolves the first-plan review as follows:

1. `pi.managed` is removed from v0.2.1 rather than treated as an ordinary
   non-owning Integration.
2. The external extension connects to an in-process broker; v0.2.1 has no
   helper daemon or background item.
3. The extension has an explicit Conn-absent, unsupported-Pi, stale-lease, and
   orphan contract.
4. Managed/external identity handoff is removed from this release.
5. `open` remains composition-owned and gains pre-click per-Integration
   availability.
6. Pi question and approval behavior is out of scope because neither is a
   standard Pi Session concept and Conn cannot generalize arbitrary user
   extensions.
7. Follow-up always sends an explicit Pi delivery mode after a focused race
   probe proves the behavior.
8. Future duplicate-writer behavior is described as detection and degradation,
   not impossible enforcement.
9. Model qualification has a current-model-only degraded mode.
10. No managed-host proof is required before external implementation.
11. Package and script enforcement gaps are named in the execution plan and
    final offline gate.
12. The installer creates the absent global `extensions/` parent safely and
    documents why Conn does not use Pi's `packages` setting.

## Non-goals

v0.2.1 does not:

- implement `pi.managed` or Conn-originated Pi Sessions;
- add `ConnPiHost`, a LaunchAgent, login item, or persistent background helper;
- amend ADR 0001's non-ownership rule;
- bundle Pi, Node, provider credentials, or model-provider SDKs;
- edit `~/.pi/agent/settings.json`;
- add Conn to the existing Pi `packages` setting;
- require a Pi wrapper command, shell alias, recurring launch flag, project
  extension, MCP registration, or per-project setup;
- scrape terminal text or inject terminal keystrokes;
- reopen a live external Session in a competing Pi process;
- expose raw Pi events, JSON, provider model objects, encrypted reasoning
  signatures, request tokens, or secrets outside `ConnPiAdapter`;
- inject custom tools or intercept arbitrary user-customized Pi tools;
- expose Pi's unqualified global model registry;
- add a public Conn plugin interface;
- regress or reroute the existing Codex Integration; or
- advertise unavailable actions and fail only after the user clicks them.

Conn installs a directory extension rather than using Pi's `packages` setting
because the directory is an official global auto-discovery location, requires
no settings merge, avoids mutating or owning the user's package list, carries
no runtime package dependency, and gives Conn an exact isolated ownership and
uninstall target.

## Product and ownership contract

### External Pi remains non-owning

ADR 0001 remains fully true for v0.2.1:

- Conn never starts, wraps, reopens, interrupts by process signal, or
  terminates an external Pi process.
- Conn actions execute inside the original Pi process only through the
  user-installed supported extension.
- Quitting, crashing, disabling, or uninstalling Conn never stops Pi work.
- Extension or broker loss removes Conn authority; it does not change the Pi
  Session's lifecycle.
- A Session resumed in another TUI receives a fresh extension instance and
  authority only after a supported handshake.

The global extension does change the behavior of future Pi TUIs, so
installation is opt-in and its optional behavioral features are independently
controlled.

### One Harness, one Integration

The well-known Harness identity is `pi`.

The stable Conn-controlled Integration identity is `pi.external`.

It has its own:

- connection generation;
- freshness;
- inventory authority;
- capability set;
- Session identities;
- buffering and overload state; and
- diagnostics and repair state.

Codex and Pi may be live simultaneously. Failure, overload, incompatibility,
or disablement of Pi cannot change Codex authority or membership.

### ConnPiAdapter is a deep module

`ConnPiAdapter` satisfies the existing `ConnIntegration` interface and hides:

- Pi and Node discovery;
- version and extension-interface qualification;
- extension resource verification and installation;
- local broker authentication and framing;
- extension-instance and Session lifecycle;
- Pi event decoding and semantic projection;
- model qualification;
- bounded buffering and snapshot/update handoff; and
- Pi-specific diagnostics.

No Pi method, delivery string, raw JSON, or arbitrary command escape hatch is
added to `ConnIntegration`.

The external seam remains:

- `establishFeed()`
- `sessionModels(for:)`
- `perform(_:)`
- `disconnect()`

The adapter implementation earns its depth by translating the complete Pi
extension lifecycle and protocol behind that small interface.

## Target graph and ownership

The v0.2.1 production graph becomes:

- `ConnDomain`
- `ConnAppCore`
- `ConnCodexAdapter`
- `ConnPiAdapter`
- `ConnUI`
- `ConnApp`

Required production edges:

- `ConnDomain` has no Conn production dependency.
- `ConnAppCore -> ConnDomain`
- `ConnCodexAdapter -> ConnDomain`
- `ConnPiAdapter -> ConnDomain`
- `ConnUI -> ConnDomain + ConnAppCore`
- `ConnApp -> ConnDomain + ConnAppCore + ConnCodexAdapter + ConnPiAdapter + ConnUI`

Forbidden edges:

- `ConnDomain`, `ConnAppCore`, and `ConnUI` do not import either adapter.
- `ConnCodexAdapter` and `ConnPiAdapter` do not import each other.
- `ConnAppCoreTests` does not depend on a production adapter; controllable
  test Integrations satisfy the seam.

Phase 1 removes the already-stale `ConnAppCoreTests -> ConnCodexAdapter`
Package.swift dependency and adds a package-graph assertion so it cannot
return.

`ConnPiAdapter` owns:

- Pi discovery and compatibility;
- broker protocol values;
- bundled extension resource and installer;
- external bridge runtime;
- Pi mapping, correlation, diagnostics, and errors; and
- the concrete `PiExternalIntegration`.

`ConnApp` owns:

- explicit consent and Pi enablement;
- in-process broker startup and shutdown through the adapter;
- Pi and Codex settings composition;
- Harness assets;
- global launch-at-login state; and
- open-in-Harness routing.

`ConnUI` remains Harness-neutral. It consumes Integration descriptors,
capabilities, Session availability, Harness attribution, and a typed
composition-owned opener interface.

## Extension installation

### Exact target

Conn owns only:

`~/.pi/agent/extensions/conn/`

The global parent `~/.pi/agent/extensions/` does not currently exist on the
tested machine. Install therefore creates the parent when absent, preserving
the existing `~/.pi/agent` directory and touching no sibling entry.

The installed directory contains:

- `index.ts`
- `.conn-install.json`

The ownership manifest contains:

- exact Conn owner identifier;
- extension protocol version;
- Conn release version;
- content hash; and
- installation transaction ID.

It contains no socket path, runtime descriptor, authentication secret, user
prompt, answer, decision, environment, or model credential.

### Enable

The user chooses `Enable Pi monitoring` and reviews consent copy explaining:

- a global TypeScript extension will load into future Pi TUIs;
- extensions execute with the user's permissions;
- core monitoring/control does not own or stop Pi work;
- existing Pi TUIs need one `/reload`, while future TUIs auto-load it.

Conn then:

1. discovers and qualifies Pi;
2. verifies every destination ancestor and exact target without following an
   unsafe final symlink;
3. refuses an existing unowned, malformed, changed, or symlinked
   `extensions/conn` target;
4. creates `extensions/` with the expected owner and safe permissions if it is
   absent;
5. prepares a sibling directory containing the bundled extension and
   ownership manifest;
6. verifies resource hash, version, permissions, and file type;
7. atomically renames the prepared directory into place;
8. starts the in-process broker;
9. verifies broker self-diagnostics; and
10. shows `Reload existing Pi Sessions` until compatible live registrations
    arrive.

### Update

Update operates only on an exact Conn-owned target:

1. prepare and verify a sibling version;
2. retain the prior directory as a rollback candidate;
3. atomically swap the new version into place;
4. request `/reload` for existing TUIs;
5. accept old and new extension versions only according to an explicit
   compatibility matrix;
6. verify new-version registration; and
7. retire the backup only after acceptance.

Failed verification restores the previous exact owned version and reports
mixed-version live Sessions honestly.

### Disable and uninstall

Disabling Pi:

- stops advertising all Pi action capability immediately;
- stops the broker and invalidates its lease;
- leaves every Pi TUI running;
- makes optional interception paths inert immediately on broker loss;
- retains the installed files so re-enable remains reversible.

Uninstall:

- refuses foreign, malformed, changed, or symlinked targets;
- moves only the exact Conn-owned `extensions/conn` directory to Trash;
- removes the parent `extensions/` only if Conn created it and it is still
  empty and exactly unchanged;
- leaves Pi settings, sessions, credentials, packages, trust decisions, and
  unrelated extensions untouched; and
- verifies absence without editing `settings.json`.

### App dragged to Trash

Conn cannot run an uninstall after the user deletes `Conn.app` directly.
The orphan contract is therefore fail-inert, not magical self-deletion:

- the extension requires a fresh broker runtime descriptor and lease before it
  enables any connection behavior;
- when the descriptor is missing, expired, malformed, incompatible, or points
  to an absent broker, the extension adds no prompts, blocks no tools, starts
  no agent work, and stops connection retries;
- the orphaned files may continue to be auto-loaded by Pi but remain inert;
- the extension never deletes itself while loaded; and
- documentation provides the exact manual removal target
  `~/.pi/agent/extensions/conn/`, or the user may reinstall Conn and use the
  verified uninstall flow.

No setting that changes Pi behavior is allowed to survive merely because a
stale file says it was once enabled.

## Conn-absent and unsupported-version contract

The extension auto-loads independently of Conn, so its inactive behavior is a
release gate.

### Startup

- The extension factory performs bounded local validation only.
- It starts no socket, process, timer, or watcher.
- `session_start` schedules connection work and returns without waiting.
- Conn adds zero synchronous network wait to Pi startup.
- Monitoring cannot block `session_start`.

### Runtime descriptor and lease

Conn atomically publishes an owner-only runtime descriptor containing:

- protocol version;
- broker generation;
- short user-temporary Unix socket path;
- rotated authentication secret;
- issue and expiry timestamps.

The socket parent is mode `0700`; the socket is owner-only; the broker verifies
peer UID where supported. Secrets never appear in the installed extension
source, logs, checkpoints, diagnostics, or UI.

The extension treats an expired descriptor as absent. Conn refreshes the lease
only while the broker is alive.

### Reconnect

- Initial reconnect uses exponential backoff with jitter.
- The retry delay has a documented floor and ceiling.
- The extension performs at most a bounded number of attempts within a bounded
  elapsed window.
- After the ceiling, it gives up and closes retry timers.
- A runtime-descriptor file change, a new `session_start`, or `/reload` may
  start a new bounded attempt window.
- A missing or expired descriptor causes no socket attempt.
- Unsupported protocol or Pi version self-disables for that extension instance
  and emits at most one bounded local diagnostic; it never loops.

Exact attempt counts, timing, and jitter injection are deterministic test
inputs rather than hard-coded sleeps in tests.

### Broker loss

Broker loss:

- invalidates live Conn authority immediately;
- starts only the bounded reconnect policy above; and
- never affects Pi's own Session or agent lifecycle.

## Provider-specific customization boundary

Conn observes and controls only standard Pi Session behavior. It does not
register model-visible tools, intercept tool execution, translate arbitrary
extension events, or attempt to emulate Codex questions and approvals.
User-installed Pi extensions remain owned by their users and outside Conn's
capability contract.

## Local broker protocol

The broker is an actor inside `ConnPiAdapter`, started and stopped by
`ConnApp` composition.

The extension connects outbound to a short Unix socket path supplied by the
fresh runtime descriptor.

The protocol is:

- local and current-user only;
- versioned;
- role-specific;
- bounded newline-delimited JSON;
- authenticated with a rotated broker-generation secret;
- correlated with opaque command IDs; and
- a closed semantic command set.

It has no provider-command forwarding field.

Handshake establishes:

- protocol version;
- extension build/version;
- Pi version;
- extension-instance UUID;
- Pi process PID as diagnostic evidence;
- stable Pi Session ID;
- Session replacement reason;
- Workspace;
- model and thinking;
- broker generation.

Every frame has a maximum byte count. Every Session has bounded pending
commands, Activities, and buffered update bytes.

Lifecycle, action reconciliation, and authority-loss events are
non-droppable. High-frequency message/tool deltas may be coalesced by stable
semantic identity. Unsafe overflow invalidates the Pi Integration generation
and requires requalification.

## Semantic mapping

### Identity

- Harness: stable `pi`.
- Integration: stable Conn-controlled `pi.external`.
- Upstream Session: Pi's stable Session ID, never the PID or file path.
- Extension instance: runtime-only UUID scoped to one loaded extension.
- Broker generation: runtime-only Integration connection generation.
- PID: diagnostic/liveness evidence only.
- Run: created only while Pi event evidence establishes an agent interval.
- Activity: adapter-generated bounded identity derived from supported event
  identity and sequence.

PID reuse, extension reload, Session replacement, and stale frames cannot
retarget Session authority.

### Lifecycle

| Pi evidence | Conn semantic update |
| --- | --- |
| `session_start: startup/resume` | Upsert persistent Session and qualify authority |
| `session_start: new` | End prior authority and upsert the new Session identity |
| `session_start: fork` | End prior authority and upsert the fork identity |
| `session_start: reload` | Replace extension instance without replacing Session identity |
| `session_info_changed` | Upsert bounded title |
| `agent_start` | Start an evidence-backed Run |
| tool/message/turn events | Upsert bounded Activities on the grounded Run |
| `agent_settled` | Reconcile terminal Run and Session status |
| `session_shutdown` | End live instance authority without deleting the Session |
| socket loss or sequence gap | Mark the Integration stale and requalify |

Extension disconnect, Conn quit, partial inventory, or a missing Session during
incomplete recovery never authorizes Session removal.

### Actions

| Conn intent | External Pi mapping |
| --- | --- |
| Create Session | Unsupported |
| Follow-up | Always explicit `pi.sendUserMessage(..., { deliverAs: "followUp" })` after Phase 0 proof |
| Steer | Explicit `deliverAs: "steer"` |
| Interrupt | `ctx.abort()` |
| Answer | Unsupported |
| Resolve approval | Unsupported |
| Model/reasoning | `setModel`, `setThinkingLevel`, then read back before follow-up |

Conn does not choose idle versus busy delivery from lagging projected state.
The adapter always supplies the semantic delivery mode and lets Pi arbitrate
against its current internal state.

Mutation acknowledgement means accepted, not settled. Dependent reads occur
only after the exact correlated mutation response. Terminal outcomes require
later authoritative events.

No consequential action is automatically replayed after timeout, disconnect,
decode failure, broker restart, or acknowledgement uncertainty.

## Model and thinking qualification

Conn never displays Pi's full registry of thousands of possible models.

Preferred mode:

- start from the current model and Pi's scoped/configured models;
- retain provider plus model ID only inside opaque adapter-owned model IDs;
- offer thinking levels supported by each selected model;
- treat `setModel == false` as definite rejection;
- read back effective model and clamped thinking before follow-up; and
- invalidate the catalog on extension-instance, model-scope, or broker
  generation change.

Degraded mode:

- if configured/authenticated model qualification cannot be bounded and proven,
  expose only the current model;
- expose its currently effective thinking level and only demonstrably
  supported alternatives;
- disable model switching rather than blocking the Integration or showing
  misleading choices; and
- preserve monitoring and other controls.

Catalogs are runtime-only and never enter the neutral checkpoint.

## Finder-safe discovery

Conn cannot rely on a Finder-launched app inheriting a login-shell `PATH`.

Discovery order:

1. revalidate any cached qualified tuple by file identity and version;
2. invoke the user's resolved login shell with strict timeout and bounded
   output to locate `pi` and `node`;
3. inspect known Pi and Node installation layouts;
4. resolve the launcher to the actual Pi package entry point;
5. execute a non-mutating version/interface probe with the resolved Node
   binary; and
6. fail with repair guidance rather than guessing.

The cache stores bounded paths, file identity, and qualification metadata only.
It stores no environment, authentication, provider configuration, or command
output.

## Open-in-Harness composition

`open` is not performed by an adapter today. `CodexIntegration.perform(.open)`
returns unavailable, while `ConnApp` supplies one hardcoded Codex opener to
`ConnViewModel`. The Open button is currently unconditional.

v0.2.1 keeps opening at the composition seam and corrects the shared shape:

1. Remove `open` from `ConnActionKind` and `ConnAction`; it is not an
   Integration action.
2. Add a small typed provider-neutral opener interface owned by `ConnUI` and
   supplied by `ConnApp`.
3. The interface answers availability for a `ConnSessionID` before rendering
   and performs the open only for an available route.
4. `ConnApp` routes by exact Integration ID to Codex or Pi composition.
5. The Open button is hidden or disabled with truthful help when no route is
   available.

Codex retains its current application activation behavior.

Pi advertises an opener route only if Phase 0 proves the owning terminal
application and exact window can be activated without:

- scraping terminal text;
- injecting keystrokes;
- requesting new Accessibility authority;
- reopening the Session;
- launching a competing writer; or
- guessing from Workspace alone.

If the proof fails, Pi Open is unavailable in v0.2.1 and the button does not
appear for Pi Sessions.

## Settings and user experience

The Codex-only settings content becomes a composed Conn Settings view in
`ConnApp`:

1. **Conn startup**
   - Launch Conn at login
2. **Codex**
   - existing built-in Integration and Shared Desktop Labs unchanged
3. **Pi**
   - Pi discovery/version
   - Enable Pi monitoring
   - Extension state/version
   - External Integration freshness
   - Reload guidance
   - Diagnose
   - Update
   - Disable
   - Uninstall

The launch-at-login control is global Conn behavior and moves out of the
Codex-named settings model. Pi does not require launch at login; enabling it
only starts Conn and its in-process broker earlier.

Required Pi states:

- Pi not found
- unsupported Pi version
- install available
- consent required
- installing
- installed, Conn not connected
- installed, reload existing Sessions
- connected
- update available
- mixed extension versions
- foreign target conflict
- disconnected
- extension inert due to stale or absent broker
- disabling
- uninstalling
- repair required

Session rows remain grouped by proven Workspace and show accessible Pi Harness
attribution. Codex and Pi Sessions may share a Project only when canonical
Workspace evidence proves equivalence.

The New Session surface does not list `pi.external`, because it has no
`createSession` capability. Codex creation behavior remains unchanged.

## Persistence and privacy

The neutral v0.2 checkpoint already supports simultaneous Integrations and
scoped Session identities. v0.2.1 may add bounded Harness presentation
metadata but no raw Pi state.

Never persist:

- bridge raw JSON;
- socket paths or authentication secrets;
- provider credentials or environment;
- full Session-file paths when Workspace identity suffices;
- hidden reasoning or encrypted signatures;
- provider envelopes, headers, or model registry payloads;
- PID, broker generation, extension instance, connection generation, live
  capability, or action availability; or
- acknowledgement-uncertain actions.

Restored Pi Sessions begin rehydrated/stale and non-actionable. Fresh extension
and broker evidence is required to restore live state or controls.

Logs and diagnostics use a strict allowlist with length bounds. Privacy tests
include unique canaries for every prohibited field.

## Reliability and resource bounds

The extension, broker, and adapter each define and test:

- maximum external connections;
- maximum frame and buffer bytes per connection;
- maximum pending commands per Session;
- retry count, elapsed window, delay ceiling, and jitter source;
- lease duration and refresh;
- heartbeat and idle timeouts;
- non-droppable lifecycle/action reconciliation events;
- coalescible high-frequency deltas;
- stale-instance rejection after reload/new/fork/resume;
- broker-generation invalidation;
- sleep/wake behavior;
- unsupported Pi and protocol behavior; and
- Conn/extension/Pi version skew.

Unsafe overflow invalidates only `pi.external` and triggers bounded
requalification. It never silently drops consequential state while claiming
live authority.

## Test strategy

The `ConnIntegration` interface is the adapter test surface.

New test target:

- `conn-pi-adapter-tests`

New TypeScript workspace:

- `integrations/pi-extension`

It pins the supported Pi package as a development dependency for type-checking
but produces an extension with no runtime npm dependency.

Test layers:

1. **Pure protocol and projection**
   - frame decoder
   - handshake/version/role negotiation
   - Pi-event-to-Conn mapping
   - sequence and generation logic
   - unknown-event tolerance
   - privacy allowlist
2. **Installer filesystem**
   - absent-parent creation
   - install/update/rollback/remove
   - exact ownership and empty-parent removal
   - symlink and foreign conflicts
   - interrupted transaction recovery
   - permissions and content hashes
3. **Conn-absent extension**
   - no descriptor
   - stale lease
   - app/broker disappears
   - bounded retry and give-up
   - unsupported Pi/protocol
   - no startup blocking
   - no prompts or tool interception
4. **External bridge**
   - ordinary TUI launch without flags
   - snapshot/update handoff
   - follow-up/steer/interrupt
   - model/thinking preferred and degraded modes
   - reload/new/fork/resume/exit
   - broker/Conn restart and mixed versions
5. **AppCore contract**
   - Codex and Pi simultaneously
   - identical upstream ID isolation
   - capability cannot cross Integration identity
   - independent freshness/failure/overflow
   - Project grouping only by proven Workspace
6. **UI and Settings**
   - every setup/repair state
   - pre-click Open availability
   - Pi excluded from New Session
   - Harness attribution/accessibility
   - Compact Shelf parity
   - no Codex regression
7. **Packaging**
   - bundled extension/resource hash
   - TypeScript type-check against pinned Pi
   - clean install/update/uninstall from packaged app

Tests assert observable behavior through module interfaces. Every correction
receives a regression test.

## Mechanical architecture enforcement

Phase 1 updates `scripts/check-provider-boundaries.sh` to reject Pi-shaped
names outside `ConnPiAdapter` and ConnApp composition, including:

- `PiRPC`
- `sendUserMessage`
- `deliverAs`
- `thinkingLevel`
- Pi extension event names
- broker wire frame names
- raw Pi provider/model objects

The script also rejects `import ConnPiAdapter` from `ConnDomain`,
`ConnAppCore`, and `ConnUI`.

`scripts/check-conn-domain-boundary.sh` adds `ConnPiAdapter` to forbidden
imports.

`scripts/check-conn-ui-boundary.sh` rejects Pi adapter/protocol names while
allowing only typed neutral opener/settings composition.

A new `scripts/check-conn-pi-adapter-boundary.sh` asserts:

- `ConnPiAdapter` imports no AppCore/UI/Codex adapter;
- Pi-shaped names remain in the adapter and extension workspace;
- `PiExternalIntegration` satisfies `ConnIntegration`;
- no managed host target or RPC production implementation exists in v0.2.1;
  and
- the bundled extension hash matches the installed resource manifest.

A package-graph check removes and forbids the unused
`ConnAppCoreTests -> ConnCodexAdapter` dependency and forbids
`ConnAppCoreTests -> ConnPiAdapter`.

## Execution plan

Implementation starts only after this revision is approved. Before the first
code change:

1. fetch the remote;
2. fast-forward from current `main`;
3. retain branch `cdx/v0.2.1-pi-agent`;
4. record the clean baseline; and
5. commit the approved plan and spike evidence separately from production
   code.

Each phase ends in a reviewable checkpoint commit and results document. No
phase may weaken privacy, ownership, authority, or no-replay invariants.

### Phase 0 — Close focused external gaps

Use throwaway extensions of `prototypes/pi-parity`; no production target lands
in this phase.

Tasks:

1. Prove explicit `deliverAs: "followUp"` is safe when Pi is idle, busy, and
   changes state between Conn observation and command execution.
2. Measure extension startup latency with Conn absent and prove no synchronous
   socket wait.
3. Prove bounded retry, jitter, ceiling, give-up, and runtime-descriptor-change
   wake-up.
4. Prove unsupported Pi/protocol self-disable with no repeated prompt or loop.
5. Attempt safe external terminal/window activation for `open`; record it
   supported or unavailable.
6. Empirically qualify scoped/configured models; if no bounded rule exists,
   accept current-model-only degraded mode.
7. Re-run the external parity matrix against the exact pinned Pi build.

Gate:

- follow-up no longer relies on projected idle/busy state;
- Conn absence is silent, bounded, inert, and non-blocking;
- model qualification has a preferred or degraded contract;
- Pi `open` has proof or is explicitly unavailable; and
- all throwaway code remains outside production targets.

Checkpoint intent: `test: qualify external Pi edge cases`

### Phase 1 — Freeze parity and establish boundaries

Tasks:

1. Record current commit, Package.swift graph, build, tests, packaging,
   signing, launch-at-login, and live Codex baseline.
2. Create the v0.2.1 Codex no-regression matrix.
3. Inventory tests and assign Pi work to Domain, AppCore, PiAdapter, UI,
   composition, or packaging.
4. Add `ConnPiAdapter`, `conn-pi-adapter-tests`, and the
   `integrations/pi-extension` workspace.
5. Add the bundled TypeScript extension as a processed adapter resource.
6. Define closed broker protocol, handshake, bounds, errors, and correlation.
7. Add TypeScript type-checking against pinned Pi.
8. Remove the unused `ConnAppCoreTests -> ConnCodexAdapter` dependency.
9. Update all named provider-boundary scripts and add the Pi adapter script and
   package-graph assertion.
10. Correct Open ownership by removing it from Conn Actions and adding the
    typed composition-owned opener interface with pre-click availability.

Gate:

- protocol/boundary values are immutable and Sendable where required;
- malformed, oversized, stale, or unauthenticated frames fail closed;
- no Pi value enters Domain/AppCore/UI;
- AppCore tests depend on no production adapter;
- the Open button follows route availability;
- TypeScript type-checks against the pinned package; and
- all existing suites remain green.

Checkpoint intent: `feat: establish external Pi adapter seam`

### Phase 2 — Implement setup and inert lifecycle

Tasks:

1. Implement Finder-safe Pi and Node discovery.
2. Implement exact version/interface qualification and cache revalidation.
3. Implement bundled-resource and manifest hashing.
4. Implement absent-parent creation, install, update, rollback, status,
   disable, and recoverable removal.
5. Implement foreign-target, symlink, ownership, permission, and interrupted
   transaction recovery.
6. Implement runtime descriptor, lease, in-process broker startup/shutdown,
   authentication, and peer validation.
7. Implement extension no-Conn, stale-lease, unsupported-version, retry,
   give-up, wake-up, and broker-loss behavior.
8. Add non-UI settings models for all setup and repair states.

Gate:

- no Pi settings file or package list changes;
- install requires no flags or project setup;
- absent global extensions parent is created safely;
- foreign targets are preserved;
- rollback restores the prior exact version;
- uninstall touches only exact Conn-owned artifacts;
- Conn absence adds no prompt, block, loop, or synchronous startup wait; and
- packaged isolated-user setup tests pass.

Checkpoint intent: `feat: add safe external Pi setup`

### Phase 3 — Implement monitoring

Tasks:

1. Implement extension lifecycle registration and automatic reconnect.
2. Implement broker acceptance and stale-instance replacement.
3. Map Session, Run, Activity, model, thinking, tool, and issue state into
   bounded Conn semantics.
4. Implement atomic snapshot plus ordered update feed.
5. Implement per-connection bounds, coalescing, overflow invalidation, and
   requalification.
6. Handle reload, new, fork, resume, exit, broker restart, sleep, and wake.

Gate:

- an ordinary TUI appears with no launch flag;
- PID reuse and extension replacement cannot retarget authority;
- snapshot races deliver every semantic update exactly once;
- unknown events are bounded and non-authoritative;
- disconnect never deletes the Session;
- quitting Conn never affects Pi work; and
- Codex remains independently live.

Checkpoint intent: `feat: monitor external Pi Sessions`

### Phase 4 — Implement standard controls

Tasks:

1. Implement explicit-mode follow-up, steer, and interrupt.
2. Implement correlated model/thinking selection and readback.
3. Implement current-model-only degraded catalog behavior.
4. Implement acknowledgement uncertainty mapping.
5. Recompute capability and Session Action Availability on every authority
   and lifecycle transition.

Gate:

- the complete external control suite passes in the original Pi process;
- state races do not change follow-up semantics;
- no action is automatically replayed;
- privacy canaries reject raw events and secrets; and
- availability disappears immediately with authority.

Checkpoint intent: `feat: control external Pi Sessions`

### Phase 5 — Compose Pi into Conn

Tasks:

1. Compose Codex and `pi.external` simultaneously.
2. Move launch-at-login into global Conn settings composition.
3. Add Pi setup, diagnostics, update, disable, and uninstall
   UI.
4. Add Pi Harness asset with provenance and license review.
5. Route Open by Integration through the typed opener interface.
6. Preserve Project grouping by proven Workspace identity.
7. Present Pi Sessions, Activities, outcomes, notifications, and Compact
   Shelf through neutral UI.
8. Add accessible Harness labels and truthful unsupported-action copy.
9. Keep Pi out of New Session creation UI.

Gate:

- Codex behavior remains at v0.2.0 parity;
- both Integrations remain independently fresh and actionable;
- identity/capability cannot cross-route actions;
- every Pi settings state is testable without live Pi;
- Open never appears without a qualified route; and
- packaged-app manual UI and accessibility acceptance pass.

Checkpoint intent: `feat: compose external Pi into Conn`

### Phase 6 — Harden and release v0.2.1

Tasks:

1. Exercise unsafe overflow, sequence gaps, sleep/wake, Conn crash, Pi crash,
   extension reload, mixed versions, app deletion, and orphan-inert behavior.
2. Exercise interrupted extension updates and rollback.
3. Verify checkpoint bounds and non-actionable restore.
4. Add allowlisted diagnostics export.
5. Run privacy canaries across checkpoints, logs, notices, crash reports, and
   diagnostics.
6. Remove prototype-only code from release inputs.
7. Run packaged live Codex and Pi acceptance.
8. Update public and operational documentation.

Offline gate:

```sh
swift build
swift run conn-domain-tests
swift run conn-app-core-tests
swift run conn-codex-adapter-tests
swift run conn-pi-adapter-tests
swift run conn-ui-tests
./scripts/check-provider-boundaries.sh
./scripts/check-conn-domain-boundary.sh
./scripts/check-conn-codex-adapter-boundary.sh
./scripts/check-conn-pi-adapter-boundary.sh
./scripts/check-conn-ui-boundary.sh
./scripts/check-package-graph.sh
./scripts/generate-codex-app-server-schemas.sh verify
pnpm --filter @conn/pi-extension typecheck
./scripts/verify-pi-extension-resource.sh
./scripts/test-inspect-release.sh
./scripts/build-app.sh --debug
codesign --verify --deep --strict .build/conn-app/Conn.app
plutil -lint .build/conn-app/Conn.app/Contents/Info.plist
git diff --check
```

Live Codex gate:

1. Repeat the complete v0.2.0 Codex acceptance matrix.
2. Verify Shared Desktop diagnosis, setup, proof, and rollback.
3. Verify Pi state cannot affect Codex freshness, actions, notifications, or
   persistence.

Live Pi gate:

1. Install through packaged Settings with explicit consent.
2. Launch Pi normally in two terminal applications without flags.
3. Verify simultaneous discovery, identity, status, Activities, model, and
   thinking.
4. Exercise idle follow-up, busy follow-up, steer, and interrupt.
5. Exercise reload, new, fork, resume, terminal exit, Conn restart,
   sleep/wake, and mixed extension versions.
6. Quit Conn and prove both TUIs continue with no Conn prompts, blocks, or
   retry loop.
7. Delete a packaged test copy without uninstall and prove the orphaned
   extension is inert.
8. Reinstall and use recoverable uninstall; prove both TUIs remain running.

Release gate:

1. Dogfood the release candidate across ordinary work, sleep/wake, reconnect,
   extension update, and launch-at-login.
2. Update version metadata, README, changelog, security, install, operations,
   acknowledgements, and release notes.
3. State the supported Pi tuple, external-only scope, default-off optional
   behavior, and orphan-removal guidance.
4. Build, sign/notarize under the current policy, inspect app and DMG, and
   generate checksums only after final signing/stapling.
5. Tag the accepted commit `v0.2.1`.

Checkpoint intent: `release: Conn 0.2.1`

## Cross-cutting acceptance invariants

- Existing Codex behavior remains at v0.2.0 parity.
- Conn never owns externally launched Harness work.
- Quitting Conn never terminates external Codex or Pi work.
- External Pi TUIs are never wrapped, reopened, or killed for control.
- Provider methods and payloads remain inside their adapters.
- One Integration has one current authority generation.
- Capability support and Session Action Availability remain separate.
- Consequential actions are correlated and never automatically replayed after
  uncertainty.
- Optional Pi behavior changes are independent, disclosed, and default off.
- Broker absence makes the extension inert, not noisy or restrictive.
- Approval mediation is Conn policy, not a sandbox.
- Attention Requests carry exact runtime-only response authority.
- Partial inventory and disconnect never authorize Session removal.
- Cached state is bounded, neutral, and non-actionable.
- Raw Pi events, model payloads, credentials, secrets, answers, decisions, and
  encrypted reasoning never cross privacy boundaries.
- Pi failure or overload cannot degrade Codex.
- Install, update, disable, and uninstall touch only exact Conn-owned
  artifacts.
- Unsupported actions are unavailable before interaction, not simulated.

## Deferred managed Pi milestone

Conn-originated Pi RPC Sessions remain a desired second milestone, not hidden
v0.2.1 scope.

Before managed implementation:

1. ADR 0006 must explicitly amend ADR 0001 for a named Conn-hosted Pi product
   mode.
2. The invariant becomes:
   - Conn never owns externally launched Harness work.
   - Conn-hosted Pi Sessions have a disclosed Conn-host lifecycle.
3. Consent must state that managed Sessions depend on the installed host and
   end if the host is removed or the user logs out, unless a future Pi-owned
   daemon contract changes that fact.
4. The persistent host, signing, background registration, upgrade handoff,
   crash recovery, resource limits, orphan handling, and uninstall disposition
   require their own implementation plan and release gate.
5. Duplicate-writer exclusion applies only to Conn-launched writers. If a user
   opens the same saved Session independently, Conn detects competing
   authority, disables consequential actions, and surfaces repair; it cannot
   claim universal enforcement.
6. Managed-to-external Open/handoff is excluded from the first managed
   milestone. It remains unavailable until identity migration, Activity
   provenance, Project continuity, response authority, and no-competing-writer
   behavior have a separately accepted design.
7. A managed Session never changes `ConnSessionID` silently. Any future
   cross-Integration handoff requires an explicit identity-migration decision,
   not automatic merging by matching Pi Session ID.
8. Host feasibility is proven in throwaway prototype code before production
   targets land.

## Review decisions

Approval of this revision accepts:

1. v0.2.1 is external Pi TUI integration only.
2. The broker lives in Conn; no Pi host/background helper ships.
3. Questions, approvals, custom-tool registration, and tool interception are
   outside the Pi Integration contract.
4. Conn absence makes the extension silent and inert.
5. Follow-up always uses explicit Pi delivery semantics after Phase 0 proof.
6. Model selection degrades to current-model-only when qualification is not
   bounded.
7. Open remains composition-owned and unavailable for Pi unless exact terminal
   activation is proven.
8. Managed Pi is a later Conn-hosted product mode requiring an ADR that
   explicitly amends ADR 0001.

## Definition of done

v0.2.1 is complete only when:

- all seven phase gates pass;
- `PiExternalIntegration` satisfies the existing `ConnIntegration` interface;
- the packaged app safely installs, updates, diagnoses, disables, and removes
  its exact global extension;
- Conn-absent, unsupported-version, and orphan behavior is silent and inert;
- external Pi parity passes without launch flags or process ownership;
- optional behavior changes are disclosed, independent, and default off;
- Codex no-regression and cross-Integration isolation pass;
- privacy, uncertainty, overflow, rollback, script, TypeScript, hash, and
  packaging gates pass;
- documentation describes true Pi security and external-only scope; and
- the accepted artifact is tagged `v0.2.1`.

No production implementation begins until this revision is reviewed and
approved.
