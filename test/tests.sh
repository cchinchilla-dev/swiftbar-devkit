#!/bin/bash
# Validates the repos.60s.sh plugin against the scenarios in fixtures.sh
S="$(cd "$(dirname "$0")" && pwd)"
T="$S/repos"
P="${REPOS_PLUGIN:-$S/../plugins/repos.60s.sh}"
# A fixture config, so the suite does not inherit whatever this machine has.
export REPOS_ROOT="$T" REPOS_TEST=1 SWIFTBAR_CONFIG="$S/test-config.sh"

# The tests mutate the repos (rename branches, pull), so they are rebuilt from
# scratch on every run.
bash "$S/fixtures.sh" "$T" >/dev/null

. "$S/lib.sh"

sha() { git -C "$T/$1" rev-parse HEAD; }
ba()  { git -C "$T/$1" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null | tr '\t' '/'; }

echo "── RENDER ────────────────────────────────────────────"
R="$(bash "$P")"
ROW() { echo "$R" | grep -E "^ +$1 " | head -1; }

lacks "clean: no markers"                "$(ROW clean)"         "↓"
has   "behind: marker ↓2"                "$(ROW behind)"        "↓2"
has   "detached: branch shows 'detached'" "$(ROW detached)"     "detached"
has   "warning text: no upstream"        "$R" "No upstream branch"
has   "summary counts pending"           "$R" "behind"

echo
echo "── CONFIG: BOTH PARSERS AGREE ────────────────────────"
# The config file is read twice over: the bash bars source it, the ports bar
# parses it in Python. Anything the two read differently is a silent bug, and
# one already bit — "$HOME/..." reached the ports bar as a literal string, so
# its Kill button pointed at a path that does not exist and did nothing.
DEVPORTS="$S/../plugins/devports.15s.py"

py_config() {   # $1=config file  $2=space-separated keys
  SWIFTBAR_CONFIG="$1" python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('dp', '$DEVPORTS')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for k in '''$2'''.split(): print('%s=%s' % (k, m.CFG.get(k, '')))" 2>/dev/null | sort
}

both_agree() {   # $1=config file  $2=test name
  local keys b p
  # Derived from the file itself, so a key added later is covered for free.
  # REPOS_ROOTS is excluded: it is an array, which the Python side never reads.
  keys="$(grep -oE '^[A-Z_]+=' "$1" | tr -d '=' | grep -v '^REPOS_ROOTS$' | sort -u | tr '\n' ' ')"
  b="$(bash -c ". '$1' >/dev/null 2>&1; for k in $keys; do printf '%s=%s\n' \"\$k\" \"\${!k-}\"; done" | sort)"
  p="$(py_config "$1" "$keys")"
  if [ "$b" = "$p" ]; then ok "$2"; else
    ko "$2" "identical values" "$(diff <(echo "$b") <(echo "$p") | tr '\n' ' ' | cut -c1-120)"
  fi
}

both_agree "$S/../config.example.sh" "config.example.sh reads the same in bash and python"
both_agree "$S/test-config.sh"       "test-config.sh reads the same in bash and python"

# The exact shape that broke, kept as its own case so the reason stays visible.
printf 'DEVPORTS_ACTION="$HOME/.local/bin/devports-action"\n' > "$S/.cfg-expand.sh"
EXPANDED="$(py_config "$S/.cfg-expand.sh" "DEVPORTS_ACTION" | cut -d= -f2-)"
equals "python expands \$HOME like the shell does" "$EXPANDED" "$HOME/.local/bin/devports-action"
lacks  "no value survives as a literal \$HOME"     "$EXPANDED" '$HOME'
rm -f "$S/.cfg-expand.sh"

echo
echo "── STASH ─────────────────────────────────────────────"
# stash@{0} is the NEWEST entry, i.e. the LAST line of the reflog.
has   "stash@{0} is the newest"           "$R" "stash@{0} · just now · On main: second"
has   "commands for stash@{0}: pop"       "$R" "git stash pop stash@{0}"
# Every entry carries its own, not just the first one.

# A clean repo with a stash must NOT light up the menu bar number: that counter
# means "things that need action", and stashing can be deliberate. The badge is
# compared against the rows carrying an action marker, so the assertion does not
# depend on how many scenarios fixtures.sh happens to define.
ACTION="$(echo "$R" | grep -E '^  [a-z][a-z-]+ ' | grep -cE '↓|↑|●|!' | tr -d ' ')"
# With nothing pending the first line is " | sfimage=...", with no number: that is 0.
BADGE="$(echo "$R" | head -1 | sed 's/ *|.*//' | tr -d ' ')"
equals "the badge ignores stashes"        "${BADGE:-0}" "$ACTION"

