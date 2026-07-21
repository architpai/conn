# Security Policy

## Supported versions

Conn is currently alpha software. Until the project publishes a broader support
policy, security fixes are provided only for the latest release on the `main`
branch.

| Version | Supported |
| --- | --- |
| 0.1.x | Yes |
| Earlier or unreleased development snapshots | No |

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability. Use
[GitHub private vulnerability reporting](https://github.com/architpai/conn/security/advisories/new)
to send a confidential report to the maintainers.

Include, when possible:

- the affected Conn version and macOS version;
- the relevant Codex CLI and App Server versions;
- a clear description of the impact and prerequisites;
- minimal reproduction steps or a proof of concept;
- whether credentials, transcripts, permission decisions, or local files may be
  exposed; and
- any suggested mitigation.

Please remove secrets and personal data that are not necessary to reproduce the
issue. The maintainers will acknowledge the report when it is reviewed, assess
its severity and scope, and coordinate remediation and disclosure through the
private advisory. Response and fix timelines may vary while the project is in
alpha.

## Security boundaries

Conn is designed as a local, non-owning client of Codex's App Server integration.
Reports involving authentication, local socket access, approval routing,
permission scope, untrusted protocol input, update or release integrity, privacy
retention, or an unexpected widening of Codex control are particularly useful.

Security issues in Codex or another upstream dependency should also be reported
to that project's security channel when appropriate. Please do not test against
systems, accounts, or data you do not own or have permission to use.
