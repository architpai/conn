# Conn Shared Desktop Mode

Setup contract: **v2**

Contract date: **2026-07-21**

Status: **Labs / Experimental / Off by default**

Shared Desktop Mode attempts to make Codex Desktop and Conn clients of the
same Codex-managed App Server daemon. It is an optional widening of Managed
Daemon Mode, not a requirement for Conn and not a claim that Conn can see all
local Codex work.

The Desktop launch switch used by this setup,
`CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`, exists in the tested installed Desktop
builds but is an internal implementation switch, not a supported public Codex
configuration contract. An update may remove or change it. If qualification
fails, Shared Desktop Mode stays unavailable while Managed Daemon Mode remains
usable.

## Supported and evidence status

Support is an exact reviewed matrix, not a semantic-version range.

| Component | Version | Phase 10 status |
| --- | --- | --- |
| Codex Desktop | `26.715.31251` build `5538` | Phase 5 transport-compatible; not qualified for the Phase 10 v2 setup contract |
| Desktop-bundled Codex CLI | `0.145.0-alpha.18` | Qualified with Desktop build `5538` |
| Managed App Server | `0.144.5`, then `0.144.6` | Both selected by the historical Desktop build; neither inherits v2 lifecycle or rollback proof |
| Codex Desktop | `26.715.31925` build `5551` | Candidate only; the internal switch is present, but Phase 10 same-daemon live proof is still required |
| Desktop-bundled Codex CLI | `0.145.0-alpha.18` | Candidate only when paired with Desktop build `5551` |
| Managed App Server | `0.144.6` | Conn-supported, but not sufficient to qualify candidate Desktop build `5551` |

The presence of the switch, a compatible daemon version, or an old successful
test does not qualify a new Desktop build. Adding a tuple requires a controlled
same-daemon test and an updated version of this matrix.

## Safety and privacy boundary

The setup and its agent must never:

- quit, kill, or relaunch Codex Desktop without a separate explicit user
  decision;
- modify the signed `/Applications/ChatGPT.app` bundle;
- open or connect to `$CODEX_HOME/ipc/ipc.sock`, `$HOME/.codex/ipc/ipc.sock`,
  or any other private Desktop IPC;
- enable or disable daemon remote control;
- stop or restart the Codex-managed daemon;
- use `defaults` or set a machine-wide or global login environment;
- dump process environments, Codex configuration, tokens, prompts,
  transcripts, raw reasoning, tool payloads, or request/response bodies;
- start, steer, interrupt, approve, or answer a turn as part of setup or
  verification; or
- widen response authority merely because Conn can resume or select a Desktop
  thread.

Phase 10 retains the Phase 9 `.connOriginatedTurnsOnly` policy. A Desktop turn
may be observed and resumed read-only during qualification, but Conn does not
gain approval or question response authority over it.

## Exact setup effects

After the user clicks **Set up Shared Desktop**, v2 may create or update only this setup-owned current-user
state:

- `$HOME/Library/LaunchAgents/com.conn.experimental-shared-desktop.plist`;
- `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` in the current user's launchd GUI
  environment.

Before installing the LaunchAgent, the setup agent may invoke the exact,
allowlisted Codex standalone executable's locally qualified
`app-server daemon start` command when the daemon is absent, then poll
`app-server daemon version` for a bounded interval. The persistent job itself
does not invoke Codex. It only sets the one GUI launch-environment flag.

The generated v2 plist is setup-owned only when all of these structural facts
match:

- `Label` is `com.conn.experimental-shared-desktop`;
- its job-local `EnvironmentVariables` contains only the ownership marker
  `CONN_SHARED_DESKTOP_SETUP_CONTRACT=v2-2026-07-21`;
- `RunAtLoad` is true, `ProcessType` is `Background`,
  `LimitLoadToSessionType` is `Aqua`, and `KeepAlive` is absent;
- `ProgramArguments` are exactly `/bin/launchctl`, `setenv`,
  `CODEX_APP_SERVER_USE_LOCAL_DAEMON`, and `1`; and
- no shell, log path, Codex executable, daemon command, or unrelated
  environment key is present.

Those six keys are the complete v2 artifact; no additional plist keys are
allowed. This gives diagnosis one exact structural identity instead of relying
on a label or command resemblance.

The job exits after setting the flag. A later explicit setup retry may
`kickstart` the one job after showing its exact effect; `KeepAlive` must not
relaunch it forever.

The setup does not modify the application bundle, Codex configuration, shell
profiles, login items, system LaunchDaemons, or other users' state. Starting an
absent Codex-managed daemon is not reversed during Shared Desktop rollback:
Conn does not own that daemon and must not stop it.

An existing same-name LaunchAgent is never silently overwritten. Conn replaces
only its exact current contract or its recognized previous v1 contract. Any
foreign, malformed, oversized, symlinked, hard-linked, wrong-owner, or
group/world-writable file blocks setup and remains untouched. Other
LaunchAgents are out of scope.

