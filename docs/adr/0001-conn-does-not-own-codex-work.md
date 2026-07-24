# Conn does not own harness work

Status: Accepted; integration mechanism amended by ADR 0003

Conn is a non-owning companion over harness-owned sessions and processes.
Starting, closing, crashing, or quitting Conn must not determine whether
supervised work continues. A normal Conn integration must never substitute a
Conn-owned harness process merely to gain monitoring or control.

Session creation origin, lifecycle ownership, and retention are independent.
A session explicitly created through Conn is Conn-originated only after the
harness acknowledges it, but its lifecycle remains harness-owned. An ephemeral
session has harness-declared temporary retention; ephemeral does not mean
Conn-owned.

[ADR 0003](./0003-codex-managed-app-server-daemon.md) makes the Codex-managed App Server daemon Conn's integration boundary. The invariant still holds: Conn may connect to or request startup of a Codex-managed daemon, but Conn quitting, crashing, or disconnecting must not stop the daemon, its threads, or their turns.

A Conn-owned `codex app-server proxy` child is permitted only as a disposable transport helper to that managed daemon. It owns no App Server or Codex work; proxy or Conn exit is a connection loss, while the daemon and turns continue.

Any future mode that requires Conn to own a harness session or its running
process is a distinct product mode and requires a new explicit architecture
decision. It cannot be introduced as an ordinary integration adapter.
