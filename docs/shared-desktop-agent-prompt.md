# Conn Shared Desktop Mode — bounded setup agent prompt

Prompt contract: **v2**

Contract date: **2026-07-21**

Copy the prompt below into a local coding agent that has access to the Conn
repository and the current Mac. The agent must read
[`shared-desktop-mode.md`](./shared-desktop-mode.md) before acting.

---

## Copyable prompt

You are guiding Conn Shared Desktop Mode setup contract v2, dated 2026-07-21.
This is a Labs/Experimental, off-by-default power-user setup. Managed Daemon
Mode is the general product and must remain available whether this setup
succeeds, fails, or is rolled back.

Read `docs/shared-desktop-mode.md` and
`docs/adr/0003-codex-managed-app-server-daemon.md` completely before taking any
action. Follow their narrower safety rule whenever instructions differ.

Work in exactly these stages:

1. Diagnose — automatic and read-only.
2. Proposed Effects — show exact scope, commands, evidence, and rollback.
3. Enable — stop for explicit Confirmation A before any mutation.
4. Relaunch — stop for separate Confirmation B; the user performs the Desktop
   quit/relaunch through the ordinary UI.
5. Verify — observe only a user-attested throwaway Desktop task.
6. Rollback — stop for explicit Rollback Confirmation before mutation; the
   user separately decides whether to quit/relaunch Desktop normally.

### Absolute boundaries

Never:

- quit, kill, or relaunch Codex Desktop yourself;
- modify `/Applications/ChatGPT.app` or any signed application bundle;
- open, connect to, probe, or reverse-engineer `$CODEX_HOME/ipc/ipc.sock`,
  `$HOME/.codex/ipc/ipc.sock`, or other private Desktop IPC;
- run `codex app-server daemon stop`, `restart`, `bootstrap`,
  `enable-remote-control`, or `disable-remote-control`;
- invoke an equivalent remote-control mutation through App Server;
- use `defaults`, edit a shell profile, install a system LaunchDaemon, or set
  machine-wide/global login state;
- print or retain full process environments, Codex config, tokens, prompts,
  transcripts, messages, raw reasoning, tool payloads, protocol params/results,
  or unbounded logs;
- manufacture live evidence from fixtures, stale checkpoints, persisted thread
  rows, or UI automation;
- start, steer, interrupt, approve, answer, or follow up on a thread as part of
  setup verification; or
- retry or retarget a consequential thread action after reconnect, selection,
  identity, or generation changes.

Retain Phase 9's `.connOriginatedTurnsOnly` policy. Resuming or selecting a
Desktop-originated thread never grants response authority. During this setup,
all Desktop-originated verification is read-only.

### Version truth

Use an exact tuple matrix, never a semver guess:

- Phase 5 qualified Codex Desktop `26.715.31251` build `5538`, bundled CLI
  `0.145.0-alpha.18`, and managed App Server `0.144.5`, then `0.144.6`.
- Codex Desktop `26.715.31925` build `5551`, bundled CLI
  `0.145.0-alpha.18`, and managed App Server `0.144.6` are candidate-only until
  Phase 10 completes same-daemon Desktop-origin, second-client delivery, and
  rollback proof.

Finding the internal environment-switch string in an app bundle is presence
evidence only. It is not a compatibility or sharing result.

### Stage 1 — Diagnose

Diagnosis may begin without confirmation because it is read-only. First resolve
and display:

- the current user's home directory and numeric GUI UID;
- the exact Desktop bundle path;
- the Desktop version/build and bundled CLI version;
- the exact allowlisted standalone Codex executable;
- launcher, managed Codex, and running App Server versions returned by the
  public `app-server daemon version` command;
- expected socket type, owner, and permissions plus its immediate parent's
  owner and permissions;
- presence of the named launchd GUI environment flag;
- presence, ownership, mode, validity, and hash status of only
  `$HOME/Library/LaunchAgents/com.conn.experimental-shared-desktop.plist`;
- launchd state for only
  `gui/<resolved-uid>/com.conn.experimental-shared-desktop`; and
- PID, parent PID, executable, and arguments for only the exact Desktop
  process, its direct App Server child, and the managed daemon.

Use repository-relative paths for repository files and `$HOME` placeholders in
the proposed human-facing commands. Before executing a mutating command,
resolve it to an exact absolute path and numeric UID and show that resolved
command.

Allowed diagnostic command shapes include:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  /Applications/ChatGPT.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /Applications/ChatGPT.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  /Applications/ChatGPT.app/Contents/Info.plist
/Applications/ChatGPT.app/Contents/Resources/codex --version
"$HOME/.codex/packages/standalone/current/codex" --version
"$HOME/.codex/packages/standalone/current/codex" \
  app-server daemon version
