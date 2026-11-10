#!/bin/zsh
# UI review loop: render (or reuse) the screenshots, build the package, start the local server, open the browser.
#   review.sh              render EN + DE, build ~/Code/lockplus-build/ux-review/, serve, open
#   review.sh --no-render  reuse native/Tools/ui/Screenshots/*.png
# Comments are saved by serve.py to docs/native/ux-review/comments.json (+ COMMENTS.md). See README.md.
set -euo pipefail
cd "${0:A:h}"
source ../../lib/paths.sh
OUT="$LP_BUILD_ROOT/ux-review"
PORT=8765
if [[ "${1:-}" != --no-render ]]; then
  ../render-screenshots.sh > /dev/null
  ../render-screenshots.sh --de > /dev/null
fi
mkdir -p "$OUT"
python3 -I build_package.py ../Screenshots "$OUT"
URL=""
if curl -fsS "http://127.0.0.1:$PORT/comments" > /dev/null 2>&1; then
  URL="http://127.0.0.1:$PORT/"                       # already running: it serves the refreshed directory
else
  nohup python3 -I serve.py "$OUT" $PORT > "$OUT/.server.log" 2>&1 &
  for i in {1..50}; do [[ -s "$OUT/.server.log" ]] && break; sleep 0.1; done
  URL="$(head -1 "$OUT/.server.log")"
fi
echo "$URL"
open "$URL"
