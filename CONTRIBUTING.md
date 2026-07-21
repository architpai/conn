# Contributing to Conn

Thanks for helping improve Conn. Conn is an early-stage macOS companion for
supervising Codex work, so focused bug fixes, tests, documentation, and small
product improvements are especially welcome.

## Before you start

- Search the existing issues before opening a new one.
- Use a feature request to discuss substantial behavior or architecture changes
  before investing in an implementation.
- Keep changes focused. Avoid combining unrelated refactors with a bug fix or
  feature.
- Do not include credentials, private transcripts, personal paths, or other
  sensitive Codex data in issues, fixtures, logs, screenshots, or commits.

For security vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of
opening a public issue.

## Development setup

Conn requires macOS 15 or later and a Swift 6 toolchain. Follow
[INSTALL.md](INSTALL.md) for the current prerequisites and build instructions.

Build the app and run the executable test harnesses from the repository root:

```sh
swift build
swift run conn-domain-tests
swift run conn-app-core-tests
swift run conn-app-server-adapter-tests
./scripts/test-inspect-release.sh
```

If your change affects the website, also run:

```sh
pnpm install
pnpm web:lint
pnpm web:build
```

Some release checks require macOS tools such as `codesign`, `hdiutil`, and
Finder. A passing local ad-hoc build is not evidence that an artifact is signed,
notarized, or ready for public distribution.

## Pull requests

1. Create a branch from the latest `main`.
2. Add or update tests for behavior changes.
3. Run the relevant validation commands above.
4. Update documentation when installation, compatibility, or user-visible
   behavior changes.
5. Complete the pull request template, including any validation that could not
   be performed locally.

UI and interaction changes should include screenshots or a short recording and
must be exercised in the running macOS app. Automated tests complement visual
verification but do not replace it.

## Architecture and safety boundaries

Conn is a client of Codex's App Server integration. Codex retains ownership of
threads, turns, subprocesses, and permission requests. Contributions must not:

- claim visibility or control that the active App Server connection cannot
  prove;
- scrape transcripts or use private Desktop IPC as a fallback;
- silently enable remote control or modify another application's signed bundle;
- persist raw prompts, transcripts, tool payloads, credentials, or approval
  contents beyond an explicitly documented product need; or
- present an experimental integration as a supported OpenAI contract.

Version compatibility changes must be backed by generated protocol artifacts,
tests, and an explicit review of the supported-version boundary.

## License

By submitting a contribution, you agree that your contribution is provided
under the [Apache License 2.0](LICENSE). You represent that you have the right to
submit it under those terms. Preserve applicable copyright, license, and
attribution notices for third-party material.
