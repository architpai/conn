# Claude Code Agent View v0.2.1 capability spike

Status: complete

Date: 2026-07-29

## Question

Can Conn supervise and safely control Claude Code through the zero-setup
Agent View surface, using `claude agents --json` as the authoritative parse and
the documented Agent View state directory only as a refresh signal?

This spike is a feasibility gate. It does not add a Claude adapter or change
Claude settings.

## Safety boundary

- Used Claude Code 2.1.220 from the installed native launcher.
- Created only uniquely named throwaway background sessions in a temporary git
  workspace.
- Used synthetic prompts, Haiku, low effort, and either no tools or a bounded
  `sleep` command.
- Used one user-provided interactive session for explicit follow-up and
  concurrent-resume testing.
- Did not edit Claude settings, install hooks, register MCP servers, inspect
  transcript content, or mutate pre-existing background jobs.
- Removed all four throwaway Agent View jobs and the temporary workspace after
  the spike.

## Environment evidence

The executable was absent from a Finder-like inherited `PATH`, while a login
shell resolved the stable launcher at `~/.local/bin/claude`. Two Claude
processes were already running from the launcher and its versioned native
binary.

Invoking the resolved launcher directly with `PATH=/usr/bin:/bin` succeeded for
both `--version` and `agents --json`. Conn therefore needs one-time executable
discovery, validation, and caching, but no recurring login-shell invocation.

With a fresh `CLAUDE_CONFIG_DIR`, `agents --json --all` returned `[]` with exit
status 0. With `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`, it returned a specific
disabled diagnostic with exit status 1. One warm authoritative inventory call
completed in approximately 0.26 seconds on this host.

The installed CLI and official Agent View documentation identify:

- `claude agents --json` for active machine-readable inventory;
- `--all` for completed background inventory;
- `~/.claude/daemon/roster.json` for supervisor recovery state; and
- `~/.claude/jobs/<id>/state.json` for per-job Agent View state.

Agent View remains a research preview. Conn must qualify CLI versions and
strictly validate JSON rather than treat the current schema as permanently
stable.

## Observed inventory shapes

Background rows contained both:

- a short Agent View job ID;
- a full Claude session ID;
- `kind: background`;
- a job `state`; and
- a process `status` that could be absent or temporarily disagree with state.

Interactive rows contained:

- no short Agent View job ID;
- a full Claude session ID;
- `kind: interactive`; and
- `status`, without background job `state`.

During a completed background turn, the row temporarily reported
`state: done` with `status: busy`. After respawn it temporarily reported
`state: working` with `status: idle`. These fields are distinct evidence and
must not be collapsed through a simple `state ?? status` rule.

During concurrent resume of one interactive session, Agent View temporarily
returned two rows with the same full session ID and different presentation
metadata. The full session ID must be the deduplication identity within the
Claude Integration.

## Capability results

