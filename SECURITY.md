# Security

## Reporting a vulnerability

Please report vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/007danlin/VeloEdit/security/advisories/new).
Include the affected version, reproduction steps, and expected impact. Do not publish private keys, personal media, or exploitable details in a public issue.

Security fixes target the latest published release. VeloEdit is currently beta software; its current distribution uses Sparkle update signatures and an ad-hoc application signature, without Apple notarization.

## Maintainer workflow

Normal trusted pushes to `main` and the existing GitHub Releases / Sparkle workflow remain available. The active main-branch ruleset blocks deletion and force-pushing without adding a second-reviewer requirement. These rules do not protect against a compromised owner account or a malicious change the owner accepts.

External contributions require review before merging or running their code. Inspect scripts, dependency changes, CI permissions, instructions, download destinations, and payment links. Validate untrusted contributions in a disposable environment without credentials; do not use the release Mac. Worktrees isolate changes, not executable code or secrets.

GitHub Actions uses a read-only default token, cannot approve pull requests, requires approval for fork workflow runs from all external contributors, and requires full commit SHAs for external actions. Approval allows code to run; it is not a substitute for reviewing that code. No signing keys or production credentials belong in PR jobs.

Dependabot alerts and security update PRs are enabled. Review and test these PRs before merging. Vendored native libraries and downloaded model/runtime artifacts also need separate tracking; Dependabot does not cover every bundled component.

Keep GitHub, Cloudflare, the domain registrar, and their recovery accounts protected with MFA/passkeys. Keep the Sparkle private signing key in the release machine's Keychain with a secure backup. Never put it in the repository, PR runners, or the website. Follow [the release guide](Docs/Guides/release.md) when publishing.
