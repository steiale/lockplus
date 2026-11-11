# Codex review, round 9: the round 8 fixes `f3837f8e` and `175a8999`

Reviewed: the round 8 fixes `f3837f8e` and `175a8999`. OpenAI Codex (GPT-6-Astra, max reasoning effort), read-only; final message as written. HEAD hashes quoted inside the report are those of a scratch checkout.

**HIGH 1 — Forged rollback records bypass metadata replay protection. Introduced in 2.0.1.**

[ProfilesStore.swift:386](native/App/Stores/ProfilesStore.swift:386), [AppSettings.swift:174](native/App/Model/AppSettings.swift:174)

Same-user, non-admin malware can retain authentic metadata at revision `r` with the kill switch disabled. After the user enables it at `r+1`, the malware restores the old file and sets `pendingRollbacks[profileID] = r` in unsigned `settings.json`.

At the next idle launch, `rollbackPending` exempts that file from replay detection. `managerIsBehind` then causes the app to save its old, weaker flags back into NE. This permanently disables the kill switch without forging an HMAC or obtaining permission to write NE preferences. It defeats the documented same-user tampering boundary.

**Fix:** Store rollback authorization in protected, non-replayable storage, bound to the exact transaction and metadata/payload revisions. Editable settings must never authorize a security-policy downgrade.

**Tests:** The replay test calls `isReplay` directly, bypassing this exception; the rollback tests trust the record. Add a full load test with authentic older metadata and a forged rollback record.

**MEDIUM 2 — Automatic recovery can still stop a later kill-switch session after waiting for a network. Pre-existing in 2.0.0; round-7 M1 remains incomplete.**

[ConnectionStore.swift:1257](native/App/Stores/ConnectionStore.swift:1257), [ConnectionStore.swift:810](native/App/Stores/ConnectionStore.swift:810)

Split’s failed start is re-provisioned successfully while the network is unavailable. `startNow(automatic: true)` enters `waitForNetwork` before recording its automatic origin. The later offline exit from `runStart` loses that origin too.

When the network returns, Work’s kill-switch session starts through on-demand or `scutil`. The waiting recovery resumes through `beginStart`, which calls `beginSwitch` and stops Work. Split can then connect without the kill switch. The direct automatic-start safeguard is never consulted.

**Fix:** Carry the recovery origin and attempt identity in `Pending` through every wait/resume transition. A resumed automatic retry must abandon itself when another session is busy.

**Tests:** The current recovery test covers another session already active when provisioning finishes. Add network loss, automatic recovery entering the wait, Work starting, and network-wait resumption; assert Work is never stopped.

**MEDIUM 3 — One incomplete manager reload destroys legitimate rollback recovery. Introduced in 2.0.1.**

[ProfilesStore.swift:229](native/App/Stores/ProfilesStore.swift:229)

A failed metadata update leaves a recorded rollback: metadata is at `r`, manager at `r+1`, and another session prevents repair. If one preferences reload temporarily omits that manager, the cleanup predicate returns `false` and durably deletes its rollback record.

When the manager reappears, `load()` treats the legitimate metadata as a replay and quarantines the profile. A transient omission therefore becomes persistent loss of the profile’s availability. The manager layer already explicitly accommodates incomplete reloads.

**Fix:** Clear the record only after positively confirming rollback completion, a superseding metadata commit, or deletion. An absent manager in one snapshot is insufficient evidence.

**Tests:** Combine the existing skipped-rollback and partial-reload scenarios. Keep the record through the missing snapshot and verify that the returning manager causes repair, not quarantine.

**LOW 4 — The generic freshness filter can hide a genuine 223 failure. Introduced in 2.0.1.**

[ConnectionStore.swift:1021](native/App/Stores/ConnectionStore.swift:1021)

A pending split start is preempted, recording 223 before the app receives its delayed `.connecting` status. If that delay exceeds one second, the generic filter clears `mapped` before the dedicated 30-second supersession check runs.

For a never-connected attempt, this can suppress the error, supersession notice and profile end note entirely. The corresponding exemption was added only for 222.

**Fix:** Route both guard errors through their dedicated freshness checks, without first applying the generic one-second filter.

**Tests:** Extend the existing “recorded two seconds before connecting” test to 223, including assertions for Diagnostics and `endNotes`.

The earlier lease routing, stale-start loop check, duplicate priority, current-flag refusal notice, 222 freshness exemption, shared throttle and latch seeding fixes remain intact. Round-7’s protection re-read, dynamic `behind`/revision checks, conditional mutations, shared pending-start predicate, drift reset, stray flag check, stale reservation handling and suite time limits are present; the recovery and rollback exceptions are above.

The documented no-stop/no-deinit enforcement gap remains unresolved; callback-driven unit tests cannot establish that NE still enforces protection. Cross-user `scutil` start/stop control already existed in 2.0.0.

Static review of `948b2ec`; no files changed and no tests executed.

---

**Fixes.** `d46a0cb2` (the rollback marker is in memory only, automatic retry carried through network waits, a vetoed preemptor releases its reservation).