| Capability | Result | Evidence and boundary |
| --- | --- | --- |
| Discover active background sessions | Confirmed | `agents --json` returned qualified background rows. |
| Discover completed background sessions | Confirmed | `agents --json --all` returned completed, failed, blocked, and stopped rows. |
| Discover interactive sessions | Version-qualified | Claude 2.1.220 returned user-started interactive rows, despite public Agent View documentation warning that ordinary interactive sessions may remain invisible until backgrounded. Do not make universal coverage a product claim. |
| Zero additional authentication | Confirmed for an already authenticated install | Inventory and throwaway creation reused the installed Claude authentication. Conn did not handle credentials. |
| Empty installation state | Confirmed | A fresh config root returned an empty inventory rather than an error. |
| Managed Agent View disablement | Confirmed | The CLI returned a distinct nonzero disabled result. |
| Create an ad-hoc background Session | Confirmed | `claude --bg` returned a short job ID immediately; the same job then appeared with its full session ID in authoritative inventory. |
| Choose model at creation | Confirmed | A Haiku background Session launched and showed Haiku in its Claude runtime. Agent View JSON did not expose model identity. |
| Choose effort at creation | Command accepted | Low effort was accepted at launch, but Agent View JSON did not expose effort. Conn may remember its own request but cannot claim the effective value for external Sessions. |
| Read model for an external Session | Unsupported by tested inventory | Neither interactive nor background Agent View JSON exposed the active model. |
| Idle interactive follow-up | Confirmed but conditional | `claude --resume <full-id> --print` completed on the same full session ID. It starts a second process and is safe only with exclusive idle authority. |
| Busy interactive steer | Unsafe | Two concurrent resume processes were accepted, both completed, and wrote to the same session. Agent View emitted duplicate rows. This is transcript interleaving, not a steer primitive. |
| Background follow-up | Unsupported | Non-interactive resume was rejected even when the job reported done/idle because Agent View still owned it. |
| `--resume ... --bg` background follow-up | Not a follow-up | It created a new background job and a new full session ID. Treat only as a new or forked Session. |
| Reply to a blocked background Session | Unsupported by tested shell surface | Agent View TUI can reply, but no public non-interactive `send` or `reply` command was exposed. Conn must not automate the TUI or write private job files. |
| Stop a working background Session | Confirmed | `claude stop <short-id>` changed the same row from working/busy to stopped. |
| Respawn a stopped background Session | Confirmed | `claude respawn <short-id>` retained identity and returned the job to working before a second stop. |
| Read recent background output | Confirmed but not selected for ingestion | `claude logs <short-id>` worked, but output is terminal-oriented, includes private content, and is not required for the zero-content monitoring MVP. |
| Remove a background Session | Confirmed on spike-owned jobs | `claude rm <short-id>` removed each exact throwaway job. Conn must not expose deletion without a separate consequential-action design. |
| Change an existing Session model | Unsupported | Resumed Sessions preserve their saved model; interactive `/model` is not a non-interactive control surface. |

## Compatibility finding: user hooks

The throwaway background Sessions inherited existing Claude customization. A
configured lifecycle hook referenced `node`, but the supervisor environment
could not resolve it. Claude reported the hook failures as non-blocking and the
synthetic turns completed.

This does not require Conn to manage hooks. It demonstrates that background
Agent View execution may have a different executable environment from a login
terminal. Conn should surface Claude's own launch failure when creation fails
and must not attempt to repair unrelated user customization.

## Product boundary supported by the spike

Conn v0.2.1 can safely claim:

- zero-configuration supervision of Sessions returned by Claude Agent View;
- ad-hoc background Session creation with workspace, model, effort, name, and
  initial prompt;
- independent Claude Integration health and stale-state handling;
- stop for a currently working background job, after exact authority checks;
- open or attach handoff to Claude for richer interaction.

Conn v0.2.1 must not claim:

- visibility into every Claude Code interactive conversation;
- safe mid-run steering;
- non-interactive replies to Agent View background jobs;
- permission or question response through private Agent View state;
- current model discovery for externally created Sessions;
- arbitrary transcript or terminal-output ingestion.

Idle interactive follow-up is technically possible but should remain out of
the first production slice unless Conn can prove exclusive idle authority.
Agent View does not provide an atomic lease preventing another terminal from
resuming the same session between qualification and send.

## Recommended adapter contract

1. Resolve and validate the stable Claude launcher once; invoke it directly.
2. Treat `agents --json --all` as the authoritative snapshot.
3. Use documented `jobs/` and `daemon/roster.json` changes only to debounce an
   immediate refresh, with periodic polling as fallback.
4. Deduplicate by full session ID, never presentation row or short job ID.
5. Decode background `state` and process `status` separately.
6. Preserve last qualified inventory as stale after command or schema failure.
7. Remember requested model and effort only for Conn-originated Sessions.
8. Capability-gate stop to authoritative working background rows with an exact
   short job ID.
9. Keep follow-up, blocked replies, model changes, deletion, and respawn out of
   the first production slice.
10. Never parse or write private job-state fields as a control protocol.

## Go/no-go

**Go** for a read-mostly Claude Agent View adapter with ad-hoc background
creation and carefully gated stop.

**No-go** for Codex App Server control parity. The tested Claude surface does
not provide safe background follow-up, atomic busy steering, response
authority, or external-session model discovery.
