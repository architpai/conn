#!/bin/zsh
set -euo pipefail

app_bundle=""
dmg_path=""
mounted_device=""
mount_root=""
scan_root=""

usage() {
  cat <<'EOF'
Usage: ./scripts/inspect-release.sh (--app /absolute/path/to/Conn.app | --dmg /absolute/path/to/Conn.dmg)

Fail if a Conn release contains a retired hook bridge, relay, probe, plugin, or
hook-registration payload. DMG inspection mounts the image read-only, requires
one Conn.app plus the conventional /Applications install shortcut, and applies
the same checks to the app.
EOF
}

cleanup() {
  if [[ -n "$mounted_device" ]]; then
    hdiutil detach -quiet "$mounted_device" >/dev/null 2>&1 || true
  fi
  if [[ -n "$mount_root" && -d "$mount_root" ]]; then
    rmdir "$mount_root" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || { print -u2 "--app needs a path"; exit 2; }
      app_bundle="${2:A}"
      shift 2
      ;;
    --dmg)
      (( $# >= 2 )) || { print -u2 "--dmg needs a path"; exit 2; }
      dmg_path="${2:A}"
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

if [[ -n "$app_bundle" && -n "$dmg_path" ]] || [[ -z "$app_bundle" && -z "$dmg_path" ]]; then
  print -u2 "Choose exactly one of --app or --dmg."
  exit 2
fi

if [[ -n "$dmg_path" ]]; then
  [[ -f "$dmg_path" && ! -L "$dmg_path" ]] || {
    print -u2 "A regular DMG is required: $dmg_path"
    exit 2
  }
  mount_root="$(mktemp -d "${TMPDIR:-/tmp}/conn-inspect.XXXXXX")"
  attach_output="$(hdiutil attach -readonly -nobrowse -mountpoint "$mount_root" "$dmg_path")"
  mounted_device="$(print -r -- "$attach_output" | awk '$1 ~ /^\/dev\// && NF >= 3 { device = $1 } END { print device }')"
  [[ -n "$mounted_device" ]] || {
    print -u2 "Could not determine the mounted DMG device."
    exit 1
  }
  app_candidates=("$mount_root"/*.app(N/))
  (( ${#app_candidates[@]} == 1 )) || {
    print -u2 "Conn DMG must contain exactly one top-level app bundle."
    exit 1
  }
  app_bundle="${app_candidates[1]}"
  unexpected_top_level=("$mount_root"/*(N) "$mount_root"/.*(N))
  for top_level in "${unexpected_top_level[@]}"; do
    [[ "${top_level:t}" == "Conn.app" ]] && continue
    if [[ "${top_level:t}" == "Applications" ]]; then
      [[ -L "$top_level" && "$(readlink "$top_level")" == "/Applications" ]] || {
        print -u2 "DMG Applications shortcut must be a symlink to /Applications."
        exit 1
      }
      continue
    fi
    if [[ "${top_level:t}" == ".background" ]]; then
      [[ -d "$top_level" && ! -L "$top_level" ]] || {
        print -u2 "DMG background payload must be a regular directory."
        exit 1
      }
      background_entries=("$top_level"/*(N) "$top_level"/.*(N))
      (( ${#background_entries[@]} == 1 )) && \
        [[ "${background_entries[1]:t}" == "installer.png" ]] && \
        [[ -f "${background_entries[1]}" && ! -L "${background_entries[1]}" ]] || {
          print -u2 "DMG background must contain only a regular installer.png."
          exit 1
        }
      continue
    fi
    if [[ "${top_level:t}" == ".DS_Store" ]]; then
      [[ -f "$top_level" && ! -L "$top_level" ]] || {
        print -u2 "DMG Finder layout metadata must be a regular .DS_Store file."
        exit 1
      }
      continue
    fi
    print -u2 "Unexpected top-level DMG payload: ${top_level:t}"
    exit 1
  done
  [[ -L "$mount_root/Applications" && "$(readlink "$mount_root/Applications")" == "/Applications" ]] || {
    print -u2 "Conn DMG must contain an Applications shortcut targeting /Applications."
    exit 1
  }
  [[ -f "$mount_root/.background/installer.png" && ! -L "$mount_root/.background/installer.png" ]] || {
    print -u2 "Conn DMG must contain its installer background artwork."
    exit 1
  }
  scan_root="$mount_root"
fi

[[ -d "$app_bundle" && ! -L "$app_bundle" && "${app_bundle:t}" == "Conn.app" ]] || {
  print -u2 "A non-symlinked Conn.app bundle is required: $app_bundle"
  exit 2
}

[[ -n "$scan_root" ]] || scan_root="$app_bundle"
while IFS= read -r -d '' candidate_path; do
  relative="${candidate_path#$scan_root/}"
  case "$relative" in
    *"/.codex-plugin/"*|*"/.codex-plugin"|*"/plugins/"*|plugins/*|*"/hooks.json"|hooks.json|*"sidequest-hook-relay"*|*"conn-probe"*|*"ConnBridge"*)
      print -u2 "Retired legacy payload found in Conn release: $relative"
      exit 1
      ;;
  esac
done < <(find "$scan_root" -print0)

executable="$app_bundle/Contents/MacOS/Conn"
[[ -f "$executable" && ! -L "$executable" ]] || {
  print -u2 "Conn release has no regular Contents/MacOS/Conn executable."
  exit 1
}

for distribution_document in LICENSE NOTICE ACKNOWLEDGEMENTS.md; do
  document_path="$app_bundle/Contents/Resources/$distribution_document"
  [[ -s "$document_path" && ! -L "$document_path" ]] || {
    print -u2 "Conn release is missing regular distribution document: $distribution_document"
    exit 1
  }
done

for token in \
  ConnBridge \
  DurableEventInbox \
  HookEventNormalizer \
  LiveEventReceiver \
  sidequest-hook-relay \
  plugins/sidequest \
  hooks/hooks.json; do
  if grep -Fq -- "$token" < <(strings - "$executable"); then
    print -u2 "Retired legacy token found in Conn executable: $token"
    exit 1
  fi
done

print "PASS: Conn release contains no retired hook/plugin payloads: $app_bundle"