## 1. Diagnose

Diagnosis is automatic and read-only. Resolve `$HOME`, the GUI user ID, and the
exact executable paths first. Do not substitute an arbitrary executable from
`PATH` for compatibility decisions.

The following commands are safe diagnostic primitives:

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

If the setup-owned plist exists, diagnosis may also run:

```sh
plutil -lint \
  "$HOME/Library/LaunchAgents/com.conn.experimental-shared-desktop.plist"
stat -f '%N type=%HT mode=%Sp uid=%u gid=%g' \
  "$HOME/Library/LaunchAgents/com.conn.experimental-shared-desktop.plist"
shasum -a 256 \
  "$HOME/Library/LaunchAgents/com.conn.experimental-shared-desktop.plist"
```

Process inspection is limited to PID, parent PID, executable, and arguments for
the exact Desktop process, its direct App Server child, and the managed daemon.
Do not use `ps e`, `ps eww`, or another command that prints environment values.
Only the presence or absence of the named GUI launch variable is reported.

The expected socket must be a Unix socket owned by the current user, mode
`0600`, inside an immediate parent directory owned by the current user and not
group- or world-writable. Diagnosis never creates, opens, or speaks to the
private Desktop IPC socket.

### Diagnostic states

The in-app and agent diagnostics use precise, non-overlapping states:

1. `Off` — no setup-owned artifact and no GUI launch flag.
2. `Setup artifact not loaded` — the plist exists but its launchd service does
   not.
3. `Setup failed` — the setup service exited unsuccessfully; show only a
   bounded sanitized reason.
4. `Ready for Desktop relaunch` — the daemon and GUI flag are ready, but the
   currently running Desktop process predates them.
5. `Desktop not sharing` — Desktop owns a private App Server child.
6. `Unsafe endpoint` — socket type, owner, or permissions fail validation.
7. `Version not qualified` — the exact tuple is absent from the matrix.
8. `Candidate sharing` — the flag is set, endpoint is safe, versions are
   candidates, and Desktop has no private App Server child.
9. `Awaiting Desktop proof` — process selection passed but no attested
   Desktop-originated throwaway thread has been observed.
10. `Awaiting second-client proof` — the attested thread is visible but
    read-only rejoin and live delivery are incomplete.
11. `Verified` — every verification gate below passed for the exact tuple.
12. `Rollback required` or `Rollback verified` — setup state is being removed
    or ordinary Desktop startup has been restored.

A running daemon, set flag, selected thread, persisted thread, or successful
`thread/list` response alone must never produce `Verified`.

## 2. Enable

Before mutation, the agent must show:

- the exact version tuple and whether it is qualified or candidate-only;
- the exact plist path, launchd GUI domain, and environment key;
- whether an existing file will be preserved;
- every command it proposes to run; and
- the complete rollback commands.

The agent then asks for **Confirmation A: install current-user setup state**.
Without that confirmation, it stops after diagnosis.

After Confirmation A, the agent may:

1. if the managed daemon is absent, run only the exact allowlisted standalone
   CLI's `app-server daemon start`, then poll `app-server daemon version` and
   the expected socket metadata for a bounded deadline;
2. if this exact service is already loaded, unload only this service before
   replacing its setup artifact; a not-found result is an idempotent no-op:

   ```sh
   /bin/launchctl bootout \
     "gui/$(id -u)/com.conn.experimental-shared-desktop"
   ```

3. create a temporary plist in the same LaunchAgents directory;
4. validate it with `plutil -lint`;
5. stop if the destination is mismatched or changed after diagnosis;
6. atomically place the setup-owned plist with mode `0600`;
7. load it with the fully resolved command:

   ```sh
   /bin/launchctl bootstrap \
     "gui/$(id -u)" \
     "$HOME/Library/LaunchAgents/com.conn.experimental-shared-desktop.plist"
   ```

8. if it did not run at load, start only that job without killing an existing
   instance:

   ```sh
   /bin/launchctl kickstart \
     "gui/$(id -u)/com.conn.experimental-shared-desktop"
   ```

9. poll `launchctl getenv` with a bounded deadline; and
10. report the resulting diagnostic state without touching Desktop.

The daemon is started and checked, if needed, before the setup artifact is
installed. Login ordering can still allow Desktop to launch before the flag
job runs or before the daemon is ready; that case is diagnosed as
`Ready for Desktop relaunch`, not treated as success. The job never owns daemon
lifecycle.

The agent next asks for **Confirmation B: user-authorized Desktop relaunch**.
The agent does not perform the quit or relaunch. The user completes it through
the ordinary Desktop UI, then tells the agent to continue.

## 3. Verify

Verification has four gates. Failure at any gate keeps the mode unverified and
does not affect Managed Daemon Mode.

