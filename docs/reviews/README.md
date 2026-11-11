# Review reports

These are the reports of the dedicated AI review passes that LockPlus 2 went through before release, published as
written. Each names the commit or area it reviewed, lists its findings by severity, and later files record how the
findings were fixed and re-checked. Only local checkout paths were shortened to repository-relative paths.

- `*-fable-*.md`: security and correctness passes (privileged and cross-user paths, the tunnel extension, XPC, secret
  handling, the update path, on-demand and pause, the upgrade from LockPlus 1.x).
- `*-codex-*.md`: OpenAI Codex, GPT-6-Astra at max reasoning effort. An independent second model family since 2.0.1, used beside Fable on the start guard (the single default-effort pass of round 1 is marked as such).
- `*-sonnet-*.md`: first-pass reviews of the app root, the tunnel, the UI and the core packages and tooling.
- `2026-11-11-2.0.1-start-guard-reviews.md`: the overview of the 2.0.1 start guard reviews (ten rounds, both families, what was accepted). Beside the reports, the 2.0.1 build was run in macOS 26 and 27 VMs (display findings F1 to F5, fixed in `7b24776a`), and a Phase 0 measurement in the same VMs showed the bug the guard addresses: two configurations run at once, and the first stops passing traffic while still shown as Connected. Those logs are not published.
- `2026-10-27-zipfoundation.md`: the review of the one new dependency before it was adopted.

Section numbers such as §7.2 refer to [`docs/native/DESIGN.md`](../native/DESIGN.md).

An AI review is not a human security audit. If you find something these passes missed, please report it: security
issues through GitHub's private vulnerability reporting on this repository, everything else as an issue.
