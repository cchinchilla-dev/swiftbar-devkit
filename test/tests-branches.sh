#!/bin/bash
# Branch listing, switching, deletion and the "only what needs attention"
# filter. Runs against its own fixtures so it cannot disturb the main suite.
S="$(cd "$(dirname "$0")" && pwd)"
. "$S/lib.sh"

T="$S/repos-branches"
P="${REPOS_PLUGIN:-$S/../plugins/repos.60s.sh}"
export REPOS_ROOT="$T" REPOS_TEST=1 SWIFTBAR_CONFIG="$S/test-config.sh"
bash "$S/fixtures-branches.sh" "$T" >/dev/null

B="$T/group-a/branches"
G="$T/group-a/gone"
branches_of() { git -C "$1" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' '; }
count_stash() { local f="$1/.git/logs/refs/stash"; [ -f "$f" ] && grep -c . "$f" || echo 0; }

R="$(bash "$P")"

section "BRANCH LIST"
has   "lists a local branch with a slash"   "$R" "------feature/login"
has   "marks the current one"               "$R" "------main  ✓"
# Plain names travel literally; only what would confuse SwiftBar is encoded.
has   "a plain branch travels unencoded"    "$R" "param3=release/2.0"

section "SWITCH"
# The bug this replaced: a slash meant "remote", so switching to feature/login
# created a brand new branch called login and left you on it.
BEFORE="$(branches_of "$B")"
bash "$P" switch "$B" "feature/login" >/dev/null 2>&1
equals "switches to the slashed local branch" \
       "$(git -C "$B" symbolic-ref --short HEAD)" "feature/login"
equals "creates no junk branch"             "$(branches_of "$B")" "$BEFORE"
bash "$P" switch "$B" "main" >/dev/null 2>&1

# A remote-only branch is the case where a local branch SHOULD be created:
# push it first, then drop the local copy so only the remote-tracking ref is
# left. Doing it the other way round leaves nothing to push.
git -C "$B" push -q origin release/2.0 2>/dev/null
git -C "$B" branch -q -D release/2.0 2>/dev/null
git -C "$B" fetch -q
OUT="$(bash "$P" switch "$B" "origin/release/2.0" 2>&1)"
equals "a remote-only branch gets a local one" \
       "$(git -C "$B" symbolic-ref --short HEAD)" "release/2.0"
bash "$P" switch "$B" "main" >/dev/null 2>&1

OUT="$(bash "$P" switch "$B" "no-such-branch" 2>&1)"

section "SWITCH REFUSES BEFORE IT STASHES"
# The guard used to sit BELOW the stash, so switching during a half-finished
# merge consumed the merge into a stash and then reported nothing was touched.
git -C "$B" rev-parse HEAD > "$B/.git/MERGE_HEAD"
echo dirty >> "$B/base.txt"
STASHES_BEFORE="$(count_stash "$B")"
OUT="$(REPOS_CONFIRM=yes bash "$P" switch "$B" "feature/login" 2>&1)"
has   "refuses while a merge is in progress"  "$OUT" "merge is in progress"
equals "the merge is still there" \
       "$([ -f "$B/.git/MERGE_HEAD" ] && echo yes || echo no)" "yes"
equals "no stash was created"                 "$(count_stash "$B")" "$STASHES_BEFORE"
rm -f "$B/.git/MERGE_HEAD"
git -C "$B" checkout -q -- base.txt

section "DELETE BRANCHES WHOSE UPSTREAM IS GONE"
BEFORE="$(branches_of "$G")"
OUT="$(REPOS_CONFIRM=no bash "$P" prunegone "$G" 2>&1)"
equals "cancelling deletes nothing"         "$(branches_of "$G")" "$BEFORE"

OUT="$(REPOS_CONFIRM=yes bash "$P" prunegone "$G" 2>&1)"
# ' merged-gone ' with its spaces: "unmerged-gone" contains "merged-gone" as a
# substring, and a plain grep would have called a live branch deleted.
equals "the merged one is gone" \
       "$(branches_of "$G" | grep -c ' merged-gone ' || true)" "0"
has   "the unmerged one is kept"            "$(branches_of "$G")" "unmerged-gone"
# The branch you are standing on is never a candidate, whatever its upstream.

OUT="$(REPOS_CONFIRM=yes bash "$P" prunegone "$T/group-a/untouched" 2>&1)"

section "ONLY WHAT NEEDS ATTENTION"
ALL="$(bash "$P")"
FILTERED="$(REPOS_ONLY_PENDING=1 bash "$P")"
lacks "with the filter, it does not"            "$FILTERED" "  untouched "
has   "and the count of hidden ones is shown"   "$FILTERED" "up to date, hidden"

section "OPEN ON THE REMOTE"
# https:// was being prepended before the host:path colon was rewritten, so
# sed's first match hit the scheme and produced https///host:group/repo.
export REPOS_TEST_OPEN="$T/.opened"; : > "$REPOS_TEST_OPEN"
bash "$P" browse "$T/group-a/ssh-remote" >/dev/null 2>&1
OUT="$(cat "$REPOS_TEST_OPEN")"
has   "rewrites an scp-style ssh remote"    "$OUT" "OPEN|https://github.com/acme/app/tree/main"

report "branches"