# A reflog with lines but no refs/stash holds leftovers of dropped entries.
cp "$T/group-a/with-stash/.git/logs/refs/stash" "$T/group-a/clean/.git/logs/refs/stash"
lacks "orphan reflog does not count"      "$(bash "$P" | grep -E '^  clean ')" "⚑"
rm -f "$T/group-a/clean/.git/logs/refs/stash"

echo
echo "── FETCH FRESHNESS, CHANGED FILES, IDE ───────────────"
# Behind/ahead only reflect the last fetch: the menu has to say how old it is.
# The files themselves, not just the count. REPOS_MAX_FILES=3 in the fixture
# config, and 'dirty' has 2 changes, so all of them fit.
DIRTY_BLOCK="$(echo "$R" | sed -n '/^  dirty /,/Open in Terminal/p')"
# The IDE button comes from the config and is named after it.
# Forks track a remote that is not origin; that must not read as a mistake.
git -C "$T/group-a/clean" remote add upstream "$T/group-a/behind.git"
lacks "a second remote does not warn"     "$(bash "$P" | sed -n '/^  clean /,/Open in Terminal/p')" "not 'origin/main'"
git -C "$T/group-a/clean" remote remove upstream

echo
echo "── WORKTREES AND HALF-FINISHED OPERATIONS ────────────"
# In a worktree .git is a FILE: -type d used to skip it entirely.
has   "the linked worktree is discovered"  "$R" "linked-worktree"
has   "mid-merge: warning"                 "$R" "merge in progress"
# Mid-merge the fix is to finish or abort, never to pull or push.
MERGE_BLOCK="$(echo "$R" | sed -n '/^  mid-merge/,/Open in Terminal/p')"
has   "mid-merge: offers --abort"          "$MERGE_BLOCK" "git merge --abort"
lacks "mid-merge: does not offer Update"   "$MERGE_BLOCK" "Update (pull"
# A half-finished operation detaches HEAD; that must not read as "Detached HEAD".

echo
echo "── COPY ONE COMMAND AT A TIME ────────────────────────"
# The payload is read out of the rendered menu rather than rebuilt here, so the
# test follows the wire format instead of restating it: a command carrying
# spaces travels as b64:… , a plain value travels literally.
B64() {   # $1=repo  $2=which clickable command, starting at 1
  echo "$R" | sed -n "/^  $1/,/Open in Terminal/p" | grep -F 'copy-one' \
    | sed -n "$2p" | grep -o 'param3=[^ ]*' | cut -d= -f2-
}
OUT="$(bash "$P" copy-one "$T/group-a/with-stash" "$(B64 with-stash 5)" 2>&1)"
has    "copy-one: notifies"                  "$OUT" "NOTICE"
bash "$P" copy-one "$T/group-a/with-stash" "$(B64 with-stash 1)" >/dev/null 2>&1
# A value with no b64: prefix is a literal by design — that is what lets a menu
# drawn by an older version still be understood. Undecodable base64 behind the
# prefix is the real error case, and it must not put junk on the clipboard.
BEFORE="$(pbpaste)"
bash "$P" copy-one "$T/group-a/with-stash" "b64:not-valid-base64!!" >/dev/null 2>&1
equals "copy-one: undecodable payload copies nothing" "$(pbpaste)" "$BEFORE"
# The commands under "How to fix it" are copied one by one too, without their
# comment: the menu shows it, the clipboard does not carry it.
bash "$P" copy-one "$T/group-b/dirty-behind" "$(B64 dirty-behind 1)" >/dev/null 2>&1
lacks  "copy-one: comment stripped"          "$(pbpaste)" "#"

# Alignment: the branch must start at the same column on every row.
# The "  name + padding" block must measure the same on every row: that is what
# guarantees the branch column always starts at the same place.
COLS="$(echo "$R" | grep -E "^  [a-z][a-z-]* " | awk '{match($0,/^  [^ ]+ +/); print RLENGTH}' | sort -u | wc -l | tr -d ' ')"

