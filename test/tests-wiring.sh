#!/bin/bash
# Every button in every bar is a `bash=` pointing at a script. If that path is
# wrong the click does nothing at all — SwiftBar runs it, the file is not there,
# and neither the menu nor the log says a word.
#
# That is exactly how three bars ended up with every action dead after a config
# was written with a temporary BIN_DIR: the menus looked perfect. So: render
# each bar and check that every target it names actually resolves.
S="$(cd "$(dirname "$0")" && pwd)"
. "$S/lib.sh"

REPO="$(cd "$S/.." && pwd)"
TMP="${TMPDIR:-/tmp}/wiring-tests.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

BARS=(repos.60s.sh devports.15s.py colima.15s.sh llama.5s.sh)

# A config pointing at this checkout's own scripts, so the test passes on a
# fresh clone where nothing has been installed into ~/.local/bin yet.
CFG="$TMP/config.sh"
cat > "$CFG" <<EOF
REPOS_DEPTH="1"
COLIMA_ACTION="$REPO/bin/colimabar-action"
DEVPORTS_ACTION="$REPO/bin/devports-action"
LLAMA_ACTION="$REPO/bin/llamabar-action"
EOF

# $1 = config file, $2 = plugin file. A `case` inside $( ) is a trap: the `)`
# closing a pattern also closes the command substitution.
render_with() {
  if [ "${2%.py}" != "$2" ]; then
    SWIFTBAR_CONFIG="$1" REPOS_ROOT="$TMP" python3 "$REPO/plugins/$2" 2>/dev/null
  else
    SWIFTBAR_CONFIG="$1" REPOS_ROOT="$TMP" bash "$REPO/plugins/$2" 2>/dev/null
  fi
}
render() { render_with "$CFG" "$1"; }

# Both spellings appear in the menus: quoted when the path may contain spaces,
# bare when it cannot. Missing one of them is how a broken target hides.
targets() { grep -oE 'bash=("[^"]*"|[^ ]+)' | sed 's/^bash=//; s/^"//; s/"$//'; }

section "EVERY BUTTON POINTS AT SOMETHING THAT EXISTS"
for bar in "${BARS[@]}"; do
  OUT="$(render "$bar")"
  BAD=""; SEEN=0
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    SEEN=$((SEEN + 1))
    [ -e "$path" ] || BAD="$BAD $path"
  done <<< "$(printf '%s' "$OUT" | targets | sort -u)"

  if [ -n "$BAD" ]; then
    ko "$bar: all targets resolve" "every bash= exists" "missing:$BAD"
  else
    ok "$bar: all $SEEN target(s) resolve"
  fi
done

section "EVERY BAR STILL OFFERS SOMETHING TO CLICK"
# A bar that stops emitting buttons entirely would pass the check above by
# having nothing to check, which is not the same as being wired correctly.
for bar in "${BARS[@]}"; do
  N="$(render "$bar" | targets | grep -c . || true)"
  if [ "${N:-0}" -gt 0 ]; then ok "$bar: emits $N button target(s)"
  else ko "$bar: emits at least one button" "one or more" "none"; fi
done

section "THE ACTION PATH COMES FROM THE CONFIG"
# The bars must use the configured path rather than a hardcoded one, or moving
# the scripts silently breaks every button.
for pair in "devports.15s.py:devports-action" \
            "colima.15s.sh:colimabar-action" \
            "llama.5s.sh:llamabar-action"; do
  bar="${pair%%:*}"; script="${pair##*:}"
  if render "$bar" | targets | grep -qF "$REPO/bin/$script"; then
    ok "$bar honours its *_ACTION key"
  else
    ko "$bar honours its *_ACTION key" "$REPO/bin/$script" \
       "$(render "$bar" | targets | sort -u | tr '\n' ' ')"
  fi
done

section "WITHOUT A CONFIG, THE DEFAULT IS ~/.local/bin"
# Existence cannot be asserted here — a fresh machine has not installed them
# yet — but the shape can, and a typo in the default is just as fatal.
EMPTY="$TMP/empty.sh"; : > "$EMPTY"
for pair in "devports.15s.py:devports-action" \
            "colima.15s.sh:colimabar-action" \
            "llama.5s.sh:llamabar-action"; do
  bar="${pair%%:*}"; script="${pair##*:}"
  OUT="$(render_with "$EMPTY" "$bar")"
  if printf '%s' "$OUT" | targets | grep -qF "$HOME/.local/bin/$script"; then
    ok "$bar defaults to ~/.local/bin/$script"
  else
    ko "$bar defaults to ~/.local/bin/$script" "$HOME/.local/bin/$script" \
       "$(printf '%s' "$OUT" | targets | sort -u | tr '\n' ' ')"
  fi
done

section "AND THE ACTION SCRIPTS ARE RUNNABLE"
# A path that resolves but is not executable fails the same silent way.
for script in colimabar-action devports-action llamabar-action; do
  if [ -x "$REPO/bin/$script" ]; then ok "$script is executable"
  else ko "$script is executable" "executable bit set" "not executable"; fi
done

report "wiring"
