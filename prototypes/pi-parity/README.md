# Pi behavioral parity prototype

This is throwaway feasibility code, not a production Conn adapter.

Question: can a Conn-owned broker and a standard global Pi extension reproduce
the current Conn-Codex behavior surface for an independently launched Pi TUI,
survive broker restart, and support a safe Settings-driven install lifecycle?

The prototype includes:

- `extension.ts`: runs inside the original Pi TUI and connects outbound;
- `broker.mjs`: owns the local Unix socket and live-session registry;
- `controller.mjs`: sends correlated Conn-style actions; and
- `installer.mjs`: exercises isolated install, update, conflict, and removal.

All manual spike commands use isolated directories under `/private/tmp`.
`PI_CODING_AGENT_DIR` must never point at the user's real Pi directory while
running the installer prototype.

Start the broker:

```sh
CONN_PI_BROKER_SOCKET=/private/tmp/conn-pi-parity/broker.sock \
node prototypes/pi-parity/broker.mjs
```

Launch Pi with `extension.ts` installed into the isolated agent directory's
global `extensions/conn/index.ts`, then inspect it:

```sh
CONN_PI_BROKER_SOCKET=/private/tmp/conn-pi-parity/broker.sock \
node prototypes/pi-parity/controller.mjs list
```

The spike is complete only when the report records evidence for model and
thinking changes, structured answer, approval deny/approve, broker reconnect,
session replacement/reload lifecycle, and safe installation behavior.
