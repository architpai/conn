#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

forbidden='AppServer|JSONRPC|JSONValue|ControlEndpoint|SharedDesktop|PiBroker|PiExternal|ExtensionAPI|deliverAs|conn_question'

if rg -n "$forbidden" Sources/ConnDomain Sources/ConnAppCore Sources/ConnUI; then
    echo "Provider-shaped names escaped the Codex adapter or composition edge." >&2
    exit 1
fi

if rg -n '^import (ConnCodexAdapter|ConnPiAdapter)' \
    Sources/ConnDomain Sources/ConnAppCore Sources/ConnUI; then
    echo "A neutral production target imports the Codex adapter." >&2
    exit 1
fi

test ! -d MigrationEvidence/ConnLegacyUI
test ! -e Sources/ConnAppCore/ThreadPickerPolicy.swift
test ! -e Sources/ConnAppCore/LegacyHookRetirementStore.swift

rg -q 'name: "ConnDomain"' Package.swift
rg -q 'name: "ConnAppCore"' Package.swift
rg -q 'name: "ConnCodexAdapter"' Package.swift
rg -q 'name: "ConnPiAdapter"' Package.swift
rg -q 'name: "ConnUI"' Package.swift
rg -q 'name: "ConnApp"' Package.swift
rg -q 'dependencies: \["ConnAppCore", "ConnDomain"\]' Package.swift

echo "PASS: provider-neutral production boundaries"