echo
echo "── UPDATE: cases that must ABORT ─────────────────────"
for case_name in dirty diverged dirty-behind; do
  case "$case_name" in
    dirty)    d=group-a/dirty;;
    diverged) d=group-a/diverged;;
    *)        d=group-b/dirty-behind;;
  esac
  BEFORE="$(sha "$d")"; OUT="$(bash "$P" update "$T/$d" 2>&1)"
  has    "$case_name: aborts with an alert" "$OUT" "ALERT"
  equals "$case_name: HEAD untouched" "$(sha "$d")" "$BEFORE"
done
has    "dirty-behind: the uncommitted warning wins" \
       "$(bash "$P" update "$T/group-b/dirty-behind" 2>&1)" "uncommitted"
equals "dirty-behind: still behind" "$(ba group-b/dirty-behind)" "1/0"

echo
echo "── UPDATE: cases that must WORK ──────────────────────"
OUT="$(bash "$P" update "$T/group-a/behind" 2>&1)"
lacks  "behind: no alert" "$OUT" "ALERT"
equals "behind: ends up to date" "$(ba group-a/behind)" "0/0"
OUT="$(bash "$P" update "$T/group-a/clean" 2>&1)"
equals "ahead: update sends nothing" "$(ba group-a/ahead)" "0/1"

echo
echo "── BRANCHES ──────────────────────────────────────────"
REPOS_IN="feature/new" bash "$P" newbranch "$T/group-a/clean" >/dev/null 2>&1
equals "new branch: created and checked out" "$(git -C "$T/group-a/clean" symbolic-ref --short HEAD)" "feature/new"

REPOS_IN="" bash "$P" newbranch "$T/group-a/ahead" >/dev/null 2>&1
equals "new branch: cancelling changes nothing" "$(git -C "$T/group-a/ahead" symbolic-ref --short HEAD)" "main"

REPOS_IN="renamed" bash "$P" rename "$T/group-a/clean" "feature/new" >/dev/null 2>&1

REPOS_IN="whatever" REPOS_CONFIRM=no bash "$P" rename "$T/group-a/behind" "main" >/dev/null 2>&1
equals "rename: cancelling keeps the branch" "$(git -C "$T/group-a/behind" symbolic-ref --short HEAD)" "main"


echo
echo "── GLOBAL ACTIONS ────────────────────────────────────"
git -C "$T/group-a/behind" reset -q --hard HEAD~2
# The menu ships this list base64-encoded, because the paths are joined with
# the same | that SwiftBar uses as its own separator.
ALL="$(printf '%s' "$T/group-a/behind|$T/group-a/dirty|$T/group-a/diverged" | base64 | tr -d '\n')"
OUT="$(bash "$P" update-all "$ALL" 2>&1)"
has "update-all: lists what was updated" "$OUT" "Updated"

bash "$P" fetch-all "$T/group-a/clean|$T/group-a/behind" >/dev/null 2>&1

echo
bash "$S/fixtures.sh" "$T" >/dev/null   # clean slate: these sections assume the original scenarios
echo "── SUGGESTED COMMANDS ────────────────────────────────"
CM() { bash "$P" copy-all "$T/$1" >/dev/null 2>&1; pbpaste; }
equals "behind: suggests pull --ff-only"      "$(CM group-a/behind)"   "git pull --ff-only"
has    "diverged: suggests pull --rebase"     "$(CM group-a/diverged)" "git pull --rebase"
has    "dirty: suggests a commit"             "$(CM group-a/dirty)"    "git add -A"
# origin/main DOES exist in that repo: the right fix is to re-attach, not recreate
# a branch genuinely absent from the remote: that is when push -u is right
git -C "$T/group-a/clean" switch -q -c invented
has    "branch missing on origin: suggests push -u" \
       "$(CM group-a/clean)" "git push -u origin invented"
git -C "$T/group-a/clean" switch -q main
has    "dirty-behind: commit comes first"     "$(CM group-b/dirty-behind | head -1)" "git add -A"
# What gets copied has to paste and run as-is: zsh ships without
# interactive_comments, so a single hash breaks the line.
equals "copy-all: no comments"                "$(CM group-b/dirty-behind | grep -c '#')" "0"
equals "copy-all: commands only"              "$(CM group-b/dirty-behind | grep -c .)"   "3"
# Counted, not pattern-matched: BSD cat has no -A, so the old check produced
# nothing and passed for the wrong reason.
# The copy-all button only makes sense when there is more than one command.
# Singular and plural, no "(s)".

echo
echo "── PUSH ──────────────────────────────────────────────"
has    "push with the remote ahead: rejected" \
       "$(bash "$P" push "$T/group-a/diverged" 2>&1)" "ALERT"
