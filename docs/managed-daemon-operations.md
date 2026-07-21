# Conn setup, migration, privacy, and removal

Status: Active Phase 11 operations contract
Updated: 2026-07-20

## Setup

Conn requires a supported Codex CLI and uses `codex app-server proxy --sock` to
connect to the current user's Codex-managed App Server daemon. Install and open
`Conn.app`; no Conn or Sidequest Codex plugin is required. Conn does not install
hooks, enable daemon remote control, modify the Codex or ChatGPT application
bundle, or take ownership of the daemon and its threads.

Managed Daemon Mode is the normal product mode. Shared Desktop Mode is a
separate, off-by-default Labs experiment; its setup and rollback contract is in
[shared-desktop-mode.md](shared-desktop-mode.md).

## Upgrading from the hook-era build

On first launch, Conn explicitly discards only these obsolete local checkpoint
roots when they exist:

- `~/Library/Application Support/Sidequest/Bridge/v1`
- `~/Library/Application Support/Sidequest/Domain/v1`

The cleanup does not import those checkpoints and never touches
`~/Library/Application Support/Conn/AppServerDomain/v1`. A private one-shot
marker records completion. A symlink, non-directory, owner mismatch, or other
unsafe path stops cleanup and is reported as repair-needed; it never re-enables
the legacy bridge.

The legacy Sidequest plugin is not part of the Conn app or release artifact.
Before deleting an old installation, open Codex `/plugins`, locate an installed
plugin whose displayed identity is Sidequest and whose selector belongs to the
old `sidequest-local` or `sidequest-release-*` marketplace, and explicitly
remove that exact selector. For the repository-development build, the known
command is:

```sh
codex plugin remove sidequest@sidequest-local
```

Do not remove an entire marketplace unless you have separately confirmed it
contains no other plugins. Removing the legacy plugin does not stop, delete, or
alter Managed Daemon threads.

## Privacy boundary

Conn consumes structured App Server Thread, Turn, Item, request, and status
messages needed for its visible supervision surface. It does not poll transcript
files or run a hook inbox. Raw reasoning deltas remain opted out.

When supported by the pinned App Server version, Conn may inspect configured
hooks through `hooks/list` and show `hook/started` and `hook/completed` activity.
That diagnostic projection keeps bounded hook identity, type, source, trust,
scope, status, and timestamps. It drops hook commands, working directories,
source paths, entry text, status messages, and raw warning or error strings.
Hook activity never determines whether a thread or turn is active, completed,
failed, or awaiting attention.

## Troubleshooting

- If Conn reports an unsupported Codex version, install one of the versions
  named in the packaged compatibility documentation. Conn fails closed instead
  of guessing at a newer protocol.
- If monitoring is stale, use Sync after the managed-daemon connection returns.
  Conn rehydrates from App Server; it does not fall back to hooks.
- If legacy cleanup needs repair, inspect only the exact two Sidequest `v1`
  paths above for a symlink, unexpected file type, or unexpected owner. Preserve
  the rest of Application Support.
- If hook diagnostics are unavailable, thread monitoring still works. Hook
  visibility is version-gated diagnostic context, not the work lifecycle.
- Shared Desktop Mode problems follow the Labs rollback instructions and do not
  change Managed Daemon Mode.

## Uninstall Conn

Quit Conn and remove `Conn.app`. This disconnects Conn but does not stop the
Codex-managed daemon or delete Codex threads. If you also want to remove Conn's
disposable local state, remove its preferences and the exact
`~/Library/Application Support/Conn` directory after confirming Conn is not
running. Do not remove the broader Application Support directory.

If an old Sidequest plugin is still installed, remove its exact selector as
described in the upgrade section. Marketplace removal remains a separate manual
decision because a marketplace may contain unrelated plugins.
