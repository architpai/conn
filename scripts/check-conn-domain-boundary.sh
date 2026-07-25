#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

forbidden_imports='^import (ConnAppCore|ConnAppServerAdapter|ConnCodexAdapter|ConnUI|AppKit|SwiftUI)([[:space:]]|$)'

if forbidden_matches=$(rg -n "$forbidden_imports" Sources/ConnDomain); then
    printf '%s\n' "$forbidden_matches"
    echo "ConnDomain imports a forbidden production or UI module." >&2
    exit 1
else
    scan_status=$?
    if [ "$scan_status" -ne 1 ]; then
        echo "ConnDomain import scan failed with status $scan_status." >&2
        exit "$scan_status"
    fi
fi

if ! rg -q '\.target\(name: "ConnDomain"\)' Package.swift; then
    echo "ConnDomain must remain a dependency-free Swift package target." >&2
    exit 1
fi

echo "PASS: ConnDomain has no adapter, AppCore, or UI dependency"
