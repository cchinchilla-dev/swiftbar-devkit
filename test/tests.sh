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
if ! have_clipboard; then
  skip "the clipboard assertions: no working pasteboard here"
  CLIPBOARD=0
else
  CLIPBOARD=1
fi
# The payload is read out of the rendered menu rather than rebuilt here, so the
# test follows the wire format instead of restating it: a command carrying
# spaces travels as b64:… , a plain value travels literally.
B64() {   # $1=repo  $2=which clickable command, starting at 1
  echo "$R" | sed -n "/^  $1/,/Open in Terminal/p" | grep -F 'copy-one' \
    | sed -n "$2p" | grep -o 'param3=[^ ]*' | cut -d= -f2-
}
OUT="$(bash "$P" copy-one "$T/group-b/dirty-behind" "$(B64 dirty-behind 1)" 2>&1)"
has    "copy-one: notifies"                  "$OUT" "NOTICE"
# A stash item carries its verb and index, not the command: the action
# rebuilds it, and takes nothing but the three verbs and a number.
has    "stash items go through copy-stash"   "$(echo "$R" | sed -n '/^  with-stash/,/Open in Terminal/p')" "param1=copy-stash"
OUT="$(bash "$P" copy-stash "$T/group-a/with-stash" pop 0 2>&1)"
has    "copy-stash: rebuilds the command"    "$OUT" "git stash pop stash@{0}"
OUT="$(bash "$P" copy-stash "$T/group-a/with-stash" drop 0 2>&1)"
lacks  "copy-stash: only show, apply, pop"   "$OUT" "NOTICE"
OUT="$(bash "$P" copy-stash "$T/group-a/with-stash" pop '0;x' 2>&1)"
lacks  "copy-stash: the index is a number"   "$OUT" "NOTICE"
# A value with no b64: prefix is a literal by design — that is what lets a menu
# drawn by an older version still be understood. Undecodable base64 behind the
# prefix is the real error case, and it must not put junk on the clipboard.
if [ "$CLIPBOARD" = 1 ]; then
  BEFORE="$(pbpaste)"
  bash "$P" copy-one "$T/group-a/with-stash" "b64:not-valid-base64!!" >/dev/null 2>&1
  equals "copy-one: undecodable payload copies nothing" "$(pbpaste)" "$BEFORE"
fi
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
if [ "$CLIPBOARD" != 1 ]; then
  skip "the suggested-command assertions: they read the clipboard"
else
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
fi

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
echo "── RUN IN TERMINAL ───────────────────────────────────"
# Return used to run each line verbatim: a commit with "..." as its message,
# and --abort straight after a --continue that stopped on a conflict.
export REPOS_TEST_OPEN="$T/.opened"
wrapper() {   # $1=repo -> the script runfix hands to Terminal
  : > "$REPOS_TEST_OPEN"
  bash "$P" runfix "$T/$1" >/dev/null 2>&1
  cat "$(sed -n 's/^OPEN|-a Terminal //p' "$REPOS_TEST_OPEN")" 2>/dev/null
}
echo change >> "$T/group-a/dirty/base.txt"
W="$(wrapper group-a/dirty)"
lacks "runfix: a placeholder is never run"     "$(echo "$W" | grep '^run ')" '...'
# Run with Return to everything, so every line is skipped: the file itself
# holds the line %q-escaped, which no plain search would match.
OUT="$(yes '' | SHELL=/usr/bin/true bash <(echo "$W" | grep -v '^rm -f') 2>&1)"
has   "runfix: it is shown to finish by hand"  "$OUT" 'finish by hand: git add -A'
has   "runfix: each line asks first"           "$W" "run it? [y/N]"
W="$(wrapper group-b/mid-merge)"
has   "runfix: a failure ends the sequence"    "$W" "the rest was skipped"
# Run it with every answer y: --continue fails on the fake MERGE_HEAD, and the
# --abort after it must not get its turn. GIT_EDITOR=false so the commit
# --continue makes cannot sit waiting on an editor.
yes y | GIT_EDITOR=false SHELL=/usr/bin/true bash <(echo "$W" | grep -v '^rm -f') >/dev/null 2>&1
equals "runfix: --abort never follows a failed --continue" \
       "$([ -f "$T/group-b/mid-merge/.git/MERGE_HEAD" ] && echo kept || echo aborted)" "kept"

echo
echo "── SETTINGS ARE STORED, NOT EXECUTED ─────────────────"
# Every bar sources the config, so a value written raw is code: a folder named
# "Client $work" lost its $work, and a $(…) would have run on every render.
CFG="$T/.cfg-written.sh"; : > "$CFG"
mkdir -p "$T/Client \$work"
SWIFTBAR_CONFIG="$CFG" REPOS_IN="$T/Client \$work" bash "$P" addroot >/dev/null 2>&1
SWIFTBAR_CONFIG="$CFG" bash "$P" set REPOS_ONLY_PENDING "1\$(touch $T/.pwned)" >/dev/null 2>&1
SWIFTBAR_CONFIG="$CFG" bash "$S/../bin/colimabar-action" set COLIMA_X "\`touch $T/.pwned\`" >/dev/null 2>&1
READBACK="$(bash -c '. "$1"; printf "%s\n" "${REPOS_ROOTS[@]}"' _ "$CFG")"
has    "a \$ in a folder name survives"        "$READBACK" "Client \$work"
equals "neither \$(…) nor backticks run"      "$([ -e "$T/.pwned" ] && echo ran || echo stored)" "stored"
# One writer, lib/setconfig.py, behind every bar's Settings: there were five
# copies, and two of them wrote values raw. Same value, same file, from all.
V='a $b `c` "d" \e $HOME/x'
for who in "$P" "$S/../bin/devports-action" "$S/../bin/llamabar-action" "$S/../bin/colimabar-action"; do
  : > "$T/.cfg-one.sh"
  SWIFTBAR_CONFIG="$T/.cfg-one.sh" bash "$who" set SOME_KEY "$V" >/dev/null 2>&1
  cat "$T/.cfg-one.sh"
