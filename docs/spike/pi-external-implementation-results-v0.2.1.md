# External Pi Integration v0.2.1 — Implementation Results

Date: 2026-07-29

## Verdict

Conn now has an end-to-end external Pi Integration using Pi's supported global
extension mechanism. Conn does not launch, own, restart, or stop Pi. An
ordinary independently launched Pi TUI can register with Conn, project bounded
Session state, accept a follow-up while idle, accept steering while busy, and
be interrupted while busy.

The implementation is intentionally not described as total Codex parity:

- external Session monitoring, follow-up, busy steering, and interrupt are
  implemented;
- current-model display is implemented, but the catalog remains
  current-model-only until authenticated alternatives can be qualified;
- structured questions and one-time approval mediation are implemented as
  explicit default-off features;
- exact Pi terminal-window activation is unavailable;
- Conn-created Pi Sessions and ad-hoc chats are unavailable.

## Setup and lifecycle

- Enablement is explicit in Conn Settings.
- Conn qualifies the actual Node executable and resolved Pi package entry with
  a bounded, non-mutating version probe.
- v0.2.1 supports Pi Coding Agent 0.82.1 exactly.
- Finder-safe discovery checks the login shell and known Node layouts,
  including NVM, without trusting Conn's inherited `PATH`.
- Conn installs only
  `~/.pi/agent/extensions/conn/{index.ts,behavior.json,.conn-install.json}`.
- Conn does not edit Pi settings, package lists, project files, provider
  credentials, or existing Sessions.
- Install and update are staged and verified. Foreign, symlinked, or changed
  targets fail closed. Uninstall moves the exact owned extension to Trash.
- The packaged Conn app includes the production extension resource, and the
  release inspector rejects an app that omits it.

## Broker and protocol

- Conn owns a private `0700` runtime/socket directory, a `0600` Unix socket,
  and a leased `0600` descriptor.
- Registration requires the current protocol generation, a bounded secret,
  the same peer user ID, extension 0.2.1, and actual runtime Pi 0.82.1.
- The wire protocol is closed and typed. It has no arbitrary method or command
  escape hatch.
- Control commands are correlated once. Timeout or connection loss becomes
  acknowledgement-uncertain and is never replayed.
- A disconnected bridge invalidates current attention authority and the
  Integration generation.

## Monitoring and controls

The extension emits bounded lifecycle, model, thinking, message, and tool
evidence. Conn maps it into the provider-neutral Integration projection while
retaining bounded Activity history across state changes.

Implemented controls:

- idle follow-up with explicit `deliverAs: "followUp"`;
- busy follow-up with the same explicit delivery mode;
- busy steering with explicit `deliverAs: "steer"`;
- interrupt through the active Pi context's supported `abort()`;
- exact structured-question answers; and
- exact one-time approve or deny decisions.

Approval mediation is a Conn policy, not a sandbox. It is default-off. When
enabled, the read-only `read`, `ls`, `find`, and `grep` names pass through;
write, edit, bash, and unknown tools require a live one-time decision. Broker
loss denies rather than guessing. No raw tool arguments or shell command are
sent to Conn.

Disabling structured questions makes an already-registered question tool
inert immediately. `/reload` is still required to remove that tool from an
already-open Pi TUI because Pi 0.82.1 has no supported unregister operation.

## Live production proof

The production bundled extension was installed into an isolated Pi agent
directory and auto-discovered by an ordinary external Pi TUI without an
extension flag. The correlated probe observed:

```text
LIVE_PROBE_READY
IDLE_FOLLOWUP_accepted
BUSY_PROMPT_accepted
STEER_accepted
INTERRUPT_PROMPT_accepted
INTERRUPT_accepted
PRODUCTION_PI_E2E_PASS
```

Pi produced the exact idle response, accepted a steer while its tool was
running, produced the exact steered response, and aborted a running
20-second command. After runtime-version hardening, a second isolated launch
again auto-loaded `conn`, qualified the actual Pi 0.82.1 package, registered,
and accepted the first external follow-up. That second isolated agent had no
provider credentials, so it was used only to re-prove the hardened
registration path.

All temporary agent, workspace, and runtime directories were moved to Trash.

## Regression evidence

Validated after implementation:

- Swift build;
- ConnDomain: 76 assertions;
- ConnAppCore: 243 assertions;
- ConnCodexAdapter: 1,470 assertions;
- ConnPiAdapter: 58 assertions;
- ConnUI: 250 assertions;
- Pi extension TypeScript type-check;
- Pi extension Node tests: 5 passing;
- provider, Domain, Codex adapter, Pi adapter, and UI boundary scripts;
- committed Codex App Server schemas for 0.144.5 and 0.144.6;
- ad-hoc-signed packaged Conn app;
- packaged resource presence and strict code-sign verification;
- release inspection and its DMG/app fixture suite; and
- `git diff --check`.

CodeRabbit CLI was not installed on this machine, so the final security pass
was performed locally. It found and corrected release-resource omission,
SIGPIPE exposure, disconnected approval pass-through, stale question feature
routing, runtime Pi-version impersonation, Activity replacement, and
configuration-tamper ownership gaps before this result was recorded.
