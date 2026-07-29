# Pi behavioral parity spike for v0.2.1

Status: complete

Date: 2026-07-29

## Decision

Proceed with the Pi extension route.

The spike achieved semantic parity with Conn's current Codex action surface
for an independently launched Pi TUI. It did not prove that the two providers
have identical protocols or process ownership:

- Conn can observe state and output, follow up, steer, queue a busy follow-up,
  interrupt, select model and thinking level, answer a structured question,
  and approve or deny intercepted tools in the original Pi process.
- Pi supplies the supported extension APIs, lifecycle events, tool
  interception, and global extension discovery needed for the bridge.
- Conn must define and disclose its Pi approval policy. Pi does not expose the
  same native approval vocabulary as Codex.
- Conn's model picker must show authenticated and usable models, not Pi's
  unqualified global model registry.

The correct product claim is **100% parity for Conn's current semantic actions
when the Pi bridge is connected**, not byte-for-byte or architectural identity
with the Codex App Server integration.

## Tested architecture

The throwaway prototype used:

1. a global Pi extension auto-discovered from the isolated
   `PI_CODING_AGENT_DIR`;
2. an outbound connection from that extension to a Conn-owned Unix-socket
   broker;
3. a separate controller representing Conn; and
4. a versioned, ownership-marked installer representing the Settings flow.

Pi was launched as an ordinary external TUI with no extension flag. Conn did
not launch, wrap, reopen, or terminate the original Pi process.

Tested with Pi Coding Agent 0.82.1 and Node 24.16.0 in isolated directories
under `/private/tmp`. Existing authentication was reused without reading
credentials. The user's real Pi configuration and sessions were not modified.

## Parity matrix

| Conn behavior | External Pi result | Ground-truth boundary |
| --- | --- | --- |
| Discover live Sessions | Confirmed | The extension registered the original Pi PID, stable Pi session ID, session file, cwd, model, thinking, idle/busy state, active tools, and pending attention. |
| Stream activity and output | Confirmed | The extension observed session, agent, turn, message, and tool lifecycle events in the original process. Production must allowlist the projected fields. |
| Idle follow-up | Confirmed | The original TUI accepted a controller message and replied with the exact requested token. |
| Steer active work | Confirmed | A supported `steer` delivery changed the active original-TUI turn. |
| Queue follow-up while busy | Confirmed | Pi exposes a distinct `followUp` delivery mode; it must remain distinct from steer in Conn. |
| Interrupt active work | Confirmed | `ctx.abort()` stopped the active original-TUI tool and turn. |
| Select model | Confirmed | The controller changed the original TUI from `gpt-5.4-mini` to `gpt-5.4`; state and the TUI footer agreed. |
| Select thinking level | Confirmed | The controller changed thinking from `low` to `medium`; state and the TUI footer agreed. |
| Answer a structured question | Confirmed | A Conn-defined Pi tool published a correlated question, blocked, received `PARITY_OK`, and the original turn completed with `QUESTION_ANSWER_PARITY_OK`. |
| Deny a permission request | Confirmed | A marked bash tool was intercepted, denial returned to the original turn, and the denied marker file was absent. |
| Approve a permission request | Confirmed | The same interception path received approval, executed the marked command, and produced the expected marker. |
| Survive Conn broker restart | Confirmed | The broker stopped and its socket disappeared while the original Pi PID remained alive. The extension reconnected to a restarted broker and accepted a new follow-up. |
| Pi `/reload` | Confirmed | The extension shut down, a fresh extension instance registered against the same Pi PID and session ID, and state reported `session_start:reload`. |
| Pi `/new` | Confirmed | The same Pi PID switched to a new stable session ID, re-registered, and accepted a new Conn follow-up that returned `NEW_SESSION_BRIDGE_OK`. |
| Pi `/fork` | Confirmed | Selecting a branch created another stable session ID and state reported `session_start:fork`. |
| Exit and resume | Confirmed | Exit removed the live registration. A newly launched TUI resumed the exact saved session ID and its globally installed bridge registered at startup. |
| Ad-hoc chat creation | Confirmed by RPC spike | Conn-managed Pi RPC Sessions support create, prompt, streaming, model/thinking selection, recovery, and the same action semantics. |

## Settings and lifecycle contract

The extension can use the same product area as Conn's existing integration and
desktop behavior, with provider-specific copy:

- `Enable Pi integration` installs Conn's global extension after explicit user
  consent.
- Conn owns only `~/.pi/agent/extensions/conn/` and records an exact ownership
  and version manifest there.
- Install and update use a prepared sibling directory followed by rename.
- Update replaces only a target carrying Conn's ownership marker.
- Removal refuses foreign or malformed targets and removes only the exact
  Conn-owned directory.
- An already-running Pi TUI needs one `/reload` after first install or update.
  New Pi TUIs auto-load the extension with no flags.
- Conn's existing launch-at-login setting starts Conn and its broker. The
  extension reconnects automatically after Conn restarts.
- Conn never launches, relaunches, or kills external Pi TUIs. Those remain
  user-owned.
- If the extension is missing, disabled, incompatible, or disconnected, Conn
  immediately disables live controls. Saved-session inventory may remain
  read-only with liveness labelled unknown.

The installer test covered fresh install, versioned update, status, removal,
and foreign-target conflict. The conflict test initially exposed a bug:
missing ownership metadata inside an existing directory was mistaken for a
missing directory. The prototype was corrected and the rerun failed closed
while preserving the foreign directory.

## Product differences that must remain visible

### Approval semantics

Codex supplies a native approval protocol. Pi supplies supported tool-call
interception, from which the Conn extension implements a policy. The user
experience can be the same, but the Pi integration must disclose the actual
policy and default to denial when Conn disconnects or a request expires.

### Model catalog

Pi's model registry returned thousands of registered provider/model
combinations, including entries without usable authentication. A production
picker needs a qualified capability probe and must handle `setModel` returning
false. Dumping the raw registry into Conn would be misleading.

### Process ownership

Codex Shared Desktop and Pi's external bridge have different transport and
ownership boundaries. The common Conn domain should expose capabilities and
actions; provider adapters should preserve their native lifecycle.

### Installation timing

Pi auto-discovers a global extension on process startup. It cannot be injected
into a TUI that is already running without the user's one-time `/reload` or a
restart. Conn should show this as `Installed — reload existing Pi sessions`,
not as an integration failure.

## Production gates

1. Pin a supported Pi version range and fail closed outside it.
2. Define the provider-neutral capability model and Pi action adapter.
3. Specify the exact allowlisted projection and privacy canaries.
4. Specify question timeout, approval timeout, disconnect, and deny behavior.
5. Qualify authenticated/usable models and thinking levels.
6. Harden the broker with per-user permissions, authentication, correlation,
   bounded queues, and stale-instance rejection.
7. Replace prototype deletion with a recoverable install transaction and
   verify rollback after interrupted updates.
8. Add Settings states for absent, installed, update available, reload needed,
   connected, incompatible, conflict, and disconnected.
9. Run the same parity suite against every supported Pi release.

No production integration code was started by this spike.
