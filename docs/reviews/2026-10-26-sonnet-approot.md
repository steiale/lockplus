# Sonnet app-root review (2026-10-26). Fix ALL.

## High
- **H1** Kill-switch / NE manager divergence: `updateMetadata` persists before `managers.save`, with no rollback. There's no flag/metaRev comparison at load or before start, the test comment at AppRootBehaviourTests:273 is false, and errors are mis-mapped (`ProfilesStore.swift:193-201`, `ConnectionStore:240`, `AppActions:173-175`).
- **H2** On-demand is turned off on every Disconnect and never re-enabled (§10.4 "until next network change"). Add an NWPathMonitor plus re-enable on manual-profile disconnect and at launch. `stop()` ignores a failed on-demand disable (`ConnectionStore.swift:276-285`, `AppEditorBackend:80-87`).
- **H3** NEManagerStore isn't serialized: `configurationStale`, `loadFromPreferences` clobbering edits, and reload replaces connection objects, so status gets stuck. Serialize all manager mutations (an actor or serial queue: reload, modify, save, one retry on stale). After every `loadAll`, diff statuses and replay them (`ManagerStore.swift:71-192`).
- **H4** "Resume Protection and Quit" quits before resuming; same for Disconnect+quit. Make them awaitable with `.terminateLater`, and clear `pausedState` after the restore (`AppActions:249,264`, `ConnectionStore:321-335`, `AppDelegate:78`).
- **H5** Uninstall after a failed deactivation still deletes data and trashes the app; wipe/remove failures are swallowed. The §4.4 residual sheet is missing (`AppActions:462-469`).
- **H6** The snapshot epoch check drops epoch-0 snapshots (latch and lastError are lost). Compare only when both epochs are nonzero and from the same session; clear on reconnect or session end (`ConnectionStore.swift:199`).

## Medium
- **M1** `create()` orphan/duplicate when the NE save fails (Import, migration).
- **M2** A failed `load()` makes reconcile remove every extension copy.
- **M3** No NE orphan/duplicate sweep:
  - `delete()` doesn't disable on-demand first and ignores a failed remove;
  - duplicate profileIDs and managers without a profileID aren't handled;
  - saves are allowed after a failed initial `loadAll` (creates duplicates).
- **M4** `replacePayload` writes the sealed file before the metadata, so a crash leaves the profile unreadable. Write `<uuid>.<rev>.sealed` and delete the old one after the commit.
- **M5** `answerAuth` failure is invisible; keep or re-show the prompt with an error.
- **M6** DNSVerifier: the TaskGroup race can't time out; use `withDeadline`. Verify whether `.invalid` is answered locally by mDNSResponder.
- **M7** Pause-while-paused loses the restore list; resume clears the state before restoring.
- **M8** `userStops` goes stale; the sticky fetchLastDisconnectError isn't cross-checked against `lastErrorAt`.
- **M9** The legacy-helper gate decides on stale data; refresh before connecting.
- **M10** LogsStore rescans 24 h every 5 s. ProcessRunner: a full pipe deadlocks, timeouts round down, and it blocks the cooperative pool.
- **M11** Import picks WG vs OVPN by extension; sniff the content.

## Low
- **L1** Export: failed writes are reported as success; overwrites and name collisions.
- **L2** `loadKeys` reentrancy can create two master keys; a wrong-size key is silently replaced.
- **L3** Uninstall deletes the master key while keeping profiles, which makes them undecryptable and later flagged as "tampered". Make the choice honest. `finishUninstall` doesn't unregister the resume agent.
- **L4** `launchSnapshotChecked` is set with a nil snapshot.
- **L5** `retryApproval` waits a fixed 1 s.
- **L6** `willBecomeDisabled` during our own deactivation sets `.disabledByUser`.
- **L7** `verifyPending` churns `metaRevision` and does an NE save on every hello.
- **L8** OnDemandPlan allows `stayConnected` on interactive or unsaved-password profiles (§8.4).
- **L9** Sparkle `installHandler()` is invoked synchronously; check against Sparkle docs. The error path fires on "no update".
- **L10** Credential read errors are swallowed, so later saves lose the passphrase and proxy creds.
- **L11** `setNotes`/`rename` re-save the NE manager on a live tunnel.
- **L12** HeadlessResume: a `loadAll` failure still clears the pause and unregisters.

## Tests to fix or add
- ResumeAgentTests:52-70 and :85-105 assert nothing real.
- AppRootFollowUpTests:31 is vacuous.
- UpdateTests:46 asserts nothing about the hook.
- AppSmokeTests:7-9 tests the helper, not the host.
- FakeVPNManager is synchronous: make it async/reentrant, add a stale-config error, and a fakeable remove failure.
- Add tests for H5, M1, M2, M4, M5.
- SystemExtensionManagerTests uses sleeps (flaky); add deactivation and guided-removal tests.

## Simplifications
- Use `withDeadline` in DNSVerifier and SystemExtensionManager.fetchProperties; add `withTaskCancellationHandler` around the OneShot waits.
- ProcessRunner: terminationHandler + continuation.
- UpdateCoordinator: remove the dead `terminationIntent` and `installHandlerBound`.
- Make the manager snapshot observable.
