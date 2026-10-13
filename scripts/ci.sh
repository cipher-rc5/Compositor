#!/bin/zsh
# The local CI gate: a clean build of the app and test targets with no warnings, then the unit tests.
# Runs before every push (see .githooks/pre-push; `just hooks` turns it on) and before release.sh archives.
#
# The UI tests aren't part of it: they need a logged-in desktop and Accessibility permission (see README).
# Builds land in build/ci, apart from `just build`'s output, and are signed ad hoc so no certificate is needed.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$PROJECT_DIR/build/ci"
LOG="$DERIVED/build.log"
RESULT="$DERIVED/tests.xcresult"
mkdir -p "$DERIVED"
cd "$PROJECT_DIR"

# Code coverage has to be on for the build as well as the run: it is compiled in.
common=(-project Compositor.xcodeproj -scheme Compositor -configuration Debug
        -destination 'platform=macOS' -derivedDataPath "$DERIVED"
        CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO -enableCodeCoverage YES)

echo "==> Building (clean, warnings are errors)"
# Clean, so every file compiles and reports its warnings, not just the ones that changed.
if ! xcodebuild clean build-for-testing "${common[@]}" \
     SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES >"$LOG" 2>&1; then
  grep -E ': (error|warning): ' "$LOG" | sort -u || tail -40 "$LOG"
  echo "==> Build failed (full log: $LOG)"
  exit 1
fi
# Some Swift concurrency diagnostics stay warnings even with the settings above, so check the log too.
# Only this project's sources count; Sparkle and Xcode's own tools report warnings of their own.
warnings=$(grep -E "^$PROJECT_DIR/(Compositor|Tests)/[^:]+:[0-9]+:[0-9]+: warning: " "$LOG" | sed "s|^$PROJECT_DIR/||" | sort -u || true)
if [[ -n "$warnings" ]]; then
  print -r -- "$warnings"
  echo "==> $(print -r -- "$warnings" | wc -l | tr -d ' ') warning(s); the build must be warning-free"
  exit 1
fi

echo "==> Running unit tests"
rm -rf "$RESULT"
if ! xcodebuild test-without-building "${common[@]}" -only-testing:CompositorTests \
     -resultBundlePath "$RESULT" >"$DERIVED/test.log" 2>&1; then
  xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null \
    | /usr/bin/python3 -c 'import json, sys
d = json.load(sys.stdin)
for f in d["testFailures"]: print("FAILED", f["testIdentifierString"], "\n   ", f["failureText"].replace("\n", "\n    "))
print(d["passedTests"], "passed,", d["failedTests"], "failed,", d["skippedTests"], "skipped")' \
    || tail -40 "$DERIVED/test.log"
  echo "==> Tests failed (full log: $DERIVED/test.log)"
  exit 1
fi
xcrun xcresulttool get test-results summary --path "$RESULT" \
  | /usr/bin/python3 -c 'import json, sys; d = json.load(sys.stdin); print("==>", d["passedTests"], "passed,", d["skippedTests"], "skipped")'
# Reported, not enforced: the number to watch is the app's, not the test bundles'.
xcrun xccov view --report --only-targets --json "$RESULT" 2>/dev/null \
  | /usr/bin/python3 -c 'import json, sys
for t in json.load(sys.stdin):
    if t["name"] == "Compositor.app":
        print("==> Line coverage of Compositor.app: %.1f%% (%d of %d lines)" % (100 * t["lineCoverage"], t["coveredLines"], t["executableLines"]))' \
  || echo "==> Line coverage unavailable (see xcrun xccov view --report $RESULT)"
echo "==> CI passed"
