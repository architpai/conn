#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/conn-migration-edge.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

xcrun swiftc \
    "$root/Sources/ConnApp/LegacyHookRetirementStore.swift" \
    "$root/Tests/ConnMigrationEdgeTests/Phase11LegacyHookRetirementTestCases.swift" \
    "$root/Tests/ConnMigrationEdgeTests/TestRunner.swift" \
    -o "$temporary/conn-migration-edge-tests"

"$temporary/conn-migration-edge-tests"
