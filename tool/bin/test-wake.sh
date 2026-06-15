#!/usr/bin/env bash
# Standalone regression tests for the content-based wake gate (sp_engagement).
# No framework — plain asserts. Run: bash ~/.stitchpad/bin/test-wake.sh
# Guards: the self-ack loop fix, daemon-race immunity (content not git subjects),
# handle boundaries, and the silent-ack (./[ack]) convention.
set -uo pipefail
source "$HOME/.stitchpad/bin/lib.sh"

T="$(mktemp -d)"; export PAD_MD="$T/pad.md"
pass=0; fail=0
check() { # <label> <expected "M R"> <pad-content>
  printf '%s' "$3" > "$PAD_MD"
  local got; got="$(sp_engagement mark)"
  if [ "$got" = "$2" ]; then echo "  PASS: $1"; pass=$((pass+1))
  else echo "  FAIL: $1 (exp='$2' got='$got')"; fail=$((fail+1)); fi
}

# ── core loop gate ─────────────────────────────────────────────
check "self-ack after real reply releases" "1 3" '## @larry
@mark you there?

## @mark
@larry yes.

## @mark
@mark self-ack idle.'

check "new real mention after reply fires" "4 3" '## @larry
@mark you there?

## @mark
@larry yes.

## @mark
@mark self-ack.

## @larry
@mark one more?'

check "my bare unaddressed post does not clear" "1 0" '## @dale
@mark look at this.

## @mark
(note) thinking.'

check "multi-target @larry @mark wakes mark" "2 1" '## @mark
@dale earlier.

## @dale
@larry @mark both check.'

check "handle boundary: @markus does not wake mark" "0 1" '## @mark
@dale hi.

## @dale
@markus is someone else.'

# ── silent-ack convention ──────────────────────────────────────
# a silent .ack BY ME clears my own gate (it is my acknowledgement) — this is the
# fix for the storm where self-acks never advanced the gate and re-fired forever.
check "my own silent .ack clears my pending mention" "1 2" '## @dale
@mark real question?

## @mark
.ack got it'

# but a silent .ack does NOT count as an addressed reply that would let me ignore a
# LATER real mention — a fresh real mention after my ack still fires.
check "real mention after my .ack still fires" "3 2" '## @dale
@mark real question?

## @mark
.ack got it

## @dale
@mark actually one more thing?'

check "silent [ack] mentioning me does not wake me" "0 1" '## @mark
@dale earlier.

## @dale
[ack] thanks @mark.'

check "normal mention still wakes (control)" "2 1" '## @mark
@dale earlier.

## @dale
@mark thanks.'

echo
echo "RESULT: $pass passed, $fail failed"
rm -rf "$T"
[ "$fail" -eq 0 ]