### Gate A — compatibility and endpoint

- exact Desktop app build and bundled CLI are recorded;
- exact managed App Server version is recorded;
- the tuple is present in the qualified matrix, or explicitly marked as a
  candidate undergoing Phase 10 qualification; and
- the expected current-user Unix socket passes type, owner, and permission
  checks.

### Gate B — Desktop process selection

- the named GUI launch flag is set;
- Desktop is running after the user's authorized relaunch;
- the existing managed daemon PID survived; and
- the exact Desktop process has no private App Server child.

This establishes only `Candidate sharing`.

### Gate C — Desktop-originated thread

1. Capture a metadata-only daemon inventory baseline.
2. Ask the user to create a throwaway, non-sensitive task in Codex Desktop.
3. Observe the new candidate thread identity within a bounded window.
4. Ask the user to attest that this exact candidate is the throwaway Desktop
   task they just created.
5. Resume it from a second client without starting or steering a turn and
   without taking request ownership.

Thread titles, prompts, messages, reasoning, configuration, and tool payloads
must not be written to diagnostics or telemetry. User attestation plus the
bounded before/after identity change is required because a generic App Server
source value alone does not prove Desktop origin.

### Gate D — shared live delivery and rollback

- the user initiates harmless activity in the throwaway Desktop task;
- both subscribed clients receive correlated method-and-identity lifecycle
  evidence;
- no setup client sends an approval, answer, steer, interrupt, or follow-up;
- disconnecting the observer does not stop the Desktop turn; and
- the rollback procedure below restores ordinary Desktop startup.

Only after Gates A-D pass may the exact tuple be added to the qualified matrix
and the connection source be presented as `Shared Desktop`. Candidate build
`26.715.31925` build `5551` remains unqualified until this live proof is
recorded.

## Content-free evidence

Setup diagnostics and telemetry may contain only:

- contract version and timestamps;
- enumerated diagnostic state and bounded reason code;
- exact app, CLI, and App Server version/build strings;
- booleans for flag presence, private-child presence, daemon survival, and
  each verification gate;
- socket safety category and fixed expected-endpoint identity;
- setup artifact presence, ownership/mode validity, and hash match;
- counts and opaque in-memory correlation results needed for the controlled
  test; and
- whether rollback restored ordinary startup.

Do not emit thread IDs to telemetry. Do not retain the throwaway thread's
content or raw protocol envelopes. Local control code may hold an exact thread
or turn identity only for the current bounded verification generation.

## 4. Roll back completely

Rollback requires an explicit **Rollback Confirmation**. Before asking, show
the exact service label, file path, GUI environment key, backup destination,
and commands. Resolve the GUI user ID and paths before execution.

After confirmation:

1. unload only the setup-owned job; a not-found result is already-unloaded
   success:

   ```sh
   /bin/launchctl bootout \
     "gui/$(id -u)/com.conn.experimental-shared-desktop"
   ```

2. remove the GUI launch flag for future processes:

   ```sh
   /bin/launchctl unsetenv CODEX_APP_SERVER_USE_LOCAL_DAEMON
   ```

3. remove only the exact setup-owned plist. Do not delete a file of uncertain
   provenance and do not touch any other LaunchAgent.
4. leave the managed daemon and any externally configured remote-control state
   untouched.
5. ask the user for a separate Desktop quit/relaunch decision. The agent does
   not perform it.
6. after the user relaunches normally, verify that the GUI flag is absent and
   Desktop's ordinary private App Server child is restored.

Removing the plist without `unsetenv` is incomplete because the current GUI
launch environment may retain the flag. Unsetting the flag without relaunching
Desktop is also incomplete because an existing Desktop process keeps its
already-selected transport.

Rollback is `Verified` only after ordinary Desktop startup is observed. The
Codex-managed daemon may remain running for Managed Daemon Mode.

## Troubleshooting and stop rules

- If the candidate tuple is unknown, stop at `Version not qualified` and run a
  controlled Phase 10 qualification; do not broaden the matrix by inference.
- If the socket is unsafe, do not connect, chmod, replace, or recreate it.
- If the setup service fails, report a bounded sanitized reason and preserve
  its artifact for review; do not loop forever.
- If Desktop still has a private child after user relaunch, report `Desktop not
  sharing`; do not kill either process.
- If another current-user LaunchAgent owns the same label/path, stop and ask.
- If remote control is already enabled outside Conn, report that fact as
  outside Conn's ownership. Never change it during setup or rollback.
- If Desktop origin cannot be established without inspecting content or
  private IPC, leave the mode unverified.
- If shared live delivery or rollback fails, record `Unverified` and keep
  Managed Daemon Mode available.

The copyable bounded agent instructions are in
[`shared-desktop-agent-prompt.md`](./shared-desktop-agent-prompt.md).
