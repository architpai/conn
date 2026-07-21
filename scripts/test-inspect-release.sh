#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/conn-inspect-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

app="$test_root/Conn.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
print '#!/bin/sh' > "$app/Contents/MacOS/Conn"
print 'exit 0' >> "$app/Contents/MacOS/Conn"
chmod 0700 "$app/Contents/MacOS/Conn"
print 'license fixture' > "$app/Contents/Resources/LICENSE"
print 'notice fixture' > "$app/Contents/Resources/NOTICE"
print 'acknowledgements fixture' > "$app/Contents/Resources/ACKNOWLEDGEMENTS.md"

"$script_dir/inspect-release.sh" --app "$app" >/dev/null

mv "$app/Contents/Resources/NOTICE" "$app/Contents/Resources/NOTICE.missing"
if "$script_dir/inspect-release.sh" --app "$app" >/dev/null 2>&1; then
  print -u2 "inspect-release accepted an app without its NOTICE"
  exit 1
fi
mv "$app/Contents/Resources/NOTICE.missing" "$app/Contents/Resources/NOTICE"

print '{}' > "$app/Contents/Resources/hooks.json"
if "$script_dir/inspect-release.sh" --app "$app" >/dev/null 2>&1; then
  print -u2 "inspect-release accepted an app-bundled hooks.json"
  exit 1
fi
rm "$app/Contents/Resources/hooks.json"

volume="$test_root/volume"
mkdir "$volume"
ditto "$app" "$volume/Conn.app"
ln -s /Applications "$volume/Applications"
mkdir "$volume/.background"
print 'installer background fixture' > "$volume/.background/installer.png"
valid_dmg="$test_root/Conn-valid-test.dmg"
hdiutil create -quiet -volname "Conn Valid Inspect Test" -srcfolder "$volume" -ov -format UDZO "$valid_dmg"
"$script_dir/inspect-release.sh" --dmg "$valid_dmg" >/dev/null

print 'retired plugin payload' > "$volume/sidequest-plugin.zip"
dmg="$test_root/Conn-test.dmg"
hdiutil create -quiet -volname "Conn Inspect Test" -srcfolder "$volume" -ov -format UDZO "$dmg"
if "$script_dir/inspect-release.sh" --dmg "$dmg" >/dev/null 2>&1; then
  print -u2 "inspect-release accepted an unexpected top-level DMG payload"
  exit 1
fi

rm "$volume/sidequest-plugin.zip" "$volume/Applications"
ln -s /tmp "$volume/Applications"
bad_shortcut_dmg="$test_root/Conn-bad-shortcut-test.dmg"
hdiutil create -quiet -volname "Conn Bad Shortcut Test" -srcfolder "$volume" -ov -format UDZO "$bad_shortcut_dmg"
if "$script_dir/inspect-release.sh" --dmg "$bad_shortcut_dmg" >/dev/null 2>&1; then
  print -u2 "inspect-release accepted an Applications shortcut with the wrong target"
  exit 1
fi

print "PASS: release inspection accepts the install shortcut and rejects unsafe DMG payloads"