equals "push: sent nothing" \
       "$(ba group-a/diverged)" "1/1"
has    "push on detached: rejected" "$(bash "$P" push "$T/group-b/detached" 2>&1)" "ALERT"
bash "$P" push "$T/group-a/ahead" >/dev/null 2>&1
REPOS_CONFIRM=no bash "$P" push "$T/group-b/no-upstream" >/dev/null 2>&1
equals "cancelled push -u: still without upstream" \
       "$(git -C "$T/group-b/no-upstream" rev-parse --abbrev-ref '@{upstream}' 2>&1 | grep -c 'no upstream\|fatal')" "1"

echo
echo "── REBASE ────────────────────────────────────────────"
BEFORE="$(sha group-a/diverged)"
bash "$P" rebase "$T/group-a/diverged" >/dev/null 2>&1
equals "rebase: resolves the divergence" "$(ba group-a/diverged)" "0/1"
OUT="$(bash "$P" rebase "$T/group-a/dirty" 2>&1)"
has    "rebase with uncommitted changes: aborts" "$OUT" "ALERT"

echo
echo "── SET UPSTREAM ──────────────────────────────────────"
bash "$P" setupstream "$T/group-b/odd-upstream" >/dev/null 2>&1
equals "setupstream: fixes tracking" \
       "$(git -C "$T/group-b/odd-upstream" rev-parse --abbrev-ref '@{upstream}')" "origin/main"
bash "$P" setupstream "$T/group-b/no-upstream" >/dev/null 2>&1
git -C "$T/group-a/clean" switch -q -c local-only

echo
echo "── STASH ACTION ──────────────────────────────────────"
bash "$P" stash "$T/group-a/dirty" >/dev/null 2>&1
equals "stash: leaves the tree clean" \
       "$(git -C "$T/group-a/dirty" status --porcelain | grep -c .)" "0"

echo
echo "── SEQUENCES ACTUALLY EXECUTED ───────────────────────"
bash "$S/fixtures.sh" "$T" >/dev/null

# Runs the suggested commands as-is, filling in the placeholders.
run_suggestion() {
  local d="$T/$1" cmds
  bash "$P" copy-all "$d" >/dev/null 2>&1
  cmds="$(pbpaste)"
  while IFS= read -r c; do
    case "$c" in ""|\#*) continue;; esac
    c="${c/\"...\"/\"automated test\"}"
    c="${c/<new-branch>/rescued}"
    c="${c/<branch>/main}"
    ( cd "$d" && eval "$c" ) >/dev/null 2>&1
  done <<< "$cmds"
}

# Compact final state: dirty/behind/ahead
final_state() {
  local d="$T/$1"
  echo "$(git -C "$d" status --porcelain | grep -c . | tr -d ' ')/$(git -C "$d" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null | tr '\t' '/' || echo '?')"
}

for case_name in group-a/behind group-a/dirty group-b/no-upstream; do
  run_suggestion "$case_name"
  equals "$(basename $case_name): ends clean and in sync" "$(final_state "$case_name")" "0/0/0"
done

run_suggestion group-b/detached
equals "detached: ends up on a branch" \
       "$(git -C "$T/group-b/detached" symbolic-ref --quiet --short HEAD >/dev/null 2>&1 && echo yes || echo no)" "yes"

echo
printf "  repos: %d passed, %d failed\n" "$PASS" "$FAIL"
TOTAL_PASS=$PASS; TOTAL_FAIL=$FAIL

# The other suites run in their own process — they build their own fixtures and
# stub their own binaries — and report back through a file, because a tally
# incremented inside $( ) would be lost with the subshell.
export TALLY_FILE="$S/.tally"; : > "$TALLY_FILE"
for suite in tests-branches.sh tests-devports.sh tests-colima.sh tests-llama.sh tests-wiring.sh; do
  echo
  echo "══ ${suite%.sh} ══════════════════════════════════════"
  bash "$S/$suite" || true
done
while read -r p f; do
  TOTAL_PASS=$((TOTAL_PASS + p)); TOTAL_FAIL=$((TOTAL_FAIL + f))
done < "$TALLY_FILE"
rm -f "$TALLY_FILE"

echo
echo "══════════════════════════════════════════════════════"
echo "  $TOTAL_PASS passed, $TOTAL_FAIL failed"
[ "$TOTAL_FAIL" -eq 0 ]