stat -f '%N type=%HT mode=%Sp uid=%u gid=%g' \
  "$HOME/.codex/app-server-control" \
  "$HOME/.codex/app-server-control/app-server-control.sock"
/bin/launchctl getenv CODEX_APP_SERVER_USE_LOCAL_DAEMON
/bin/launchctl print \
  "gui/$(id -u)/com.conn.experimental-shared-desktop"
```

Treat an absent launchd service as an ordinary `Off` or `Setup artifact not
loaded` state. Do not broaden a read because a command fails. Do not use
`ps e`, `ps eww`, `env`, `launchctl print` for the entire GUI domain, `defaults
read`, or `cat` on Codex configuration or logs. If a bounded setup log is needed
to explain a setup-owned failure, sanitize it before reporting and include no
conversation or configuration data.

The expected App Server endpoint is safe only when it is a Unix socket owned by
the current user, mode `0600`, inside an immediate current-user-owned directory
that is not group- or world-writable. Never repair an unsafe endpoint.

Report one precise state from the runbook's diagnostic state list. Do not call
the mode verified.

### Stage 2 — Proposed Effects

Before asking for permission, print a compact evidence table containing only:

- contract version and timestamp;
- exact version/build strings and matrix result;
- enumerated setup/verification state and bounded reason code;
- socket safety category;
- booleans for GUI flag, setup artifact, launchd job, private Desktop child,
  and managed-daemon presence;
- setup artifact ownership/mode/hash-match status; and
- verification-gate booleans.

Do not print thread content, IDs, full paths outside the fixed setup locations,
raw protocol envelopes, environment values other than whether the one named
flag is present, or full logs.

Then show all proposed effects:

- setup-owned plist:
  `$HOME/Library/LaunchAgents/com.conn.experimental-shared-desktop.plist`;
- launchd domain: `gui/<resolved-uid>`;
- environment key: `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`;
- possible idempotent start of the Codex-managed daemon through the exact
  allowlisted executable; and
- no app-bundle, config, private IPC, shell-profile, system, daemon-stop, or
  remote-control change.

Show the exact proposed plist diff and commands. The setup-owned job must:

- use the exact `com.conn.experimental-shared-desktop` label and declare only
  the job-local ownership marker
  `CONN_SHARED_DESKTOP_SETUP_CONTRACT=v2-2026-07-21` under
  `EnvironmentVariables`;
- use `RunAtLoad = true`, `ProcessType = Background`, and no persistent
  `KeepAlive` key;
- use `LimitLoadToSessionType = Aqua`;
- use exactly `/bin/launchctl setenv CODEX_APP_SERVER_USE_LOCAL_DAEMON 1` as
  `ProgramArguments`;
- contain no shell, Codex executable, daemon command, or log path;
- exit after setting the flag; and
- never retry forever.

The complete generated artifact has exactly these six top-level keys: `Label`,
`ProgramArguments`, `EnvironmentVariables`, `RunAtLoad`, `ProcessType`, and
`LimitLoadToSessionType`. Do not add logging, shell, calendar, throttle, or
keep-alive keys.

If the target plist exists and its exact label, current or recognized previous
contract markers, required job structure, or content hash do not match a
Conn-owned artifact, stop.
Show its path, safe metadata, structural match result, and hash, but not
unrelated content. Never overwrite, move, or delete it.

Show this rollback sequence before enablement:

```sh
/bin/launchctl bootout \
  "gui/$(id -u)/com.conn.experimental-shared-desktop"
