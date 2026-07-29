#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

forbidden_adapter_imports='^[[:space:]]*(@testable[[:space:]]+)?import([[:space:]]+(class|struct|enum|protocol|func|var|let|typealias))?[[:space:]]+(ConnAppCore|ConnUI|AppKit|SwiftUI)([.]|[[:space:]]|$)'
if forbidden_matches=$(rg -n "$forbidden_adapter_imports" Sources/ConnCodexAdapter); then
    printf '%s\n' "$forbidden_matches"
    echo "ConnCodexAdapter imports a forbidden AppCore or UI module." >&2
    exit 1
else
    scan_status=$?
    if [ "$scan_status" -ne 1 ]; then
        echo "ConnCodexAdapter import scan failed with status $scan_status." >&2
        exit "$scan_status"
    fi
fi

raw_neutral_names='AppServer|ConnAppServer|JSONRPC|JSONValue|ControlEndpoint|SharedDesktop|Transport|WebSocket|Stdio'
if raw_matches=$(rg -n "$raw_neutral_names" \
    Sources/ConnDomain/ConnIntegration.swift \
    Sources/ConnDomain/ConnIntegrationModels.swift \
    Sources/ConnDomain/ConnIntegrationProjection.swift); then
    printf '%s\n' "$raw_matches"
    echo "A provider-specific name crossed the neutral ConnDomain boundary." >&2
    exit 1
else
    scan_status=$?
    if [ "$scan_status" -ne 1 ]; then
        echo "Neutral boundary scan failed with status $scan_status." >&2
        exit "$scan_status"
    fi
fi

if [ -d Sources/ConnAppServerAdapter ] || [ -d Tests/ConnAppServerAdapterTests ]; then
    echo "Legacy ConnAppServerAdapter target directories still exist." >&2
    exit 1
fi

legacy_names='ConnAppServerAdapter|conn-app-server-adapter-tests'
if legacy_matches=$(rg -n "$legacy_names" Package.swift Sources Tests); then
    printf '%s\n' "$legacy_matches"
    echo "Legacy adapter target, product, or executable references remain." >&2
    exit 1
else
    scan_status=$?
    if [ "$scan_status" -ne 1 ]; then
        echo "Legacy adapter reference scan failed with status $scan_status." >&2
        exit "$scan_status"
    fi
fi

if ! rg -q 'public actor CodexIntegration: ConnIntegration' \
    Sources/ConnCodexAdapter/CodexIntegration.swift; then
    echo "ConnCodexAdapter must provide the neutral ConnIntegration port." >&2
    exit 1
fi

echo "PASS: ConnCodexAdapter contains provider details behind the neutral port"
