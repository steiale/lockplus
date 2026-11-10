#!/bin/zsh
# Syncs App/UI/Localizable.xcstrings (English source; the app's one table) from the .stringsdata the compiler emits
# for every App/ source, App root included (SWIFT_EMIT_LOC_STRINGS=YES).
# Usage: sync-strings.sh <DerivedData dir of a build of the LockPlus target>
set -euo pipefail
NATIVE="${0:A:h:h:h}"
DD="${1:?usage: sync-strings.sh <DerivedData>}"
CATALOG="$NATIVE/App/UI/Localizable.xcstrings"
UI_FILES=(${(f)"$(cd "$NATIVE/App" && find . -name '*.swift' -exec basename {} .swift \;)"})
DATA=()
for f in $UI_FILES; do
  hit=$(find "$DD" \( -path "*LockPlus.build*" -o -path "*UIHarness.build*" \) -name "$f.stringsdata" -print -quit)
  [[ -n "$hit" ]] && DATA+=("$hit")
done
[[ -f "$CATALOG" ]] || printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n  },\n  "version" : "1.0"\n}\n' > "$CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "${DATA[@]}"
print "synced ${#DATA} files into $CATALOG ($(xcrun xcstringstool print "$CATALOG" | grep -c .) lines)"