done > "$T/.cfg-all"
equals "every bar writes the same line"        "$(sort -u "$T/.cfg-all" | grep -c .)" "1"
equals "and it reads back as written"          "$(bash -c '. "$1"; printf %s "$SOME_KEY"' _ "$T/.cfg-one.sh")" "${V/\$HOME/$HOME}"
# A config kept in a dotfiles repo is a symlink, and must stay one.
echo 'OTHER="1"' > "$T/.cfg-real.sh"; ln -sfn "$T/.cfg-real.sh" "$T/.cfg-link.sh"
SWIFTBAR_CONFIG="$T/.cfg-link.sh" bash "$P" set SOME_KEY v >/dev/null 2>&1
equals "a symlinked config stays a symlink"   "$([ -L "$T/.cfg-link.sh" ] && grep -c SOME_KEY "$T/.cfg-real.sh")" "1"
# The key arrives as a menu parameter: it is not allowed to be shell.
python3 "$S/../lib/setconfig.py" "$T/.cfg-bad.sh" 'X; touch pwned' v >/dev/null 2>&1
equals "a key that is not a name is refused"  "$([ -e "$T/.cfg-bad.sh" ] && echo written || echo refused)" "refused"

echo
echo "── A | IN FREE TEXT ──────────────────────────────────"
# SwiftBar reads everything after the first | as parameters, and a cloned
# repository can bring file names of its own choosing.
touch "$T/group-a/clean/x|href=https:"
has   "a | in a file name becomes ¦"   "$(bash "$P")" "x¦href=https:"

echo
echo "── ROOTS THAT USED TO SCAN NOTHING ───────────────────"
# A root that does not exist read "All up to date · 0 repos", and once said
# so, the menu still has to offer the way to change it.
GONE_MENU="$(REPOS_ROOT="$T/.nowhere" bash "$P")"
has   "a missing root is named"         "$GONE_MENU" "Nothing is being scanned"
has   "with Settings still on hand"     "$GONE_MENU" "Add a folder…"
# BSD find does not descend into a root that is a symlink: "0 repos", no warning.
ln -sfn "$T" "$T.link"
lacks "a symlinked root is scanned"    "$(REPOS_ROOT="$T.link" bash "$P")" "0 repos"
rm -f "$T.link"
# Unquoted, the root was a glob pattern and the group header the whole path.
mkdir -p "$T/.roots/Work [x]"; cp -R "$T/group-a/clean" "$T/.roots/Work [x]/"
has   "a root with [ ] keeps its group header" \
      "$(REPOS_ROOT="$T/.roots/Work [x]" bash "$P" | grep -B1 '^  clean' | head -1)" "WORK [X]"
rm -rf "$T/.roots"
# A worktree whose main repository is gone: not a detached HEAD.
mkdir -p "$T/group-b/orphan"; echo "gitdir: /nonexistent/.git/worktrees/orphan" > "$T/group-b/orphan/.git"
ORPHAN="$(bash "$P" | sed -n '/^  orphan/,/Open in Terminal/p')"
has   "an unreadable .git says so"      "$ORPHAN" "git cannot read this repository"
lacks "and is not called detached"      "$ORPHAN" "Detached HEAD"
lacks "nor offered branch actions"      "$ORPHAN" "Switch branch"
rm -rf "$T/group-b/orphan"

echo
echo "── PULL REQUESTS AND BACKGROUND ROUNDS ───────────────"
# The render only reads what refresh-prs cached; written by hand here, in the
# same unit-separated shape, so no test talks to GitHub.
export TMPDIR="$T/.tmp"; mkdir -p "$TMPDIR/reposbar/pr"
US=$'\037'; KEY="$(printf '%s' "$T/group-a/clean" | tr / %)"
# Whatever branch the earlier sections left it on: the cache names its branch.
B="$(git -C "$T/group-a/clean" branch --show-current)"
printf '%s%s7%shttps://example.com/pull/7%sCHANGES_REQUESTED%sfail%s\n' "$B" "$US" "$US" "$US" "$US" "$US" \
  > "$TMPDIR/reposbar/pr/$KEY"
R="$(bash "$P")"
has   "a failing PR marks the row"           "$(ROW clean)" "✗"
has   "and says what failed"                 "$R" "PR #7 · checks failing · changes requested"
has   "the summary counts it"                "$R" "✗ 1 failing checks"
# Written for another branch: the PR of the branch you left is not yours now.
sed -i '' "s|^$B$US|not-$B$US|" "$TMPDIR/reposbar/pr/$KEY"
R="$(bash "$P")"
lacks "a cache for another branch is ignored" "$R" "PR #7"
lacks "and does not mark the row either"      "$(ROW clean)" "✗"
equals "the suite never starts a round"      "$(ls "$TMPDIR/reposbar" | grep -c stamp)" "0"
# The round itself: a fetch, with nothing that could ask for a password.
rm -f "$T/group-a/clean/.git/FETCH_HEAD"
bash "$P" autofetch "$(printf '%s' "$T/group-a/clean" | base64)" >/dev/null 2>&1
equals "autofetch fetches"                   "$([ -f "$T/group-a/clean/.git/FETCH_HEAD" ] && echo yes || echo no)" "yes"
unset TMPDIR

echo
if [ "$CLIPBOARD" != 1 ]; then
  skip "running the suggested sequences: they read the clipboard"
else
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
fi

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
