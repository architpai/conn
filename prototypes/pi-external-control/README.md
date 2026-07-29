# External Pi TUI control prototype

This is throwaway feasibility code, not a production Conn adapter.

Question: can Conn follow up, steer, and interrupt a Pi TUI that the user
launched independently, without opening the same session in a competing Pi
process?

The prototype loads `conn-bridge.ts` as a normal Pi extension. The extension
runs inside the original TUI process and maps a user-local Unix socket onto
Pi's supported extension APIs:

- `pi.sendUserMessage(...)` for idle follow-up;
- `pi.sendUserMessage(..., { deliverAs: "steer" })` for active steering;
- `pi.sendUserMessage(..., { deliverAs: "followUp" })` for busy follow-up; and
- `ctx.abort()` for interrupt.

For an isolated manual run:

```sh
CONN_PI_BRIDGE_DIR=/private/tmp/conn-pi-bridge \
pi --extension ./prototypes/pi-external-control/conn-bridge.ts
```

In another terminal:

```sh
CONN_PI_BRIDGE_DIR=/private/tmp/conn-pi-bridge \
node prototypes/pi-external-control/controller.mjs list
```

Use the returned PID for `state`, `follow-up`, `steer`, or `interrupt`.

Production would install a versioned copy as a global Pi extension under
`~/.pi/agent/extensions/`. Pi auto-loads global extensions in independently
launched TUI sessions; no wrapper command or special launch flag is then
required.

The production transport should invert this prototype: Conn owns one broker,
and each loaded extension connects outbound and registers its Pi session and
process identity. This avoids one listener per TUI and gives Conn a single
place for authentication, protocol versioning, command correlation, lifecycle,
and stale-client cleanup.

Boundaries:

- installation should be explicit and reversible because it adds a global Pi
  extension;
- a TUI that was already running before installation needs an extension reload
  or restart;
- a TUI launched with extensions disabled is not controllable;
- command acceptance and observed settlement are separate protocol events; and
- Conn must never reopen the same session file as a fallback writer.
