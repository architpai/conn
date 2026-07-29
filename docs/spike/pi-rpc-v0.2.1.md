# Pi RPC v0.2.1 capability spike

Status: complete

Date: 2026-07-29

Follow-up: the external-TUI lifecycle, Settings installation contract, model
selection, questions, and approvals were tested in the
[`pi-behavioral-parity-v0.2.1.md`](./pi-behavioral-parity-v0.2.1.md) spike.

## Question

Can Conn provide the same useful control surface it currently provides for
Codex, including control of independently launched Pi TUIs?

This spike is a feasibility gate. It does not add a production Pi adapter,
bundle Pi, or change the user's real Pi configuration.

## Executive result

Yes, through two supported Pi surfaces:

- Conn can reach near-Codex control parity for **Conn-managed Pi RPC
  Sessions**.
- Conn can follow up, steer, and interrupt an **externally launched Pi TUI**
  when a Conn bridge extension is loaded inside that original process.

The earlier RPC-only conclusion that external TUI control was unsupported was
too narrow. Reopening a saved session still does not attach to its original
process, but Pi's Extension API can execute control operations inside that
process and expose them to Conn over a user-local transport.

This is materially different from the Claude Agent View result. Pi exposes
documented control APIs for prompt, steer, queued follow-up, abort, model
selection, thinking selection, state, history, and session recovery.

## Safety boundary

- Used the installed Pi Coding Agent 0.82.1.
- Created isolated git, session, and synthetic command targets under
  `/private/tmp`.
- Reused existing provider authentication without reading credentials.
- Loaded extensions only in isolated throwaway Pi environments; did not
  install them or edit the user's real Pi settings.
- Proved automatic extension discovery by launching a separate TUI without an
  extension command-line flag.
- Used bounded `sleep` commands to test steer and abort.
- Used a nonexistent, uniquely named target to test a denied permission
  request; the command was blocked before execution.
- Did not open or mutate existing user Pi session transcripts.
- Stopped the test TUI, verified that shutdown removed its socket, and moved
  the isolated workspace, session, and bridge directories to Trash after the
  spike.

## Tested environment

The installed package was:

- package: `@earendil-works/pi-coding-agent`
- version: `0.82.1`
- launcher: `~/.nvm/versions/node/v24.16.0/bin/pi`
- runtime: Node 24.16.0

The `pi` launcher failed in a Finder-like minimal `PATH` because its
`#!/usr/bin/env node` interpreter could not resolve `node`. Invoking the
resolved Node binary with Pi's resolved `dist/cli.js` entry point worked.

Conn therefore cannot cache only `command -v pi`. It must resolve and validate
the Node runtime plus the Pi entry point, or adopt another supported runtime
strategy that remains valid when launched outside a login shell.

## Protocol shape

Pi RPC is newline-delimited JSON over stdin/stdout. Commands may carry an
arbitrary `id`, which is echoed by their correlated response. Runtime activity
arrives as asynchronous events.

The spike observed that correlated responses do not necessarily complete in
input order. A `get_state` sent alongside `set_model` returned first and still
showed the old model. Conn must:

1. correlate every mutation by command ID;
2. wait for that mutation's success response; and
3. only then issue dependent reads.

A successful command response means the command was accepted, not that the
model turn succeeded. An Anthropic prompt was accepted and then failed through
structured runtime events because the account had no extra usage. Conn must
preserve the difference between pre-execution rejection, post-accept runtime
failure, abort, and successful settlement.

## Capability results

