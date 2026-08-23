#!/bin/bash
# Assertions shared by every suite. Sourced, never run on its own.
#
# Each suite keeps its own PASS/FAIL and prints its own total; the runner in
# tests.sh adds them up. Counting in a subshell would lose them, so nothing
# here may be called from inside $( ).

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf "  \033[32mOK\033[0m   %s\n" "$1"; }
ko() {
  FAIL=$((FAIL + 1))
  printf "  \033[31mFAIL\033[0m %s\n     expected: %s\n     got:      %s\n" "$1" "$2" "$3"
}

has() {   # $1=name  $2=haystack  $3=needle
  if echo "$2" | grep -qF -- "$3"; then ok "$1"
  else ko "$1" "contains '$3'" "$(echo "$2" | head -3 | tr '\n' ' ')"; fi
}

lacks() {
  if echo "$2" | grep -qF -- "$3"; then
    ko "$1" "WITHOUT '$3'" "$(echo "$2" | head -3 | tr '\n' ' ')"
  else ok "$1"; fi
}

equals() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "$3" "$2"; fi; }

# Writes the tally where the runner can read it: a suite that exits non-zero
# still has to report what it managed to check.
report() {   # $1=suite name
  echo
  printf "  %s: %d passed, %d failed\n" "$1" "$PASS" "$FAIL"
  [ -n "${TALLY_FILE:-}" ] && printf '%s %s\n' "$PASS" "$FAIL" >> "$TALLY_FILE"
  [ "$FAIL" -eq 0 ]
}

section() { echo; echo "── $1 $(printf '%.0s─' $(seq 1 $((50 - ${#1}))))"; }
