#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

forbidden='ConnCodexAdapter|AppServer|JSONRPC|JSONValue|ControlEndpoint|SharedDesktop'

if rg -n "$forbidden" Sources/ConnUI; then
    echo "ConnUI contains provider-shaped names or dependencies." >&2
    exit 1
fi

if rg -n 'AnyView' Sources/ConnUI Sources/ConnApp; then
    echo "The Integration settings seam must remain statically typed." >&2
    exit 1
fi

rg -q 'ConnSurfaceView<IntegrationSettingsContent: View>' \
    Sources/ConnUI/ConnSurfaceView.swift
rg -q 'ConnPanelController<IntegrationSettingsContent: View>' \
    Sources/ConnUI/ConnPanelController.swift
rg -q 'CodexIntegration\(' Sources/ConnApp/ConnApplication.swift
rg -q 'ConnIntegrationCoordinator\(' Sources/ConnApp/ConnApplication.swift
rg -q 'CodexIntegrationSettingsView' Sources/ConnApp/ConnApplication.swift

test ! -e Sources/ConnApp/ConnViewModel.swift
test ! -e Sources/ConnApp/ConnSurfaceView.swift
test ! -e Sources/ConnApp/ConnPanelController.swift
test ! -e Sources/ConnApp/GlobalHotKey.swift

echo "PASS: ConnUI is provider-neutral and ConnApp owns Codex composition"
