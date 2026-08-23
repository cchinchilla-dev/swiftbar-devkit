#!/bin/bash
# Creates sample stashes in the fixture repos, to see the plugin's stash block
# with varied data.
#
# Usage:  bash stash-demo.sh [fixtures-directory]
#
# Only touches the fixtures directory. Never your real repositories.
# To undo:  bash fixtures.sh <fixtures-directory>
set -e

S="$(cd "$(dirname "$0")" && pwd)"
T="${1:-$S/repos}"
[ -d "$T" ] || {
  echo "$T does not exist"
  echo "Build the fixtures first:  bash $S/fixtures.sh $T"
  exit 1
}

g() { git -C "$1" -c commit.gpgsign=false -c user.email=t@t -c user.name=T "${@:2}"; }

# Stashes a change with a faked date. The reflog takes the committer date, so
# setting it shows off the age formatting without waiting days.
stash_one() {   # $1=relative repo  $2=message  $3=how many seconds ago
  local path="$T/$1" msg="$2" ago="${3:-0}" when
  [ -d "$path" ] || { echo "  ($1 missing, skipping)"; return 0; }
  when="$(( $(date +%s) - ago )) +0200"
  echo "$msg" >> "$path/base.txt"
  GIT_COMMITTER_DATE="$when" GIT_AUTHOR_DATE="$when" \
    g "$path" stash push -q -m "$msg"
}

# --- a single stash, in an otherwise clean repo
echo "ahead: 1 stash"
stash_one group-a/ahead "half-finished gateway tweak" 7200          # 2 h ago

# --- several, with different ages: covers minutes, hours and days.
# Pushed oldest first: stash@{0} is the last one pushed, so only in that order
# does it also end up being the newest.
echo "odd-upstream: 3 stashes"
stash_one group-b/odd-upstream "redis experiment"   $((86400 * 4))  # 4 d ago
stash_one group-b/odd-upstream "client refactor"    $((3600 * 5))   # 5 h ago
stash_one group-b/odd-upstream "quick check"        $((60 * 9))     # 9 min ago

# --- twelve, to see a long list scroll
echo "behind: 12 stashes"
for i in $(seq 12 -1 1); do
  stash_one group-a/behind "attempt number $i" $((86400 * i))
done

echo
echo "Done. Refresh SwiftBar to see it."
echo "Check that stash@{0} is the NEWEST one in each repo:"
echo "  git -C $T/group-b/odd-upstream stash list"
