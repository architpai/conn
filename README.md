# Conn

![Conn — a notch-native supervision surface for AI harnesses](.github/assets/conn-banner.png)

[Visit the Conn website](https://conn-umber.vercel.app/) · [Download the latest release](https://github.com/architpai/conn/releases/latest)

Conn is a native macOS notch companion for supervising AI harness Sessions
while you work in other apps. It shows connected activity, surfaces supported
permission and question requests, and lets you steer, follow up, or interrupt
a Run without taking ownership of the harness process.

> [!IMPORTANT]
> Conn 0.2.0 remains an alpha preview for Apple Silicon Macs running macOS 15
> or later. Codex is the only supported harness in v0.2, using CLI/App Server
> versions `0.144.5` and `0.144.6` exactly. Shared Desktop Mode remains
> experimental and off by default.

Conn is an independent open-source project and is not an official OpenAI
product.

## What Conn does

- Keeps the Sessions in the current active and 24-hour view visible in a compact
  top-center surface, with status counts scoped to exactly that visible set.
- Expands into a focused workspace with harness attribution, Session switching,
  chronological activity, grouped Runs, full completion summaries, and elapsed
  work time.
- Supports capability-gated approval, question, follow-up, steer, and stop
  actions through Codex App Server.
- Starts a New Session as a local draft in the default Workspace, with one
  compact model-and-reasoning control; Codex creates the real Session only when
  the first message is sent.
- Rehydrates state after reconnecting without taking ownership of Codex Sessions
  or their lifecycle.
- Offers an optional Labs flow for qualifying Codex Desktop and Conn as clients
  of the same managed daemon.

## Requirements

- Apple Silicon Mac. Intel builds have not been validated yet.
- macOS 15.0 or later.
- Codex installed, authenticated, and exposing CLI/App Server version `0.144.5`
  or `0.144.6`.
- Swift 6 and the Xcode Command Line Tools only when building from source.

## Install

Download the latest macOS archive from
[GitHub Releases](https://github.com/architpai/conn/releases/latest), verify the
included checksum, open the DMG, and drag Conn into Applications.

The current alpha build is ad-hoc signed. macOS will therefore require an
explicit Control-click **Open** on first launch, and **Launch Conn at login**
cannot be registered by this artifact. Developer ID signing and notarization
are planned before Conn leaves alpha. See
[INSTALL.md](INSTALL.md) for the exact binary and source installation paths,
Gatekeeper steps, supported versions, verification commands, and uninstall
instructions.

## Five-minute judge test

1. Confirm an authenticated Codex `0.144.5` or `0.144.6` standalone CLI is
   installed.
2. Install and open Conn using [INSTALL.md](INSTALL.md).
3. Leave **Shared Desktop Mode** off; Managed Daemon Mode is the default.
4. Start or resume a harmless Codex Session through the managed daemon.
5. Confirm the Session appears in Conn, expand it, and inspect its activity.
6. Open **New Session**, confirm the draft uses the default Workspace, choose a
   model and reasoning effort, and verify that no Session appears until the
   first message is sent.
7. Send a benign follow-up, then confirm the Run continues if Conn is closed and
   reopened.

Conn fails closed when the App Server version is unsupported. Some approval and
question controls only appear when the connected Codex host emits the matching
request and grants Conn authority to answer it.

## Architecture

Conn is a Swift 6 menu-bar/accessory application. Its normal integration path
is:

```text
Conn.app -> codex app-server proxy --sock -> Codex-managed App Server daemon
```

The proxy is a disposable transport helper. Codex owns the daemon, threads, and
turns; quitting Conn only disconnects its client. Conn uses structured App
Server messages and does not scrape transcript files or install hooks.

The provider-neutral implementation is split into:

- `ConnDomain` for Harness, Integration, Session, Run, Activity, Attention, and
  action semantics.
- `ConnAppCore` for Integration aggregation, persistence, presentation, and
  policy.
- `ConnCodexAdapter` for the version-gated Codex App Server implementation.
- `ConnUI` for the provider-neutral AppKit and SwiftUI notch surface.
- `ConnApp` for Codex-only composition and migration controls in v0.2.

Read the [architecture decisions](docs/adr),
[domain model](docs/architecture/domain-model.md), and
[operations guide](docs/managed-daemon-operations.md) for the deeper contracts.

## Privacy and safety

Conn reads structured thread, turn, item, request, and status data needed for
the visible supervision surface. It opts out of raw reasoning deltas, does not
poll transcript files, and does not enable daemon remote control. Consequential
actions are bound to the exact connection, thread, turn, and request identity.

Shared Desktop Mode uses an internal Codex Desktop switch that may change in a
future release. Its setup is explicit, reversible, current-user-only, and
documented in [docs/shared-desktop-mode.md](docs/shared-desktop-mode.md).

## Building and testing

```sh
git clone https://github.com/architpai/conn.git
cd conn
./scripts/build-app.sh

swift run conn-codex-adapter-tests
swift run conn-domain-tests
swift run conn-app-core-tests
swift run conn-ui-tests
./scripts/test-inspect-release.sh
```

The built application is written to `.build/conn-app/Conn.app`. See
[INSTALL.md](INSTALL.md) for installation and [CONTRIBUTING.md](CONTRIBUTING.md)
for the full development workflow.

## Built with Codex and GPT-5.6

Conn was created during OpenAI Build Week, from July 18–21, 2026. GPT-5.6 in
Codex accelerated protocol research, Swift implementation, test generation,
privacy hardening, release tooling, code review, and computer-driven UI
verification.

The human-led decisions remained central: choosing the notch supervision
problem, defining the interaction design, pivoting from a hook-based prototype
to the managed App Server architecture, keeping Codex as the lifecycle owner,
setting the privacy boundary, and accepting or rejecting each implementation
and design tradeoff. The project was developed in phased Codex tasks with
explicit plans, ADRs, deterministic tests, adversarial review, and live app
checks.

## Project status and roadmap

Version 0.2.0 is a continued alpha. It introduces an internal provider-neutral
Integration API while shipping only the real Codex Integration; Claude Code,
Pi, OpenCode, and other harnesses are not supported yet. Near-term priorities
remain Developer ID signing and notarization, broader adapter qualification,
universal macOS builds, and UI refinement through daily use.
See [CHANGELOG.md](CHANGELOG.md) for release history.

## Contributing and security

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md). Please
report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Conn is licensed under the [Apache License 2.0](LICENSE). Third-party inspiration
and generated protocol-schema provenance are recorded in
[ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
