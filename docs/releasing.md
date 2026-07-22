# Release process

Conn's public release target is a Developer ID signed, hardened-runtime,
notarized, and stapled DMG. Never publish signing credentials or notarization
profiles in the repository.

## Run the local release gate

Run the complete app-core suite on a Mac with an interactive login session;
it exercises macOS workspace and session behavior that hosted CI cannot model.

```sh
swift run conn-app-server-adapter-tests
swift run conn-domain-tests
swift run conn-app-core-tests
./scripts/test-inspect-release.sh
pnpm install --frozen-lockfile
pnpm web:build
pnpm web:lint
```

## Build and sign the app

```sh
./scripts/build-app.sh
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: NAME (TEAMID)" \
  .build/conn-app/Conn.app
codesign --verify --deep --strict --verbose=2 .build/conn-app/Conn.app
./scripts/package-dmg.sh --app "$PWD/.build/conn-app/Conn.app"
```

## Sign, notarize, and staple the DMG

```sh
codesign --force --timestamp \
  --sign "Developer ID Application: NAME (TEAMID)" \
  dist/Conn-0.1.1.dmg
xcrun notarytool submit dist/Conn-0.1.1.dmg \
  --keychain-profile CONN_NOTARY --wait
xcrun stapler staple dist/Conn-0.1.1.dmg
xcrun stapler validate dist/Conn-0.1.1.dmg
spctl --assess --type open --context context:primary-signature \
  --verbose=4 dist/Conn-0.1.1.dmg
./scripts/inspect-release.sh --dmg "$PWD/dist/Conn-0.1.1.dmg"
```

Signing and stapling change the DMG bytes, so generate the checksum only after
those operations:

```sh
(cd dist && shasum -a 256 Conn-0.1.1.dmg > Conn-0.1.1.dmg.sha256)
```

The alpha artifacts use the explicit `--ad-hoc` packaging path because the
build machine has no Developer ID identity. They must be labeled as unnotarized
everywhere they are distributed.
