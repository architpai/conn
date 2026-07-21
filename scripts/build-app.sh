#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
configuration="release"
output_dir="$repo_root/.build/conn-app"

usage() {
  print "Usage: ./scripts/build-app.sh [--debug] [--output DIRECTORY]"
}

while (( $# > 0 )); do
  case "$1" in
    --debug)
      configuration="debug"
      shift
      ;;
    --output)
      (( $# >= 2 )) || { print -u2 "--output needs a directory"; exit 2; }
      output_dir="${2:A}"
      shift 2
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

swift build --package-path "$repo_root" --configuration "$configuration" --product Conn
bin_dir="$(swift build --package-path "$repo_root" --configuration "$configuration" --show-bin-path)"
executable="$bin_dir/Conn"
info_plist="$repo_root/ConnApp/Resources/Info.plist"
app_icon="$repo_root/ConnApp/Resources/AppIcon.icns"
shared_desktop_prompt="$repo_root/docs/shared-desktop-agent-prompt.md"
license_file="$repo_root/LICENSE"
notice_file="$repo_root/NOTICE"
acknowledgements_file="$repo_root/ACKNOWLEDGEMENTS.md"
app_bundle="$output_dir/Conn.app"

[[ -x "$executable" ]] || { print -u2 "Missing Conn executable: $executable"; exit 1; }
[[ -f "$info_plist" ]] || { print -u2 "Missing app Info.plist: $info_plist"; exit 1; }
[[ -f "$app_icon" ]] || { print -u2 "Missing app icon: $app_icon"; exit 1; }
[[ -f "$shared_desktop_prompt" ]] || { print -u2 "Missing Shared Desktop setup prompt: $shared_desktop_prompt"; exit 1; }
[[ -f "$license_file" ]] || { print -u2 "Missing project license: $license_file"; exit 1; }
[[ -f "$notice_file" ]] || { print -u2 "Missing project notice: $notice_file"; exit 1; }
[[ -f "$acknowledgements_file" ]] || { print -u2 "Missing acknowledgements: $acknowledgements_file"; exit 1; }

rm -rf -- "$app_bundle"
install -d -m 0755 "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
install -m 0755 "$executable" "$app_bundle/Contents/MacOS/Conn"
install -m 0644 "$info_plist" "$app_bundle/Contents/Info.plist"
install -m 0644 "$app_icon" "$app_bundle/Contents/Resources/AppIcon.icns"
install -m 0644 "$shared_desktop_prompt" "$app_bundle/Contents/Resources/shared-desktop-agent-prompt.md"
install -m 0644 "$license_file" "$app_bundle/Contents/Resources/LICENSE"
install -m 0644 "$notice_file" "$app_bundle/Contents/Resources/NOTICE"
install -m 0644 "$acknowledgements_file" "$app_bundle/Contents/Resources/ACKNOWLEDGEMENTS.md"
plutil -lint "$app_bundle/Contents/Info.plist"
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

print "Built ad-hoc-signed Conn app: $app_bundle"
