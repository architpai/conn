# Install Conn

## Supported platform

Conn 0.2.1 Alpha supports Apple Silicon Macs on macOS 15.0 or later. It
qualifies two independent Integrations:

- Codex CLI/App Server `0.144.5` or `0.144.6`.
- Pi Coding Agent `0.83.0`, with the Node runtime that provides `pi`.

Other versions fail closed instead of guessing at protocol compatibility.
Check the harnesses you intend to enable:

```sh
"$HOME/.codex/packages/standalone/current/codex" --version
pi --version
```

The expected outputs are `codex-cli 0.144.5` or `codex-cli 0.144.6`, and
`0.83.0` for Pi. You only need one qualified harness to use Conn.

## Install the release build

1. Download `Conn-0.2.1-macos-arm64.zip` and its `.sha256` file from the
   [latest GitHub release](https://github.com/architpai/conn/releases/latest).
2. In Terminal, change to the download directory and verify the archive:

   ```sh
   shasum -a 256 -c Conn-0.2.1-macos-arm64.zip.sha256
   ditto -x -k Conn-0.2.1-macos-arm64.zip Conn-0.2.1
   cd Conn-0.2.1
   shasum -a 256 -c Conn-0.2.1-adhoc.dmg.sha256
   ```

3. Open `Conn-0.2.1-adhoc.dmg` and drag **Conn** into **Applications**.
4. Because this alpha is ad-hoc signed and not notarized, open it the first time
   by Control-clicking `/Applications/Conn.app`, choosing **Open**, and then
   choosing **Open** again. If macOS still blocks it, open **System Settings →
   Privacy & Security** and use **Open Anyway** for Conn.
5. Conn appears at the top center of the display. Open Settings and enable
   Codex, Pi, or both. Both Integrations are off by default.

Codex monitoring needs no plugin or hook. Enabling Pi asks for confirmation,
qualifies Pi and Node, and installs Conn's standard global extension at
`~/.pi/agent/extensions/conn`. Run `/reload` once in Pi TUIs that were already
open. Disabling Pi leaves its TUIs running; **Uninstall extension** moves only
Conn's owned extension to Trash.

The ad-hoc alpha cannot register **Launch Conn at login** with macOS. That
setting remains visibly unavailable until Conn is signed with a Developer ID
identity; launch-at-login support is part of the signed distribution path
planned before Conn leaves alpha.

Do not enable Shared Desktop Mode for the basic test path. It is an optional
Labs feature with a separate qualification and rollback guide in
`docs/shared-desktop-mode.md`.

## Build and install from source

Install Xcode Command Line Tools and Swift 6, then run:

```sh
git clone https://github.com/architpai/conn.git
cd conn
./scripts/build-app.sh
open .build/conn-app
```

Drag `Conn.app` from the Finder window into `/Applications`, then use the same
Control-click **Open** flow described above. The build script creates an ad-hoc
signature locally and verifies the bundle before returning success. As with the
downloadable alpha, an ad-hoc source build cannot register Launch Conn at login.

To install from Terminal instead of Finder:

```sh
ditto .build/conn-app/Conn.app /Applications/Conn.app
open /Applications/Conn.app
```

## Verify a source build

```sh
swift run conn-codex-adapter-tests
swift run conn-pi-adapter-tests
swift run conn-domain-tests
swift run conn-app-core-tests
swift run conn-ui-tests
pnpm pi:typecheck
pnpm --filter @conn/pi-extension test
./scripts/test-inspect-release.sh
./scripts/inspect-release.sh --app "$PWD/.build/conn-app/Conn.app"
```

The three Swift executables are deterministic test suites. The release
inspection checks that retired plugin, hook, relay, and probe payloads are not
present in the built application.

## Troubleshooting

- **App Server version incompatible:** install or select Codex `0.144.5` or
  `0.144.6`. Conn 0.2.1 deliberately rejects newer or unknown versions.
- **Pi version incompatible:** install Pi `0.83.0`, then use **Diagnose** in
  Settings. Conn preserves unknown or foreign extension installations.
- **An already-open Pi TUI is missing:** run `/reload` once so Pi loads Conn's
  newly installed extension.
- **No Sessions are visible:** confirm the intended Integration is enabled.
  Managed Daemon Mode shows only qualified Codex Sessions; Pi shows only
  independently launched TUIs that loaded Conn's extension.
- **Conn is stale:** restore the managed-daemon connection and use **Sync**.
- **Shared Desktop setup is unavailable:** leave the Labs feature off; it is not
  required for normal operation.

More detail is available in [docs/managed-daemon-operations.md](docs/managed-daemon-operations.md).

## Uninstall

If Pi was enabled, first use **Settings → Pi Agent → Uninstall extension** to
move Conn's owned extension to Trash. Then quit Conn and move
`/Applications/Conn.app` to the Trash. This disconnects Conn without stopping
the Codex-managed daemon, stopping Pi TUIs, or deleting harness Sessions.

To remove Conn's disposable local state as well, first confirm Conn is not
running, then remove only `~/Library/Application Support/Conn`. Do not remove
the broader Application Support directory.
