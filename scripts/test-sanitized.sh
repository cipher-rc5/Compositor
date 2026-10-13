#!/bin/zsh
# The unit tests under Address Sanitizer and Undefined Behavior Sanitizer, for the C pixel kernels in
# Compositor/Rendering/*.c: an out-of-bounds read or write, a use after free, a signed overflow or a bad shift
# there stops the run with a report instead of passing silently. `just test-sanitized` runs it; so does the
# Sanitizers workflow (.github/workflows/sanitizers.yml), weekly and on pull requests touching the C sources.
#
# Several times slower than scripts/ci.sh, so it isn't part of that gate. Builds land in build/sanitize,
# apart from every other build, since sanitized objects can't be mixed with plain ones.
# Extra arguments go to xcodebuild, e.g. ./scripts/test-sanitized.sh -only-testing:CompositorTests/BrushTests
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$PROJECT_DIR/build/sanitize"
RESULT="$DERIVED/tests.xcresult"
LOG="$DERIVED/test.log"
mkdir -p "$DERIVED"
cd "$PROJECT_DIR"
rm -rf "$RESULT"

only=(-only-testing:CompositorTests)
[[ " $* " == *" -only-testing:"* ]] && only=()

# UBSan only logs by default; halting turns each report into a test failure. TEST_RUNNER_ forwards a variable
# into the test host process.
export TEST_RUNNER_UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"
export TEST_RUNNER_ASAN_OPTIONS="halt_on_error=1:detect_stack_use_after_return=1"

common=(-project Compositor.xcodeproj -scheme Compositor -configuration Debug
        -destination 'platform=macOS' -derivedDataPath "$DERIVED"
        CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
        -enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES)

echo "==> Running unit tests with Address and Undefined Behavior Sanitizers"
result=0
xcodebuild test "${common[@]}" -resultBundlePath "$RESULT" "${only[@]}" "$@" >"$LOG" 2>&1 || result=$?

# How many tests the run should have covered. A crash or a time limit can stop the test host part way, and the result
# bundle then only counts what ran, so its own total can't tell a short run from a full one.
ENUMERATION="$DERIVED/tests.json"
rm -f "$ENUMERATION"
expected=0
if xcodebuild test-without-building "${common[@]}" "${only[@]}" "$@" -enumerate-tests -test-enumeration-style flat \
     -test-enumeration-format json -test-enumeration-output-path "$ENUMERATION" >/dev/null 2>&1; then
  expected=$(/usr/bin/python3 -c 'import json, sys
print(sum(len(v["enabledTests"]) for v in json.load(open(sys.argv[1]))["values"]))' "$ENUMERATION" 2>/dev/null || echo 0)
fi

# Failures, counts, and whether every expected test ran. Exits 1 when the run was cut short.
summarize() {
  xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null | /usr/bin/python3 -c 'import json, sys
d = json.load(sys.stdin)
expected = int(sys.argv[1])
for f in d["testFailures"]: print("FAILED", f["testIdentifierString"], "\n   ", f["failureText"].replace("\n", "\n    "))
ran = d["passedTests"] + d["failedTests"] + d["skippedTests"] + d["expectedFailures"]
print("==>", d["passedTests"], "passed,", d["failedTests"], "failed,", d["skippedTests"], "skipped;", ran, "of",
      expected if expected else "an unknown number of", "tests ran")
if expected and ran < expected:
    print("==> The run was cut short:", expected - ran, "tests never ran (a crash, a hang or a time limit stopped it)")
    sys.exit(1)' "$expected"
}

# A sanitizer report names the file and line; show those first, whatever xcodebuild's exit status.
reports=$(grep -E 'ERROR: AddressSanitizer|runtime error:|SUMMARY: (Address|UndefinedBehavior)Sanitizer' "$LOG" | sort -u || true)
if [[ -n "$reports" ]]; then
  print -r -- "$reports"
  summarize || true
  echo "==> Sanitizer reports found (full log: $LOG)"
  exit 1
fi
if (( result != 0 )); then
  if grep -q '\*\* TEST BUILD FAILED \*\*\|\*\* BUILD FAILED \*\*' "$LOG"; then
    # The build never finished, so no test ran: show why, not a test count.
    grep -E ': error: ' "$LOG" | sort -u \
      || grep -E -A3 '^Stack dump:|While (evaluating|emitting)|^The following build commands failed:' "$LOG" | cut -c1-300 \
      || tail -40 "$LOG"
    echo "==> The sanitized build failed (full log: $LOG)"
    exit 1
  fi
  if [[ -d "$RESULT" ]]; then summarize || true; else tail -40 "$LOG"; fi
  echo "==> Sanitized tests failed (full log: $LOG)"
  exit 1
fi
if ! summarize; then
  echo "==> Sanitized tests failed (full log: $LOG)"
  exit 1
fi
echo "==> Sanitized tests passed"
