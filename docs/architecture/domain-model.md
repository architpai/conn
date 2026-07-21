# Conn domain model

Conn is a notch-anchored macOS companion that lets people supervise Codex work while keeping their attention on other activities.

This vocabulary documents the product and architecture boundaries used by the
Conn codebase. In particular, Conn observes and controls supported operations;
it does not own Codex threads or their lifecycle.

## Language

### Work and ownership

**Conn**:
A Dynamic Island-like App Server client for supervising and controlling connected Codex work without owning its lifecycle.
_Avoid_: Sidequest, Backseat, universal Codex observer, Codex replacement, notification utility

**Codex Thread**:
A Codex-owned conversation identified by App Server whose lifecycle remains independent of Conn.
_Avoid_: Conn job, hook session, Conn process

**Conn Integration**:
A validated connection between the native Conn app and the current user's Codex-managed App Server daemon.
_Avoid_: Plugin bridge, patched Codex, private Desktop IPC

**Managed Daemon**:
The Codex-managed App Server process that owns the connected thread runtime and can outlive Conn.
_Avoid_: Conn child process, Conn server

**Managed Daemon Mode**:
The general Conn mode that supervises only threads started, loaded, or rejoined through the connected Managed Daemon.
_Avoid_: All Codex mode, automatic Desktop monitoring

**Shared Desktop Mode**:
An experimental power-user mode in which Codex Desktop and Conn are verified clients of the same Managed Daemon.
_Avoid_: Default Desktop integration, supported Desktop patch

**Connected Thread**:
A Codex Thread that Conn has successfully read or rejoined through its current App Server Connection.
_Avoid_: Every persisted thread, unrelated CLI thread, silently discovered session

**Active Thread**:
A Connected Thread with authoritative active-turn, unresolved-attention, failure, or unreviewed-outcome state.
_Avoid_: Silent thread assumed to be running, acknowledged recent thread

**Subagent Activity**:
Observed delegated work within a Codex Thread, nested only when App Server supplies stable identity and parentage.
_Avoid_: Invented child thread, inferred hidden agent

**App Server Observation**:
A structured Thread, Turn, Item, status, or request fact delivered through the current App Server Connection.
_Avoid_: Hook event, transcript scrape, inferred Desktop state

**Daemon Hook Diagnostic**:
A bounded configured-hook summary or hook execution fact supplied by stable App Server methods. It may explain daemon integration activity but never determines Thread or Turn lifecycle.
_Avoid_: Legacy Sidequest hook, work completion signal, transcript source

**App Server Connection**:
The initialized, capability-negotiated subscription through which Conn observes and controls Connected Threads.
_Avoid_: Lifecycle ownership, private IPC connection

**Monitoring**:
Automatic presentation of Connected Threads from authoritative App Server Observations.
_Avoid_: Claiming discovery of every local thread, lifecycle ownership

### Surface and status

**Notch Surface**:
The compact and expandable top-center interface used to supervise Connected Threads.
_Avoid_: Main window, dashboard, floating widget

**Idle Handle**:
The minimal Notch Surface shown when no Active Thread exists so Conn remains reachable.
_Avoid_: Idle status card, hidden app

**Codex Activity**:
The latest meaningful work state grounded in structured App Server Observations.
_Avoid_: Progress percentage

**Activity Label**:
The current user-facing work description supplied by Codex, or a conservative grounded fallback.
_Avoid_: Model-generated progress claim, raw protocol method

**Status Indicator**:
The icon, text, color, and optional motion that communicate a thread's current state.
_Avoid_: Color-only status, progress percentage

**Thread Label**:
A Codex-provided title when available, otherwise a repository or working-directory name paired with a short thread identifier.
_Avoid_: Prompt-derived title, unexplained numeric suffix

**Activity Timeline**:
A compact sequence of normalized observed events intended for rapid status comprehension.
_Avoid_: Transcript, terminal log, diff viewer

**Connection Freshness**:
Whether displayed thread state is Live, Rehydrated, Stale, or unavailable because the App Server Connection needs repair.
_Avoid_: Treating silence as completion

### Attention and control

**Attention Request**:
A grounded thread state that requires the user to grant permission, answer a question, or respond to a failure.
_Avoid_: Notification

**Attention State**:
The persistent expanded presentation of an unhandled Attention Request.
_Avoid_: Modal, alert dialog

**Permission Request**:
A Codex approval request presented with its exact operation, supported decisions, and Codex-defined scope.
_Avoid_: Generic confirmation, Conn-defined permission

**Structured Question**:
A Codex question containing one or more grouped prompts, supported choices, and optional free-text fields.
_Avoid_: Generic chat message, flattened prompt

**Answer**:
A capability-gated response that resolves a pending question through the supported request that asked it.
_Avoid_: Steer, Follow-up

