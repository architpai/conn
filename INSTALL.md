# Install Conn

## Supported platform

Conn 0.1.1 supports Apple Silicon Macs on macOS 15.0 or later. It requires an
authenticated Codex CLI/App Server version `0.144.5` or `0.144.6`; other
versions fail closed instead of guessing at protocol compatibility.

Check the standalone Codex version before installing:

```sh
"$HOME/.codex/packages/standalone/current/codex" --version
```

The expected output is `codex-cli 0.144.5` or `codex-cli 0.144.6`.

## Install the release build

1. Download `Conn-0.1.1-macos-arm64.zip` and its `.sha256` file from the
   [latest GitHub release](https://github.com/architpai/conn/releases/latest).
2. In Terminal, change to the download directory and verify the archive:

   ```sh
   shasum -a 256 -c Conn-0.1.1-macos-arm64.zip.sha256
   ditto -x -k Conn-0.1.1-macos-arm64.zip Conn-0.1.1
   cd Conn-0.1.1
   shasum -a 256 -c Conn-0.1.1-adhoc.dmg.sha256
   ```

3. Open `Conn-0.1.1-adhoc.dmg` and drag **Conn** into **Applications**.
4. Because this alpha is ad-hoc signed and not notarized, open it the first time
   by Control-clicking `/Applications/Conn.app`, choosing **Open**, and then
   choosing **Open** again. If macOS still blocks it, open **System Settings →
   Privacy & Security** and use **Open Anyway** for Conn.
5. Conn appears at the top center of the display. Managed Daemon Mode is ready
   without a plugin or hook installation.

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
signature locally and verifies the bundle before returning success.

To install from Terminal instead of Finder:

```sh
ditto .build/conn-app/Conn.app /Applications/Conn.app
open /Applications/Conn.app
```

## Verify a source build

```sh
swift run conn-app-server-adapter-tests
swift run conn-domain-tests
swift run conn-app-core-tests
./scripts/test-inspect-release.sh
./scripts/inspect-release.sh --app "$PWD/.build/conn-app/Conn.app"
```

The three Swift executables are deterministic test suites. The release
inspection checks that retired plugin, hook, relay, and probe payloads are not
present in the built application.

## Troubleshooting

- **App Server version incompatible:** install or select Codex `0.144.5` or
  `0.144.6`. Conn 0.1.1 deliberately rejects newer or unknown versions.
- **No threads are visible:** Managed Daemon Mode only shows threads connected
  through the Codex-managed daemon. It does not claim every local Desktop, CLI,
  IDE, cloud, or web thread.
- **Conn is stale:** restore the managed-daemon connection and use **Sync**.
- **Shared Desktop setup is unavailable:** leave the Labs feature off; it is not
  required for normal operation.

More detail is available in [docs/managed-daemon-operations.md](docs/managed-daemon-operations.md).

## Uninstall

Quit Conn and move `/Applications/Conn.app` to the Trash. This disconnects Conn
without stopping the Codex-managed daemon or deleting Codex threads.

To remove Conn's disposable local state as well, first confirm Conn is not
running, then remove only `~/Library/Application Support/Conn`. Do not remove
the broader Application Support directory.
