#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
expected_bundle_identifier="dev.sidequest.app"
dmg_background_svg="$script_dir/assets/dmg-background.svg"
app_bundle=""
output_dir="$repo_root/dist"
ad_hoc=false

usage() {
  cat <<'EOF'
Usage: ./scripts/package-dmg.sh --app /absolute/path/to/Conn.app [--output DIRECTORY] [--ad-hoc]

Create a Conn macOS drag-and-drop release. The app bundle is required
explicitly so this script cannot accidentally distribute the Phase 0 packaging
probe. By default the supplied app must already have a strict-valid signature.
--ad-hoc signs a copied staging app only for local smoke tests; it is not a
notarized or publicly distributable release.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || { print -u2 "--app needs a path"; exit 2; }
      app_bundle="${2:A}"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || { print -u2 "--output needs a directory"; exit 2; }
      output_dir="${2:A}"
      shift 2
      ;;
    --ad-hoc)
      ad_hoc=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$app_bundle" && -d "$app_bundle" && "${app_bundle:e}" == "app" ]] || {
  print -u2 "A real .app bundle is required via --app; no DMG was created."
  exit 2
}
[[ ! -L "$app_bundle" ]] || { print -u2 "Refusing a symlinked app bundle: $app_bundle"; exit 1; }
[[ "${app_bundle:t}" != "ConnPackagingProbe.app" ]] || {
  print -u2 "The Phase 0 packaging probe is not a distributable Conn app."
  exit 1
}
[[ -f "$dmg_background_svg" && ! -L "$dmg_background_svg" ]] || {
  print -u2 "Missing regular DMG background artwork: $dmg_background_svg"
  exit 1
}
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/conn-dmg.XXXXXX")"
mounted_device=""
mount_root=""
cleanup() {
  if [[ -n "$mounted_device" ]]; then
    hdiutil detach -quiet "$mounted_device" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$staging_root"
}
trap cleanup EXIT
volume_root="$staging_root/volume"
staging_app="$volume_root/Conn.app"
install -d -m 0755 "$volume_root"
ditto "$app_bundle" "$staging_app"

[[ -d "$staging_app/Contents/MacOS" ]] || { print -u2 "App bundle has no Contents/MacOS directory"; exit 1; }
bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$staging_app/Contents/Info.plist" 2>/dev/null || true)"
[[ "$bundle_identifier" == "$expected_bundle_identifier" ]] || {
  print -u2 "App CFBundleIdentifier ($bundle_identifier) must be $expected_bundle_identifier."
  exit 1
}
bundle_executable="$(plutil -extract CFBundleExecutable raw "$staging_app/Contents/Info.plist" 2>/dev/null || true)"
[[ "$bundle_executable" == "Conn" && -f "$staging_app/Contents/MacOS/Conn" ]] || {
  print -u2 "App CFBundleExecutable must be Conn and Contents/MacOS/Conn must exist."
  exit 1
}
app_version="$(plutil -extract CFBundleShortVersionString raw "$staging_app/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$app_version" ]] || {
  print -u2 "App CFBundleShortVersionString must be a non-empty release version."
  exit 1
}
version="$app_version"
"$script_dir/inspect-release.sh" --app "$staging_app"
if $ad_hoc; then
  codesign --force --deep --sign - "$staging_app"
else
  codesign --verify --deep --strict "$staging_app"
  signature_details="$(codesign -dv --verbose=4 "$staging_app" 2>&1)"
  [[ "$signature_details" == *"Authority=Developer ID Application:"* ]] || {
    print -u2 "A Developer ID Application signature is required unless --ad-hoc is explicit."
    exit 1
  }
fi

suffix=""
$ad_hoc && suffix="-adhoc"
install -d -m 0755 "$output_dir"
dmg_path="$output_dir/Conn-${version}${suffix}.dmg"
rm -f -- "$dmg_path" "$dmg_path.sha256"
volume_name="Conn ${version}"
read_write_dmg="$staging_root/Conn-${version}.rw.dmg"
app_size_kb="$(du -sk "$staging_app" | awk '{ print $1 }')"
image_size_kb=$(( app_size_kb + 32768 ))
(( image_size_kb >= 65536 )) || image_size_kb=65536

hdiutil create -quiet \
  -volname "$volume_name" \
  -fs HFS+ \
  -size "${image_size_kb}k" \
  "$read_write_dmg"

mount_root="/Volumes/$volume_name"
[[ ! -e "$mount_root" ]] || {
  print -u2 "A volume named '$volume_name' is already mounted; eject it before packaging."
  exit 1
}
attach_output="$(hdiutil attach -readwrite -noverify "$read_write_dmg")"
mounted_device="$(print -r -- "$attach_output" | awk '$1 ~ /^\/dev\// && NF >= 3 { device = $1 } END { print device }')"
[[ -n "$mounted_device" ]] || { print -u2 "Could not determine the mounted DMG device."; exit 1; }
[[ -d "$mount_root" ]] || { print -u2 "Expected mounted volume at $mount_root."; exit 1; }

ditto "$staging_app" "$mount_root/Conn.app"
ln -s /Applications "$mount_root/Applications"
install -d -m 0755 "$mount_root/.background"
sips -s format png "$dmg_background_svg" --out "$mount_root/.background/installer.png" >/dev/null
SetFile -a V "$mount_root/.background"

DMG_VOLUME_NAME="$volume_name" osascript <<'APPLESCRIPT'
set volumeName to system attribute "DMG_VOLUME_NAME"
tell application "Finder"
  tell disk volumeName
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {180, 180, 860, 610}

    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 14
    set label position of viewOptions to bottom
    set background picture of viewOptions to file ".background:installer.png"

    set position of item "Conn.app" of container window to {165, 230}
    set position of item "Applications" of container window to {515, 230}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Keep Finder's window layout while excluding mount-time filesystem metadata
# that is unrelated to the installer payload.
rm -rf -- "$mount_root/.fseventsd" "$mount_root/.Spotlight-V100" "$mount_root/.Trashes"
sync
hdiutil detach -quiet "$mounted_device"
mounted_device=""
mount_root=""

hdiutil convert -quiet "$read_write_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg_path"
hdiutil verify "$dmg_path"
"$script_dir/inspect-release.sh" --dmg "$dmg_path"
dmg_name="${dmg_path:t}"
(cd "$output_dir" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")

print "Packaged Conn DMG ${version}: $dmg_path"
if $ad_hoc; then
  print "Warning: this is ad-hoc signed for local smoke testing only; it is not notarized."
else
  print "Supply notarization separately before public distribution."
fi
