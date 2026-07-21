# Codex-managed App Server daemon as the integration boundary

Status: Accepted; implementation gated by the Phase 5 live-daemon spike
Date: 2026-07-19
Supersedes: ADR 0002

## Context

The plugin-and-hooks implementation proved safe passive observation across a
narrow set of Desktop and CLI lifecycle events, but it cannot provide
authoritative completion, stable asynchronous request correlation, structured
history, questions, steering, interruption, or exact thread control. Transcript
parsing would add an unstable second source of truth.

The installed Codex distribution exposes a managed App Server daemon and a
structured Thread -> Turn -> Item protocol. App Server provides status, history,
streaming output, requests, actions, and cross-client reconciliation. The current
Desktop normally owns a private stdio App Server, but its installed bundle also
contains an opt-in path that makes Desktop use the managed daemon's Unix socket.
That Desktop launch switch is not currently a public configuration contract and
has not yet passed a live Conn attachment test.

## Decision

Conn will use Codex App Server as its sole target integration after the
migration gate passes.

- **General distribution uses Managed Daemon Mode.** Conn connects to the
  current user's Codex-managed daemon, requesting `codex app-server daemon
  start` when it is absent. General mode shows and controls only threads started
  or resumed through that daemon. It does not claim discovery of unrelated
  standalone Desktop, CLI, IDE, cloud, or web work.
- **Power users may enable Shared Desktop Mode.** A clearly experimental,
  off-by-default README and agent prompt may help a user start the daemon and
  relaunch Desktop with `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`. Conn enables
  this mode only after it proves that Desktop and Conn share the same
  socket, compatible App Server version, and thread manager.
- **App Server is authoritative.** Conn derives presentation from Thread,
  Turn, Item, status, request, and usage messages. It sends follow-ups with
  `turn/start`, steers an in-flight turn with `turn/steer`, interrupts with
  `turn/interrupt`, and resolves approval or question requests only through the
  matching server request. Success appears only after App Server acknowledges
  it.
- **Stable API is the baseline.** Each connection initializes, declares its
  client capabilities, opts out of raw reasoning deltas with exact
  `optOutNotificationMethods`, and records the App Server version. The current
  initialize response is not a general server-feature matrix, so Conn gates
  methods through committed CLI-generated stable and experimental schemas for
  each supported version, any feature-specific read method the protocol
  supplies, and explicit unsupported-method handling. Codex CLI 0.144.5 is the
  first required allowlist artifact; adding a version requires regenerating and
  reviewing the schema diff rather than editing an allowlist by hand.
  Conn opts into `experimentalApi` only for named experimental features
  with a stable fallback; the opt-in is not treated as discovery or proof of
  Desktop sharing.
- **Codex retains lifecycle ownership.** Conn never substitutes a private
  child App Server for another surface's live state. Quitting Conn only
  disconnects its subscription. It does not stop or restart a daemon or turn
  unless the user explicitly invokes the corresponding control.
- **Phase 5 selects the production transport.** The daemon's Unix socket speaks
  WebSocket with an HTTP Upgrade. The spike must compare RFC 6455 framing over
  `NWConnection` with a documented `codex app-server proxy --sock` child that
  relays the same HTTP Upgrade and WebSocket frames as raw stdio bytes. A proxy
  is a disposable connection helper, not an owned App Server: its exit may end
  with Conn while daemon work continues.
- **Conn never enables remote control.** It neither runs `codex app-server
  daemon enable-remote-control` nor invokes an equivalent method because that
  would widen the daemon's exposure for every connected client. Both product
  code and the Shared Desktop setup prompt remain on the local current-user
  socket.
- **Hooks are transitional, not a fallback architecture.** Existing hook,
  relay, bridge, and normalized-fixture code remains until the live-daemon and
  migration gates pass. It is then removed from the product and distribution
  rather than maintained as a competing source of truth.

Conn will not modify the signed ChatGPT application bundle, connect to
private Desktop IPC, silently set persistent launch state, or present an
agent-authored setup prompt as an OpenAI-supported contract.

## Consequences

- Conn changes from a universal passive observer into a compact App Server
  client that can both supervise and control the threads within its connection.
- The general product gains structured output and controls but loses automatic
  observation of ordinary standalone CLI and unconfigured Desktop sessions.
- Shared Desktop Mode can restore rich cross-surface behavior for power users,
  but must remain experimental, version-checked, reversible, and visibly
  diagnosed while its launch switch is undocumented.
- The installed CLI currently labels App Server experimental. General
  distribution remains a preview until the tested version/schema policy is
  strong enough to support upgrades without silent breakage.
- WebSocket ingress is bounded and can reject requests with `-32001`. The
  client must bound and coalesce notification work, back off safe retry traffic,
  rehydrate after shedding, and never automatically replay a consequential
  action whose acceptance is unknown.
- The native notch shell, durable app-state coordination, selection behavior,
  and presentation work from Phases 1-4.5 remain reusable. Hook-specific event
  identity, relay, plugin packaging, and transcript-tail plans are retired after
  migration.
- A failed Shared Desktop spike does not invalidate Managed Daemon Mode. It does
  prevent Conn from advertising control of Desktop-originated active
  threads.
- ADR 0002 and the plugin-and-hooks product plan are superseded and retained as
  history.
- Removing the legacy Sidequest plugin does not remove all hook visibility:
  supported daemon versions expose `hooks/list`, `hook/started`, and `hook/completed`
  through App Server. Those facts remain useful diagnostics but do not become a
  second work-lifecycle authority.

## Migration gates

Before hook removal, Managed Daemon Mode must prove daemon survival after
Conn disconnects, structured output and outcomes, safe message sending,
request reconciliation, interruption, reconnect/rehydration, version
diagnostics, a selected direct-or-proxy transport, 0.144.5 generated-schema
artifacts, notification opt-out, bounded overload behavior, and a complete
migration away from hook-derived production state.

Shared Desktop Mode has a separate gate: same-daemon Desktop attachment,
discovery and rejoin of an active Desktop thread, cross-client output and
actions, and complete rollback to the ordinary Desktop launch. A failed Shared
Desktop gate disables that mode; it does not reactivate hooks or block removal
after the general Managed Daemon Mode migration passes.
