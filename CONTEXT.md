# Conn

Conn is a macOS companion for supervising work performed by external agentic
coding harnesses without conflating their provider-specific protocols.

## Language

**Harness**:
An external agentic coding system whose work Conn can supervise through a supported integration.
_Avoid_: Provider, backend, model

**Integration**:
One independently connected and qualified source of harness sessions, authority, freshness, and capabilities.
_Avoid_: Harness, adapter type, global provider singleton

**Conn Session**:
A harness-owned conversation or unit of continuing work represented inside Conn.
_Avoid_: Generic Thread, Conn job, process

**Upstream Session**:
The harness-specific object mapped into a Conn Session, such as a Codex Thread.
_Avoid_: Conn Session ID, globally unique thread

**Workspace**:
The source location against which a Conn Session performs work, with identity remaining Integration-scoped until equivalence is proven.
_Avoid_: Display-name-only Project match

**Project**:
A Conn presentation group for Sessions proven to share the same Workspace.
_Avoid_: Harness section, same-name path guess

**Conn-Originated Session**:
A Conn Session whose creation was explicitly requested through Conn and acknowledged by its harness.
_Avoid_: Conn-owned Session

**Session Ownership**:
The harness responsibility for the lifecycle and running process of an Upstream Session.
_Avoid_: Creation origin, Conn connection authority

**Session Retention**:
The harness-declared durability of an Upstream Session, expressed as ephemeral, persistent, or unknown.
_Avoid_: Session Ownership, active status

**Integration Capability**:
An operation proven to be supported by one Integration under its current version and mode.
_Avoid_: Harness-wide feature claim, UI availability

**Integration Freshness**:
The current authority of one Integration's displayed state, independent of every other Integration.
_Avoid_: Global Conn online status, Session completion

**Session Action Availability**:
Current evidence that a supported action is safe and meaningful for one Conn Session.
_Avoid_: Integration Capability, inferred control authority

**Conn Action**:
A provider-neutral user intent that asks a harness to act on a Session or its current work.
_Avoid_: Raw protocol method, arbitrary provider command

**Action Outcome**:
Evidence describing whether a Conn Action was unavailable, rejected, accepted, left acknowledgement-uncertain, invalidated, or resolved elsewhere.
_Avoid_: Boolean success, raw provider error

**Run**:
A bounded interval of harness work within a Conn Session, represented only when supported evidence establishes its boundary.
_Avoid_: Synthetic Turn, entire Session

**Activity**:
A meaningful observed work event attributed to a Conn Session and optionally to an evidence-backed Run.
_Avoid_: Raw provider event, transcript dump

**Attention Request**:
A supported upstream request that Conn can authoritatively answer or resolve.
_Avoid_: Failure, generic notification, inferred blocker

**Session Issue**:
A Session failure or degraded condition requiring inspection but carrying no upstream response authority.
_Avoid_: Attention Request, permission, question

**Attention**:
The umbrella for an Attention Request or Session Issue that warrants user awareness.
_Avoid_: Notification delivery, request token

**Attention State**:
The persistent Conn presentation of unresolved Attention.
_Avoid_: Assuming every item is actionable

## Relationships

- A **Harness** may have zero or more **Integrations**
- An **Integration** may expose zero or more **Upstream Sessions**
- Each **Upstream Session** maps to exactly one **Conn Session** within its **Integration**
- Conn may supervise **Conn Sessions** from multiple **Harnesses** simultaneously
- A **Conn Session** retains its harness attribution
- A **Conn Session** identity is scoped by its **Integration**
- A **Project** may contain **Conn Sessions** from multiple **Harnesses**
- Conn merges Integration-scoped **Workspaces** only when their identity equivalence is proven
- A **Conn-Originated Session** remains subject to harness **Session Ownership**
- **Session Retention** is independent of who originated the session
- An **Integration Capability** does not make its action available on every **Conn Session**
- **Integration Freshness** qualifies only Sessions supplied by that **Integration**
- **Session Action Availability** requires both an **Integration Capability** and current Session-specific authority
- An Integration may support any subset of the shared **Conn Actions**
- Every consequential **Conn Action** produces an evidence-bearing **Action Outcome**
- A **Conn Session** may contain zero or more evidence-backed **Runs**
- An **Activity** belongs to one **Conn Session** and may belong to one **Run**
- An **Attention Request** belongs to one **Conn Session** and may reference one **Run**
- **Attention** contains either an actionable **Attention Request** or a non-actionable **Session Issue**
- **Attention State** may present Requests and Issues without conflating their authority

## Example dialogue

> **Developer:** “Can a Codex Thread and a Claude Code session appear together?”
>
> **Domain expert:** “Yes. They are different Upstream Sessions represented as separate Conn Sessions with visible harness attribution.”

## Flagged ambiguities

- “Thread” previously meant both a Codex App Server Thread and the generic work unit; resolved: **Codex Thread** is upstream terminology and **Conn Session** is the cross-harness term.
- “Provider” can mean a model vendor, API vendor, or coding harness; resolved: Conn integrates with a **Harness**.
- “Conn-owned” was used for ephemeral sessions created through Conn; resolved: they are **Conn-Originated Sessions** with harness **Session Ownership** and independent **Session Retention**.
- “Harness” and “Integration” were used interchangeably; resolved: a **Harness** is the external product family while an **Integration** is one independently connected source.
- “Supported by a harness” was treated as sufficient control evidence; resolved: support is an **Integration Capability** and current execution requires **Session Action Availability**.
- “Conn is offline” was considered a global state; resolved: each **Integration** has independent **Integration Freshness** and repair state.
- “Project” was considered a Harness grouping; resolved: a **Project** groups proven shared **Workspace** identity while the Harness remains Session attribution.
- “Command” could mean a Conn user intent, shell execution, or provider protocol method; resolved: **Conn Action** names the shared user intent while provider methods remain adapter-internal.
- “Failed action” conflated pre-send refusal, provider rejection, and post-send uncertainty; resolved: **Action Outcome** preserves the evidence boundary and forbids automatic replay after uncertain acknowledgement.
- “Turn” was considered as a required cross-harness execution unit; resolved: a **Run** exists only when upstream evidence establishes a bounded work interval, while Activities may remain Session-scoped.
- “Attention Request” previously included failures; resolved: only response-bearing upstream requests are **Attention Requests**, while failures and degraded conditions are **Session Issues** under the broader **Attention** concept.
