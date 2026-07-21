#!/bin/bash

set -euo pipefail

readonly JSON_NORMALIZATION="jq --sort-keys '.'"

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIRECTORY
REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd -P)"
readonly REPOSITORY_ROOT
readonly SCHEMA_BASE="${REPOSITORY_ROOT}/protocol-schemas/codex-app-server"

usage() {
    cat >&2 <<EOF
Usage:
  $(basename "$0") verify [VERSION]
  $(basename "$0") generate VERSION [CODEX_EXECUTABLE]

verify without VERSION checks every committed schema manifest. generate uses the
manifest-recorded native executable unless CODEX_EXECUTABLE is supplied.
EOF
}

fail() {
    printf 'generate-codex-app-server-schemas: %s\n' "$*" >&2
    exit 1
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

portable_display_path() {
    local absolute_path="$1"
    local codex_home_path="${CODEX_HOME:-${HOME}/.codex}"

    if [[ -e "${codex_home_path}" ]]; then
        codex_home_path="$(realpath "${codex_home_path}")"
    fi

    if [[ "${absolute_path}" == "${codex_home_path}" ]]; then
        printf '%s\n' '$CODEX_HOME'
    elif [[ "${absolute_path}" == "${codex_home_path}/"* ]]; then
        printf '$CODEX_HOME/%s\n' "${absolute_path#"${codex_home_path}/"}"
    elif [[ "${absolute_path}" == "${HOME}" ]]; then
        printf '%s\n' '$HOME'
    elif [[ "${absolute_path}" == "${HOME}/"* ]]; then
        printf '$HOME/%s\n' "${absolute_path#"${HOME}/"}"
    else
        printf '%s\n' "${absolute_path}"
    fi
}

materialize_recorded_path() {
    local recorded_path="$1"
    local codex_home_path="${CODEX_HOME:-${HOME}/.codex}"

    case "${recorded_path}" in
        '$CODEX_HOME')
            printf '%s\n' "${codex_home_path}"
            ;;
        '$CODEX_HOME/'*)
            printf '%s/%s\n' "${codex_home_path}" "${recorded_path#\$CODEX_HOME/}"
            ;;
        '$HOME')
            printf '%s\n' "${HOME}"
            ;;
        '$HOME/'*)
            printf '%s/%s\n' "${HOME}" "${recorded_path#\$HOME/}"
            ;;
        '$EXTERNAL/'*)
            fail "cannot materialize legacy external path '${recorded_path}'"
            ;;
        /*)
            printf '%s\n' "${recorded_path}"
            ;;
        *)
            fail "manifest native executable path is not absolute or portable: ${recorded_path}"
            ;;
    esac
}

manifest_path_for_version() {
    printf '%s/%s/manifest.json\n' "${SCHEMA_BASE}" "$1"
}

schema_root_for_version() {
    printf '%s/%s\n' "${SCHEMA_BASE}" "$1"
}

recorded_native_executable() {
    local manifest_path="$1"
    local recorded_path
    local executable_path

    recorded_path="$(jq -er \
        '.codexCli.nativeExecutable.resolvedPath | select(type == "string" and length > 0)' \
        "${manifest_path}")" || fail "manifest has no recorded native executable: ${manifest_path}"
    executable_path="$(materialize_recorded_path "${recorded_path}")"
    [[ -x "${executable_path}" ]] || fail \
        "recorded native Codex executable is missing or not executable: ${executable_path}"
    realpath "${executable_path}"
}

generated_file_hashes() {
    local bundle_root="$1"
    local file
    local relative_path

    (
        cd "${bundle_root}"
        find stable experimental -type f -print | LC_ALL=C sort
    ) | while IFS= read -r relative_path; do
        file="${bundle_root}/${relative_path}"
        jq -cn \
            --arg path "${relative_path}" \
            --arg sha256 "$(sha256_file "${file}")" \
            '{path: $path, sha256: $sha256}'
    done | jq -s '.'
}

normalize_bundle_json() {
    local bundle_root="$1"
    local file
    local normalized_file

    while IFS= read -r file; do
        normalized_file="${file}.normalized"
        jq --sort-keys '.' "${file}" > "${normalized_file}"
        chmod 0644 "${normalized_file}"
        mv "${normalized_file}" "${file}"
    done < <(find "${bundle_root}" -type f -name '*.json' -print | LC_ALL=C sort)
}

require_versioned_native_executable() {
    local version="$1"
    local executable_path="$2"
    local actual_version
    local expected_version="codex-cli ${version}"

    [[ -x "${executable_path}" ]] || fail \
        "Codex executable is missing or not executable: ${executable_path}"
    actual_version="$("${executable_path}" --version 2>&1)"
    [[ "${actual_version}" == "${expected_version}" ]] || fail \
        "expected exactly '${expected_version}' from ${executable_path}, found '${actual_version}'"
}

generate_bundles() {
    local executable_path="$1"
    local output_root="$2"

    mkdir -p "${output_root}"
    "${executable_path}" app-server generate-json-schema --out "${output_root}/stable"
    "${executable_path}" app-server generate-json-schema --experimental --out "${output_root}/experimental"
    normalize_bundle_json "${output_root}"
}

write_manifest() {
    local version="$1"
    local executable_path="$2"
    local schema_root="$3"
    local manifest_path="${schema_root}/manifest.json"
    local executable_display_path
    local generated_at_utc
    local generated_files
    local stable_command
    local experimental_command
    local temporary_manifest

    executable_display_path="$(portable_display_path "${executable_path}")"
    generated_at_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    generated_files="$(generated_file_hashes "${schema_root}")"
    stable_command="${executable_display_path} app-server generate-json-schema --out protocol-schemas/codex-app-server/${version}/stable"
    experimental_command="${executable_display_path} app-server generate-json-schema --experimental --out protocol-schemas/codex-app-server/${version}/experimental"
    temporary_manifest="$(mktemp "${schema_root}/.manifest.json.XXXXXX")"

    jq -n \
        --arg schema_bundle_version "${version}" \
        --arg cli_version "codex-cli ${version}" \
        --arg executable_path "${executable_display_path}" \
        --arg executable_sha256 "$(sha256_file "${executable_path}")" \
        --arg generated_at_utc "${generated_at_utc}" \
        --arg platform "$(uname -s)" \
        --arg architecture "$(uname -m)" \
        --arg stable_command "${stable_command}" \
        --arg experimental_command "${experimental_command}" \
        --arg json_normalization "${JSON_NORMALIZATION}" \
        --argjson generated_files "${generated_files}" \
        '{
            manifestFormatVersion: 1,
            schemaBundleVersion: $schema_bundle_version,
            codexCli: {
                version: $cli_version,
                launcher: {
                    command: "codex",
                    commandPath: $executable_path,
                    resolvedPath: $executable_path,
                    sha256: $executable_sha256
                },
                nativeExecutable: {
                    resolvedPath: $executable_path,
                    sha256: $executable_sha256
                }
            },
            generation: {
                generatedAtUtc: $generated_at_utc,
                platform: $platform,
                architecture: $architecture,
                commands: [
                    $stable_command,
                    $experimental_command
                ],
                jsonNormalization: $json_normalization
            },
            generatedFiles: $generated_files
        }' > "${temporary_manifest}"

    chmod 0644 "${temporary_manifest}"
    mv "${temporary_manifest}" "${manifest_path}"
}

validate_manifest() {
    local version="$1"
    local executable_path="$2"
    local schema_root="$3"
    local manifest_path="${schema_root}/manifest.json"
    local executable_display_path
    local expected_file_hashes
    local recorded_file_hashes

    [[ -f "${manifest_path}" ]] || fail "missing manifest: ${manifest_path}"
    executable_display_path="$(portable_display_path "${executable_path}")"

    jq -e \
        --arg schema_bundle_version "${version}" \
        --arg cli_version "codex-cli ${version}" \
        --arg executable_path "${executable_display_path}" \
        --arg executable_sha256 "$(sha256_file "${executable_path}")" \
        --arg platform "$(uname -s)" \
        --arg architecture "$(uname -m)" \
        --arg stable_suffix " app-server generate-json-schema --out protocol-schemas/codex-app-server/${version}/stable" \
        --arg experimental_suffix " app-server generate-json-schema --experimental --out protocol-schemas/codex-app-server/${version}/experimental" \
        --arg json_normalization "${JSON_NORMALIZATION}" \
        '
            .manifestFormatVersion == 1 and
            .schemaBundleVersion == $schema_bundle_version and
            .codexCli.version == $cli_version and
            .codexCli.launcher.command == "codex" and
            (.codexCli.launcher.commandPath | type == "string" and length > 0) and
            .codexCli.launcher.resolvedPath == $executable_path and
            .codexCli.launcher.sha256 == $executable_sha256 and
            .codexCli.nativeExecutable.resolvedPath == $executable_path and
            .codexCli.nativeExecutable.sha256 == $executable_sha256 and
            (.generation.generatedAtUtc |
                type == "string" and
                test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
            .generation.platform == $platform and
            .generation.architecture == $architecture and
            (.generation.commands | type == "array" and length == 2) and
            (.generation.commands[0] | type == "string" and endswith($stable_suffix)) and
            (.generation.commands[1] | type == "string" and endswith($experimental_suffix)) and
            .generation.jsonNormalization == $json_normalization and
            (.generatedFiles | type == "array" and length > 0)
        ' "${manifest_path}" >/dev/null || fail \
        "manifest provenance is invalid for Codex CLI ${version}"

    expected_file_hashes="$(generated_file_hashes "${schema_root}" | jq -S '.')"
    recorded_file_hashes="$(jq -S '.generatedFiles' "${manifest_path}")"
    [[ "${recorded_file_hashes}" == "${expected_file_hashes}" ]] || fail \
        "manifest generated-file hashes do not match the ${version} committed bundles"
}

generate_version() {
    local version="$1"
    local executable_argument="${2:-}"
    local schema_root
    local manifest_path
    local executable_path
    local temporary_root

    schema_root="$(schema_root_for_version "${version}")"
    manifest_path="$(manifest_path_for_version "${version}")"

    if [[ -n "${executable_argument}" ]]; then
        executable_path="$(realpath "${executable_argument}")"
    else
        [[ -f "${manifest_path}" ]] || fail \
            "new schema version ${version} requires an explicit Codex executable"
        executable_path="$(recorded_native_executable "${manifest_path}")"
    fi
    require_versioned_native_executable "${version}" "${executable_path}"

    temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/conn-codex-schemas.${version}.XXXXXX")"
    trap 'rm -rf "${temporary_root:-}"' EXIT
    generate_bundles "${executable_path}" "${temporary_root}"

    mkdir -p "${schema_root}"
    rm -rf "${schema_root}/stable" "${schema_root}/experimental"
    mv "${temporary_root}/stable" "${schema_root}/stable"
    mv "${temporary_root}/experimental" "${schema_root}/experimental"
    write_manifest "${version}" "${executable_path}" "${schema_root}"

    rm -rf "${temporary_root}"
    trap - EXIT
    printf 'Generated Codex App Server %s stable and experimental schema bundles.\n' "${version}"
}

verify_version() {
    local version="$1"
    local schema_root
    local manifest_path
    local executable_path
    local temporary_root

    schema_root="$(schema_root_for_version "${version}")"
    manifest_path="$(manifest_path_for_version "${version}")"
    [[ -d "${schema_root}/stable" ]] || fail "missing ${version} stable schema bundle"
    [[ -d "${schema_root}/experimental" ]] || fail "missing ${version} experimental schema bundle"

    executable_path="$(recorded_native_executable "${manifest_path}")"
    require_versioned_native_executable "${version}" "${executable_path}"
    validate_manifest "${version}" "${executable_path}" "${schema_root}"

    temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/conn-codex-schemas.${version}.XXXXXX")"
    trap 'rm -rf "${temporary_root:-}"' EXIT
    generate_bundles "${executable_path}" "${temporary_root}"

    diff -ru "${schema_root}/stable" "${temporary_root}/stable" || fail \
        "stable schema bundle has drifted from Codex CLI ${version}"
    diff -ru "${schema_root}/experimental" "${temporary_root}/experimental" || fail \
        "experimental schema bundle has drifted from Codex CLI ${version}"

    rm -rf "${temporary_root}"
    trap - EXIT
    printf 'Verified Codex App Server %s schema bundles with its manifest-recorded native executable.\n' "${version}"
}

verify_all() {
    local manifest_path
    local version
    local verified_count=0

    while IFS= read -r manifest_path; do
        version="$(basename "$(dirname "${manifest_path}")")"
        verify_version "${version}"
        verified_count=$((verified_count + 1))
    done < <(find "${SCHEMA_BASE}" -mindepth 2 -maxdepth 2 -type f -name manifest.json -print | LC_ALL=C sort)

    [[ "${verified_count}" -gt 0 ]] || fail "no committed schema manifests found in ${SCHEMA_BASE}"
    printf 'Verified all %d supported Codex App Server schema versions.\n' "${verified_count}"
}

case "${1:-verify}" in
    generate)
        if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
            usage
            exit 64
        fi
        generate_version "$2" "${3:-}"
        ;;
    verify)
        if [[ "$#" -gt 2 ]]; then
            usage
            exit 64
        fi
        if [[ "$#" -eq 2 ]]; then
            verify_version "$2"
        else
            verify_all
        fi
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage
        exit 64
        ;;
esac
