# Provider-neutral Conn integration boundary

Status: Accepted
Date: 2026-07-24

Conn supervises Harness-owned Sessions through an internal provider-neutral
integration port rather than exposing Codex App Server concepts to its domain,
application core, or UI. Conn v0.2 ships only a Codex adapter, but the core
models simultaneous Integrations, scoped Session identities, semantic updates,
capabilities, freshness, and actions without raw provider payloads or command
escape hatches.

The production target graph is deliberately small: `ConnDomain` owns neutral
models, reducers, and the integration port; `ConnAppCore` owns aggregation,
persistence, action availability, and presentation; `ConnCodexAdapter` owns all
Codex and App Server behavior; `ConnUI` owns the native view model and surface;
and the `ConnApp` executable is the composition root. Compiler dependencies
prevent AppCore and UI from importing the Codex adapter.

The enforced production edges are `ConnAppCore -> ConnDomain`,
`ConnCodexAdapter -> ConnDomain`,
`ConnUI -> ConnDomain + ConnAppCore`, and
`ConnApp -> ConnDomain + ConnAppCore + ConnCodexAdapter + ConnUI`;
`ConnDomain` has no Conn production dependency. Codex-only settings are
composed by `ConnApp` into a typed generic SwiftUI content slot owned by
`ConnUI`; provider state does not cross that seam through `AnyView`, opaque
action identifiers, or provider dictionaries.

v0.2 cuts over atomically to the new path without a legacy runtime fallback.
The integration port remains an internal Swift contract until multiple working
adapters provide evidence for any public plugin or IPC API.