**Steer**:
An instruction appended to the exact active turn through App Server without creating a new turn.
_Avoid_: Answer, Follow-up

**Follow-up**:
A message that starts a new turn on an idle Connected Thread.
_Avoid_: Answer, Steer

**Stop Turn**:
An explicit supported request to interrupt the selected thread's active turn.
_Avoid_: Quit Conn, disconnect, kill process

**Open in Codex**:
An explicit action that returns to Codex, targeting the selected thread only when supported.
_Avoid_: Implicit navigation, compact-notch click

**Resolved Elsewhere**:
An Attention Request proven by a supported source to have been handled by another Codex surface.
_Avoid_: Conn failure, retryable request

### Input and outcomes

**Voice Dictation**:
A user-started and user-stopped recording session that transcribes into the active text field for review before sending.
_Avoid_: Press-and-hold recording, always-listening mode, automatic sending

**Acknowledged Outcome**:
A completed or failed Connected Thread whose result the user has dismissed or opened.
_Avoid_: Active thread, unread completion

**Recent Thread**:
An Acknowledged Outcome retained temporarily for quick return without contributing to live activity.
_Avoid_: Running thread, archived thread

**Outcome Summary**:
A completion or failure card grounded only in supported Codex fields and observed facts.
_Avoid_: Independently generated re-entry brief

**Stale Observation**:
The condition in which Conn's last rehydrated or observed state may no longer be current while Codex-owned work continues independently.
_Avoid_: Thread failure, interrupted Codex

**Integration Repair**:
Guidance for a missing daemon, unsafe endpoint, incompatible protocol, disconnected client, or unverified Shared Desktop Mode.
_Avoid_: Codex failure, automatic trust bypass

## Relationships

- The **Conn Integration** delivers **App Server Observation** to the native **Conn** app
- **Monitoring** presents **Active Threads** among known **Connected Threads**
- **Connection Freshness** qualifies every displayed work state
- **Managed Daemon Mode** is general; **Shared Desktop Mode** is an experimental widening of the same connection
- **Subagent Activity** nests only when App Server supplies stable identity and parentage
- Subagent **Attention Requests** bubble to their top-level thread when grounded
- The **Notch Surface** summarizes Active Threads and becomes an **Attention State** for unresolved attention
- An **Idle Handle** keeps the Notch Surface reachable when no Active Thread exists
- A Codex Thread has a latest observed **Codex Activity**, expressed through an **Activity Label** and **Status Indicator**
- Selecting a thread reveals its **Activity Timeline**
- **Permission Requests** and **Structured Questions** are kinds of **Attention Request** only when the integration exposes them
- **Answer**, **Steer**, **Follow-up**, and **Stop Turn** require a capability that supports the exact action
- **Voice Dictation** supplies editable text only to an available text action
- An **Acknowledged Outcome** becomes a **Recent Thread**
- **Resolved Elsewhere** requires supported reconciliation evidence
- A **Stale Observation** changes Conn presentation without changing Codex work
- **Integration Repair** restores the connection or mode verification; it does not repair Codex work itself
- **Open in Codex** leaves supervision for the full Codex work surface
- The **App Server Connection** is the only live source for **Monitoring** and control
- A **Daemon Hook Diagnostic** is inspectable context only; it never creates an **Active Thread** or **Attention Request**

## Example dialogue

> **Developer:** Do I need to keep Codex visible while Conn-connected threads are working?
>
> **Product expert:** No. Collapse Conn into the Notch Surface. It will show threads from its Managed Daemon and surface supported attention events.
>
> **Developer:** If I quit Conn, do those threads stop?
>
> **Product expert:** No. Codex owns the daemon and threads. Quitting Conn disconnects its client without stopping the work.

## Flagged ambiguities

- All active threads means active threads in the current App Server Connection; it does not mean every local, persisted, Desktop, or CLI thread.
- Companion means Conn never owns Codex Threads or their running processes.
- Managed does not mean Conn-owned; Codex manages the daemon and its lifetime is independent of the Conn app.
- Live means confirmed by the current connection, not merely restored from Conn persistence.
- Blocked is avoided because it conflates permission, question, failure, stale observation, and integration repair; use the precise state.
- Reply is avoided when capability semantics matter; use Answer, Steer, or Follow-up only when supported.
- Attention is persistent state inside the Notch Surface, not merely a transient notification.
- Codex wording and permission scope are authoritative when supplied.
- Turn completion, failure, and interruption require authoritative App Server state.
- Experimental API opt-in enables gated methods or fields; it does not create a shared transport or prove Shared Desktop Mode.
- Shared Desktop means verified same-daemon membership, not merely a running daemon or a listed persisted thread.
- Dynamic Island-like describes interaction character; Conn does not copy Apple's exact animation or use private notch APIs.
