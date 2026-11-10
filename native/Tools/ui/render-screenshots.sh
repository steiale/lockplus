#!/bin/zsh
# Renders the review screenshots (opt-in ScreenshotTests suite) into native/Tools/ui/Screenshots/.
# Unsigned app-hosted run; needs a logged-in GUI session (offscreen windows). Not part of the Unit plan.
# DerivedData stays on the internal disk: a host app on an external volume blocks on a TCC removable-volume approval.
# Usage: render-screenshots.sh [--de]   (--de renders the German set, files *-de.png)
# -testLanguage doesn't reach a hosted unit-test app, so the German run edits a copy of the .xctestrun to launch
# the host with -AppleLanguages (de) and runs test-without-building.
set -euo pipefail
cd "${0:A:h:h:h}"
source Tools/lib/paths.sh
DD="${LP_UI_DD:-$LP_BUILD_ROOT/ui-screens}"
mkdir -p "$LP_BUILD_ROOT"
LOG="$LP_BUILD_ROOT/ui-screens.log"
while pgrep -f "^[^ ]*xcodebuild test" >/dev/null; do sleep 5; done   # two hosted runs of one bundle ID collide
fail() { grep -E '✘|error:' $LOG | sort -u | head -20; exit 1; }
xcodebuild build-for-testing -project LockPlus.xcodeproj -scheme LockPlus -testPlan Unit -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO > $LOG 2>&1 || fail
RUN=("$DD"/Build/Products/LockPlus_Unit_*.xctestrun(N[1]))
[[ -n "${RUN:-}" ]] || { echo "no xctestrun in $DD"; exit 1; }
if [[ "${1:-}" == --de ]]; then
  DE="${RUN:h}/German-${RUN:t}"           # outside the LockPlus_Unit_* glob
  python3 -I - "$RUN" "$DE" <<'PY'
import plistlib, sys
src, dst = sys.argv[1:3]
p = plistlib.load(open(src, "rb"))
def patch(t):
    if isinstance(t, dict):
        if "TestHostPath" in t or "TestBundlePath" in t:
            t["CommandLineArguments"] = list(t.get("CommandLineArguments", [])) + ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
            t["TestLanguage"], t["TestRegion"] = "de", "DE"
        for v in t.values(): patch(v)
    elif isinstance(t, list):
        for v in t: patch(v)
patch(p)
plistlib.dump(p, open(dst, "wb"))
PY
  RUN="$DE"
fi
CACHE="$HOME/Library/Caches/LockPlusUIScreenshots"
rm -f "$CACHE"/*.png(N)                                 # no stale renders from an earlier run
TEST_RUNNER_LP_RENDER_SCREENSHOTS=1 xcodebuild test-without-building -xctestrun "$RUN" -destination "platform=macOS,arch=arm64" \
  -only-testing:LockPlusTests/ScreenshotTests >> $LOG 2>&1 || fail
mkdir -p Tools/ui/Screenshots
if [[ "${1:-}" != --de ]]; then                          # the English run starts a fresh set (renamed surfaces leave no orphans)
  for f in Tools/ui/Screenshots/*.png(N); do [[ ${f:t} == harness-control-* ]] || rm -f "$f"; done
fi
cp "$CACHE"/*.png Tools/ui/Screenshots/
ls Tools/ui/Screenshots
# Render stamp for the review page: when, from which commit, which build number, and whether UI sources were uncommitted.
DIRTY=$(git status --porcelain -- App Tests Config Shared | wc -l | tr -d ' ')
python3 -I - "$(date '+%Y-%m-%d %H:%M:%S %z')" "$(git rev-parse --short HEAD)" \
  "$(sed -n 's/^LP_BUILD_NUMBER *= *//p' Config/Version.xcconfig)" "$DIRTY" > Tools/ui/Screenshots/render-stamp.json <<'PY'
import json, sys
when, commit, build, dirty = sys.argv[1:5]
print(json.dumps({"rendered": when, "commit": commit, "build": build, "uncommitted_ui_files": int(dirty)}, indent=1))
PY
