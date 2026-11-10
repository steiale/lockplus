# Security policy

## Reporting a vulnerability

Please report security issues **privately** through GitHub's
[private vulnerability reporting](https://github.com/steiale/lockplus/security/advisories/new) on this repository,
not as a public issue.

Helpful to include: the LockPlus version (Settings › About), the macOS version, what you observed, and steps or a
profile (with secrets removed) that reproduce it.

What happens next:

- I acknowledge your report within **7 days**.
- I keep you informed while I investigate and fix it.
- Fixes ship as a signed update through LockPlus's built-in updater; the advisory is published after the fix is out.
- I'd like to coordinate disclosure with you; the default is publication once a fix is released, or after **90 days**,
  whichever comes first.
- With your permission, you are credited in the advisory and the release notes.

LockPlus is maintained by one person, so please be patient; I take every report seriously.

## Supported versions

| Version | Security fixes |
|---|---|
| **2.x** (native, macOS 26+) | Yes, latest release only |
| 1.2.0 and older (Go app) | No. 1.2.0 offers the move to 2.x. |

## Scope

In scope:

- the LockPlus app and its network (system) extension;
- the app ↔ extension XPC interface;
- handling of profiles, keys and passwords (keychain, profile files, logs, the diagnostics export);
- the kill switch and DNS handling, beyond the limits documented in the README FAQ;
- the update chain (Sparkle feed and signatures);
- the migration from LockPlus 1.x and the removal of its old helper.

Out of scope, or better reported elsewhere:

- vulnerabilities in **OpenVPN 3**, **wireguard-go** or **OpenSSL** themselves: please report them to those projects
  as well (LockPlus ships them pinned and updates when fixes are released);
- macOS behaviour that LockPlus documents as a limit, e.g. the short window after a tunnel-process crash or the
  traffic macOS always lets bypass a VPN (see "How tight is the kill switch?" in the README);
- issues that need an already compromised Mac or administrator access;
- your VPN server's configuration.

## How LockPlus is reviewed

LockPlus has not had an independent human security audit. Its security-relevant changes went through dedicated AI
review passes; the reports and their fixes are in [`docs/reviews/`](docs/reviews/). Independent review is very
welcome.
