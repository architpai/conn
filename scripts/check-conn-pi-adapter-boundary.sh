#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

forbidden_adapter_imports='^[[:space:]]*(@testable[[:space:]]+)?import([[:space:]]+(class|struct|enum|protocol|func|var|let|typealias))?[[:space:]]+(ConnAppCore|ConnCodexAdapter|ConnUI|AppKit|SwiftUI)([.]|[[:space:]]|$)'
if forbidden_matches=$(rg -n "$forbidden_adapter_imports" Sources/ConnPiAdapter); then
    printf '%s\n' "$forbidden_matches"
    echo "ConnPiAdapter imports another adapter, AppCore, or UI module." >&2
    exit 1
else
    scan_status=$?
    if [ "$scan_status" -ne 1 ]; then
        echo "ConnPiAdapter import scan failed with status $scan_status." >&2
        exit "$scan_status"
    fi
fi

raw_neutral_names='PiBroker|PiExternal|ExtensionAPI|deliverAs|conn_question'
if raw_matches=$(rg -n "$raw_neutral_names" Sources/ConnDomain Sources/ConnAppCore Sources/ConnUI); then
    printf '%s\n' "$raw_matches"
    echo "A Pi-specific name crossed the neutral production boundary." >&2
    exit 1
else
    scan_status=$?
    if [ "$scan_status" -ne 1 ]; then
        echo "Neutral Pi boundary scan failed with status $scan_status." >&2
        exit "$scan_status"
    fi
fi

rg -q 'public actor PiExternalIntegration: ConnIntegration' \
    Sources/ConnPiAdapter/ConnPiAdapter.swift
rg -q 'name: "ConnPiAdapter"' Package.swift
rg -q 'name: "conn-pi-adapter-tests"' Package.swift
rg -q 'dependencies: \["ConnAppCore", "ConnDomain"\]' Package.swift

echo "PASS: ConnPiAdapter contains Pi details behind the neutral port"
