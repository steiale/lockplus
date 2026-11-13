#!/bin/zsh
# Fails when an .xcresult ran fewer tests than the plan's floor, skipped more than the plan allows, or had a failure (a
# test plan that silently selects nothing, drops a target, or turns tests into skips, passes xcodebuild with exit 0).
# Usage: assert-test-count.sh <result.xcresult> [minimum passed]
#   minimum defaults to the floor of the plan the bundle is named after (Unit.xcresult, UnitRelease.xcresult), else 1.
# The floors count PASSED tests (round 1, Sonnet L10: skipped ones don't count); SKIPS caps the opt-in skips
# (2.0.2: 39 screenshot tests + the live self-test probe in Unit, none in UnitRelease).
# Raise the floors when a release adds tests (2.0.2 round 4: Unit 836 passed, UnitRelease 10; round 5: 828, the user-stop
# notice and its 13 tests removed, 5 added; round 6: 838, 10 added; round 7: 844, 6 added;
# 200027: 852, 8 added: the headless runner, the embedded validator service, the editor opening through the bridge;
# 200027 RC review: 863, 11 added: the headless run's retry and idempotent hand-off, the temp-file sweep; 871, 8 added:
# the single status decision, targetInTransition and the out-of-time window; 872: fix-3 M1, the window removed, -2 tests +3).
set -euo pipefail
typeset -A FLOOR=(Unit 872 UnitRelease 10)
typeset -A SKIPS=(Unit 40 UnitRelease 0)
R=${1:?usage: assert-test-count.sh <result.xcresult> [minimum]}
PLAN=${R:t:r}
MIN=${2:-${FLOOR[$PLAN]:-1}}
MAXSKIP=${SKIPS[$PLAN]:-0}
[[ -d "$R" ]] || { print -u2 "FAIL: no result bundle at $R"; exit 1; }
S=$(xcrun xcresulttool get test-results summary --path "$R" --compact)
total=$(jq -r '.totalTestCount // 0' <<<"$S"); failed=$(jq -r '.failedTests // 0' <<<"$S")
passed=$(jq -r '.passedTests // 0' <<<"$S"); skipped=$(jq -r '.skippedTests // 0' <<<"$S")
(( passed >= MIN )) || { print -u2 "FAIL: $R passed $passed tests (< $MIN; $total run, $skipped skipped)"; exit 1; }
(( skipped <= MAXSKIP )) || { print -u2 "FAIL: $R skipped $skipped tests (> $MAXSKIP allowed for $PLAN)"; exit 1; }
(( failed == 0 )) || { print -u2 "FAIL: $R has $failed failed tests"; exit 1; }
print "$R: $passed passed (floor $MIN), $skipped skipped (max $MAXSKIP), $total total, 0 failed"