| Codex capability in Conn | Pi RPC result | Evidence and boundary |
| --- | --- | --- |
| Create an ad-hoc Session | Confirmed | A named, isolated RPC Session was created and returned a stable session ID and session file. |
| Choose model | Confirmed | `set_model` changed the active Session from Anthropic Haiku to OpenAI Codex `gpt-5.4-mini`; subsequent state and turns used the new model. |
| Choose reasoning effort | Confirmed | Pi exposed supported thinking levels and accepted `low`; state reported the effective value. |
| Send an idle follow-up | Confirmed | A second prompt settled with the exact expected reply on the same Session. |
| Steer an active run | Confirmed | During a 20-second bash tool call, `steer` was accepted, appeared in `queue_update`, and replaced the intended final response with `STEER_APPLIED`. |
| Queue a follow-up while busy | Confirmed | `follow_up` was accepted during the same active turn, remained separate from the steering queue, and ran after the steered turn as `FOLLOW_UP_APPLIED`. |
| Interrupt an active run | Confirmed | `abort` stopped a 30-second bash command, emitted an aborted tool result and turn, settled the agent, and returned a correlated success response. |
| Stream activity and output | Confirmed | RPC emitted agent, turn, message, text-delta, tool execution, queue, error, and settled events with structured usage. |
| Read current state | Confirmed | `get_state` returned model, thinking, streaming/compaction flags, queue modes, session identity, name, file, and message counts. |
| Read conversation history | Confirmed | `get_messages` returned the structured Session history. |
| Recover after Conn restart | Confirmed | A new RPC process opened the exact saved session file and returned the same session ID, name, model, thinking level, message count, and history. |
| Answer a structured question | Confirmed through extension UI | An explicitly loaded extension emitted an `input` request; the correlated UI response was received and acknowledged through a notification. |
| Resolve a permission request | Confirmed through an extension-defined policy | Pi's example permission gate emitted a `select` request for a synthetic `rm -rf`; replying `No` blocked the tool before execution and the turn reported `APPROVAL_BLOCKED`. |
| Discover externally created Sessions | Read-only inventory is feasible | Pi persists documented session files and its SDK exposes session listing. File presence does not prove that a TUI process is currently live. |
| Follow up an externally launched TUI | Confirmed through global extension | A separately launched TUI auto-loaded the isolated bridge extension. A socket command injected an idle prompt and the original TUI replied exactly `EXTERNAL_FOLLOWUP_OK`. |
| Steer an externally launched TUI | Confirmed through global extension | During an active turn in the original TUI, the bridge delivered a supported `steer` message. The original response was replaced by exactly `EXTERNAL_STEER_OK`. |
| Interrupt an externally launched TUI | Confirmed through global extension | The controller waited for `tool_execution_start`, called the bridge while `sleep 30` was active, and the original TUI reported `Command aborted` after 0.1 seconds followed by `Operation aborted`. |

## Questions and approvals

Pi has a documented extension UI subprotocol for `select`, `confirm`, `input`,
and `editor`, plus fire-and-forget notifications and status updates. Requests
have unique IDs and block the extension until the RPC client returns a matching
response.

This is enough to map Pi questions into Conn's existing attention UI for
Conn-managed Sessions.

Permission requests are different from Codex:

- Codex exposes a native approval protocol and policy vocabulary.
- Pi provides extension interception around tool calls.
- Conn can load a bundled, versioned permission extension explicitly for its
  managed processes without editing user settings.
- The Pi Integration must describe the exact policy it implements; it must not
  pretend that a Conn-defined extension is Pi's universal native permission
  model.

## External TUI bridge spike

The external-control test used a separate interactive Pi process with an
isolated agent directory. The bridge extension was placed in that directory's
global `extensions/` location, and the TUI was launched normally with no
`--extension` argument. Its startup UI confirmed that `conn-bridge.ts` had been
auto-loaded.

The controller then connected from another process:

1. **Idle follow-up:** injected `Reply exactly EXTERNAL_FOLLOWUP_OK.`; the
   original TUI produced exactly `EXTERNAL_FOLLOWUP_OK`.
2. **Busy steer:** while the original TUI was running a turn containing a
   20-second tool call, injected a steer message; the original requested
   response was replaced by exactly `EXTERNAL_STEER_OK`.
3. **Active-tool interrupt:** waited until bridge state reported
   `lastEvent: "tool_execution_start"` and `activeToolCount: 1`, then sent
   interrupt. The original TUI showed `sleep 30`, `Command aborted`,
   `Took 0.1s`, and `Operation aborted`; the prohibited completion marker was
   not produced.
4. **Lifecycle:** exiting the original TUI invoked extension shutdown and
   removed its socket. Resuming the same stable Pi session created a new
   process registration without changing the Pi session ID.

The prototype also exposed a protocol requirement: mutation acknowledgements
can precede the corresponding state/event transition. Production commands need
an acceptance acknowledgement plus later event-sequenced observation of their
effect.

## Privacy and decoder boundary

OpenAI Codex-backed Pi events included opaque encrypted reasoning signatures in
partial and completed message payloads. Conn does not need these fields for its
Session UI.

The adapter must use a strict allowlist and persist only bounded semantic
content:

- stable Session identity and name;
- qualified state transitions;
- user-visible text;
- tool name plus deliberately selected status metadata;
- model/thinking identity;
- attention request title, options, and correlation identity; and
- bounded usage/error summaries.

It must drop encrypted signatures, raw provider envelopes, unbounded tool
payloads, credentials, and unknown fields.

