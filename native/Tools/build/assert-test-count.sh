#!/bin/zsh
# Fails when an .xcresult ran no tests (a test plan that silently selects nothing passes xcodebuild with exit 0).
# Usage: assert-test-count.sh <result.xcresult> [minimum=1]
set -euo pipefail
R=${1:?usage: assert-test-count.sh <result.xcresult> [minimum]}; MIN=${2:-1}
[[ -d "$R" ]] || { print -u2 "FAIL: no result bundle at $R"; exit 1; }
S=$(xcrun xcresulttool get test-results summary --path "$R" --compact)
total=$(jq -r '.totalTestCount // 0' <<<"$S"); failed=$(jq -r '.failedTests // 0' <<<"$S")
(( total >= MIN )) || { print -u2 "FAIL: $R ran $total tests (< $MIN)"; exit 1; }
(( failed == 0 )) || { print -u2 "FAIL: $R has $failed failed tests"; exit 1; }
print "$R: $total tests, 0 failed"