/bin/launchctl unsetenv CODEX_APP_SERVER_USE_LOCAL_DAEMON
```

State that rollback removes only an exact Conn-owned plist and that the managed
daemon and external remote-control state will remain untouched.

Ask exactly one clear question for Confirmation A: whether to install or update
the displayed current-user setup state. Stop and wait. A general request to
"continue" before this displayed scope is not confirmation for hidden or
different effects.

### Stage 3 — Enable after Confirmation A

After explicit confirmation only:

1. If the managed daemon is absent, invoke only the fully resolved allowlisted
   standalone CLI's `app-server daemon start`, then poll only
   `app-server daemon version` and the expected socket metadata for a bounded
   deadline. Stop before installing anything if readiness is not established.
2. If this exact label is already loaded, unload only this label using the
   resolved equivalent of:

   ```sh
   /bin/launchctl bootout \
     "gui/$(id -u)/com.conn.experimental-shared-desktop"
   ```

   Treat a not-found service as an idempotent no-op. Do not unload any other
   job.
3. Create a temporary plist beside the destination without overwriting the
   destination.
4. Validate it with `plutil -lint`.
5. Stop if the destination changed or no longer matches the diagnosis.
6. Atomically move the validated setup-owned plist into place with mode `0600`.
7. Load only this label using the resolved equivalent of:

   ```sh
   /bin/launchctl bootstrap \
     "gui/$(id -u)" \
     "$HOME/Library/LaunchAgents/com.conn.experimental-shared-desktop.plist"
   ```

8. If RunAtLoad did not start it, use the resolved equivalent of:

   ```sh
   /bin/launchctl kickstart \
     "gui/$(id -u)/com.conn.experimental-shared-desktop"
   ```

   Do not use `kickstart -k`.
9. Poll only `app-server daemon version`, the expected socket metadata, the
   named GUI flag, and the one setup job for a bounded deadline.
10. Preserve failed setup state and report a sanitized failure. Do not fall back
   to an alternate executable, retarget another label, or loop indefinitely.

Treat already-correct, setup-owned state as an idempotent no-op. Re-run
diagnosis after each mutation.

If setup reaches `Ready for Desktop relaunch`, show that result and ask a
separate clear question for Confirmation B: whether the user wants to quit and
relaunch Codex Desktop now. Even after confirmation, do not perform it. Ask the
user to use the ordinary Desktop UI and tell you when it is running again.

### Stage 4 — Verify after the user's relaunch

Re-run the read-only diagnosis. First require:

- named GUI flag present;
- safe expected socket;
- exact candidate or qualified tuple;
- the same managed daemon survived; and
- the relaunched Desktop process has no private App Server child.

These facts establish `Candidate sharing`, not `Verified`.

For Desktop-origin proof:

1. Capture a metadata-only inventory baseline.
2. Ask the user to create a throwaway, non-sensitive Codex Desktop task.
3. Observe a new candidate identity within a bounded interval.
4. Ask the user to attest that the exact candidate corresponds to the
   throwaway task they just created. Do not infer origin from a generic source
   enum alone.
5. Resume the exact thread from the second client read-only. Do not start a
   turn or claim request ownership.
6. Ask the user to initiate harmless activity in Desktop.
7. Record only correlated lifecycle method and opaque in-memory identity
   evidence proving both subscribed clients received new events.
8. Disconnect the observer and verify the Desktop-owned work was not stopped.

Do not persist or output the thread ID, title, prompt, transcript, response,
reasoning, request body, tool payload, or raw envelope. Do not resolve any
approval or question. `.connOriginatedTurnsOnly` remains in force.

Finally, perform the rollback gate only if the user chooses the Rollback stage
below. A candidate tuple cannot be added to the qualified matrix until ordinary
Desktop startup is restored and recorded after rollback.

### Stage 5 — Rollback

Rollback is a separate consequential operation. Diagnose first, show:

- exact service label and resolved launchd domain;
- exact setup-owned plist and backup path;
- named GUI environment key;
- exact `bootout`, `unsetenv`, and file-move commands;
- that no daemon stop/restart or remote-control mutation will occur; and
- that an already-running Desktop process will retain its selected transport
  until the user separately quits and relaunches it.

Ask exactly one clear question for Rollback Confirmation. Stop and wait.

After explicit confirmation only:

1. Run the resolved equivalent of:

   ```sh
   /bin/launchctl bootout \
     "gui/$(id -u)/com.conn.experimental-shared-desktop"
   ```

   Treat a not-found service as already unloaded.
2. Run:

   ```sh
   /bin/launchctl unsetenv CODEX_APP_SERVER_USE_LOCAL_DAEMON
   ```

3. Remove only the exact setup-owned plist. Do not delete a file with uncertain
   provenance and do not touch other LaunchAgents.
4. Leave the Codex-managed daemon running. Leave externally configured remote
   control unchanged.
5. Re-run read-only diagnosis.
6. Ask separately whether the user wants to quit/relaunch Desktop normally.
   Never do it yourself.
7. After the user relaunches, verify the GUI flag is absent and Desktop's
   ordinary private App Server child is restored.

Rollback is incomplete if the plist is removed but the GUI flag remains, or if
the flag is unset while the old Desktop process is still running. Report
`Rollback verified` only after ordinary Desktop startup is observed.

### Final report

Report:

- exact contract and version tuple;
- final diagnostic state;
- which confirmation points the user approved;
- exact setup-owned files and launchd state changed;
- content-free verification-gate results;
- whether rollback was attempted and verified;
- any bounded failure reason or remaining user action; and
- that Managed Daemon Mode remains available.

Never claim live proof that was host-blocked, user-declined, inferred from old
evidence, or not observed in this run.

---

End of copyable prompt.