## Recommended product contract

### Managed Pi Sessions

Conn starts and owns one Pi RPC subprocess per active managed Session. These
Sessions can support:

- ad-hoc creation;
- model and thinking selection;
- live streaming;
- idle follow-up;
- active steer;
- queued follow-up;
- interrupt;
- question answering;
- Conn-defined permission mediation;
- recovery from the saved session file; and
- explicit open/export handoff.

This is an embedded-client integration, not passive supervision. It is still a
supported Pi contract: RPC mode exists specifically for embedding Pi in other
applications.

### Bridged external Pi TUI Sessions

Conn installs a versioned bridge as a global Pi extension, with explicit user
consent. Pi auto-discovers global extensions for ordinary independently
launched TUI Sessions, so users do not need a wrapper command or recurring
launch flag.

The extension runs in the original TUI process and connects to a Conn-owned,
user-local broker. It publishes only allowlisted semantic state and accepts
correlated follow-up, steer, and interrupt commands:

- idle follow-up maps to `pi.sendUserMessage(...)`;
- active steer maps to `pi.sendUserMessage(..., { deliverAs: "steer" })`;
- busy follow-up maps to `pi.sendUserMessage(..., { deliverAs: "followUp" })`;
  and
- interrupt maps to `ctx.abort()`.

This is genuine control of the externally launched process. Conn does not open
the saved session file in a competing Pi process.

### Unbridged external Pi Sessions

Conn may show saved unbridged Pi Sessions as read-only history after a strict
schema and privacy review. It must label liveness as unknown and must not offer
control actions.

The bridge cannot be injected retroactively into an already-running TUI that
never loaded it. The user must reload extensions or restart that Pi Session
once after installation. A Session launched with extension loading disabled is
also explicitly unsupported.

The product contract is therefore capability-based:

- bridge connected: follow-up, steer, busy follow-up, and interrupt available;
- saved session only: read-only inventory, liveness unknown; and
- bridge disconnected: controls disabled immediately, without starting a
  competing writer.

## Implementation gates

Before production implementation:

1. Pin and qualify supported Pi versions, starting with 0.82.1.
2. Decide whether Pi remains a user-installed prerequisite or is bundled under
   a compatible distribution strategy.
3. Implement Finder-safe Node and Pi entry-point resolution.
4. Use real pipes, never a pseudo-terminal; the test PTY echoed input JSON.
5. Build a strict JSONL decoder with command-ID correlation and unknown-event
   tolerance.
6. Treat `agent_settled` as runtime settlement, not the initial command
   response.
7. Preserve steer and follow-up as distinct queues.
8. Bundle and version the TUI bridge plus any question/permission extension.
   Install the global extension transparently and only with explicit consent;
   own clean upgrade and uninstall paths without touching unrelated files.
9. Define an allowlisted permission policy and deny safely if the Conn UI
   disconnects.
10. Use a Conn-owned session directory or ownership marker so managed and
    external Sessions cannot be confused.
11. Enforce a single live writer per managed session file.
12. Redact opaque provider fields before projection or persistence.
13. Prefer an outbound connection from each extension to one Conn-owned broker
    over a listener per TUI. The broker owns authentication, command
    correlation, lifecycle, stale-client cleanup, and protocol versioning.
14. Restrict bridge and broker storage to the current user and add a
    per-install capability handshake; Unix file permissions alone do not
    distinguish Conn from every other same-user process.
15. Separate command acceptance from observed settlement. The prototype
    intentionally exposed that `sendUserMessage` can acknowledge before Pi's
    state changes.
16. Treat extension-disabled Sessions and pre-install live Sessions as
    honestly unbridged, never silently fall back to concurrent session-file
    access.

## Go/no-go

**Go** for Pi Integration with both Conn-managed RPC Sessions and bridged
external TUI Sessions. The spike confirmed the hard external-control
requirements in the original TUI: follow-up, genuine active steering, and
active-tool interrupt.

The qualification is one-time extension installation, not recurring session
ownership or launch ceremony. Conn can automate that installation with
explicit consent. Sessions that have not loaded the bridge remain honestly
read-only until reload or restart.

## Primary references

- Pi RPC documentation: <https://pi.dev/docs/latest/rpc>
- Pi extension documentation: <https://pi.dev/docs/latest/extensions>
- Pi security and project trust documentation:
  <https://pi.dev/docs/latest/security>
- Pi SDK documentation:
  <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md>
- Pi 0.82.1 release:
  <https://pi.dev/news/releases/0.82.1>
