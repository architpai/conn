# Conn App Server 0.144.5 probe fixtures

These deterministic samples document the Phase 5 probe's persisted format.
They are not captured transcripts.

- Request identifiers are synthetic `req-NNN` values.
- Only JSON-RPC method names, envelope shapes, error codes, and bounded
  evidence labels are retained.
- Prompt and response text, filesystem paths, authentication material, model
  settings, environment values, and real thread, turn, or item identifiers are
  forbidden.
- Stable capabilities omit `experimentalApi`; experimental capabilities set it
  explicitly. Both use exactly one notification opt-out:
  `item/reasoning/textDelta`.
- Reasoning summaries and required lifecycle/request methods stay retained.
- Consequential methods are never represented as automatically retried.

Live probe output passes through `SanitizedProtocolTraceDocument.validated()`
before it can be printed or written as a fixture. An existing fixture path is
never overwritten implicitly.
