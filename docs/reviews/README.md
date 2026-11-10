# Review reports

These are the reports of the dedicated AI review passes that LockPlus 2 went through before release, published as
written. Each names the commit or area it reviewed, lists its findings by severity, and later files record how the
findings were fixed and re-checked. Only local checkout paths were shortened to repository-relative paths.

- `*-fable-*.md`: security and correctness passes (privileged and cross-user paths, the tunnel extension, XPC, secret
  handling, the update path, on-demand and pause, the upgrade from LockPlus 1.x).
- `*-sonnet-*.md`: first-pass reviews of the app root, the tunnel, the UI and the core packages and tooling.
- `2026-10-27-zipfoundation.md`: the review of the one new dependency before it was adopted.

Section numbers such as §7.2 refer to [`docs/native/DESIGN.md`](../native/DESIGN.md).

An AI review is not a human security audit. If you find something these passes missed, please report it: security
issues through GitHub's private vulnerability reporting on this repository, everything else as an issue.
