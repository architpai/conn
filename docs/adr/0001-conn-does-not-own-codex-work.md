# Conn does not own Codex work

Status: Accepted; integration mechanism amended by ADR 0003

Conn is a non-owning companion over Codex-owned sessions and processes. Starting, closing, crashing, or quitting Conn must not determine whether Codex work continues. Conn must never substitute a child Codex or App Server process that it owns merely to gain monitoring or control.

[ADR 0003](./0003-codex-managed-app-server-daemon.md) makes the Codex-managed App Server daemon Conn's integration boundary. The invariant still holds: Conn may connect to or request startup of a Codex-managed daemon, but Conn quitting, crashing, or disconnecting must not stop the daemon, its threads, or their turns.

A Conn-owned `codex app-server proxy` child is permitted only as a disposable transport helper to that managed daemon. It owns no App Server or Codex work; proxy or Conn exit is a connection loss, while the daemon and turns continue.
