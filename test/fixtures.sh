#!/bin/bash
# Builds test repos covering every state the plugin distinguishes.
# Usage: fixtures.sh <target-directory>
set -e
T="$1"; rm -rf "$T"; mkdir -p "$T"

g() { git -C "$1" -c commit.gpgsign=false -c user.email=t@t -c user.name=T "${@:2}"; }

# Creates a repo with its own remote and an initial commit.
new_repo() {
  local path="$T/$1"
  mkdir -p "$path"
  git init -q --bare "$path.git"
  git init -q -b main "$path"
  git -C "$path" config commit.gpgsign false   # unsigned: the plugin calls git without overrides
  g "$path" remote add origin "$path.git"
  echo base > "$path/base.txt"
  g "$path" add .
  g "$path" commit -qm initial
  g "$path" push -q -u origin main
}

# Adds a commit on the remote (simulates someone else pushing).
remote_advances() {
  local path="$T/$1" n="${2:-1}" clone="$T/.clone-$$"
  rm -rf "$clone"; git clone -q -b main "$path.git" "$clone"
  for i in $(seq 1 "$n"); do
    echo "r$i" > "$clone/remote$i.txt"
    g "$clone" add .; g "$clone" commit -qm "remote $i"
  done
  g "$clone" push -q origin main
  rm -rf "$clone"
  g "$path" fetch -q
}

# Adds local commits that were never pushed.
local_advances() {
  local path="$T/$1" n="${2:-1}"
  for i in $(seq 1 "$n"); do
    echo "l$i" > "$path/local$i.txt"
    g "$path" add .; g "$path" commit -qm "local $i"
  done
}

# ---------------------------------------------------------------- scenarios

new_repo group-a/clean                                  # up to date

new_repo group-a/behind;        remote_advances group-a/behind 2

new_repo group-a/ahead;         local_advances group-a/ahead 1

new_repo group-a/dirty
echo change >> "$T/group-a/dirty/base.txt"
echo new > "$T/group-a/dirty/untracked.txt"

new_repo group-a/diverged;      remote_advances group-a/diverged 1
local_advances group-a/diverged 1

new_repo group-b/dirty-behind;  remote_advances group-b/dirty-behind 1
echo change >> "$T/group-b/dirty-behind/base.txt"

new_repo group-b/no-upstream
g "$T/group-b/no-upstream" branch --unset-upstream main

new_repo group-b/odd-upstream
g "$T/group-b/odd-upstream" push -q origin main:other
g "$T/group-b/odd-upstream" fetch -q
g "$T/group-b/odd-upstream" branch -q --set-upstream-to=origin/other main

new_repo group-b/detached
g "$T/group-b/detached" checkout -q --detach HEAD

# Two stashed entries and a clean tree: checks that stashes show up even when
# nothing else is pending, and that stash@{0} is the newest one ('second').
new_repo group-a/with-stash
echo first >> "$T/group-a/with-stash/base.txt"
g "$T/group-a/with-stash" stash push -q -u -m first
echo second >> "$T/group-a/with-stash/base.txt"
g "$T/group-a/with-stash" stash push -q -u -m second

# A linked worktree: there .git is a FILE, not a directory, which the
# discovery used to miss entirely. It lands next to its parent as its own repo.
new_repo group-a/has-worktree
g "$T/group-a/has-worktree" worktree add -q "$T/group-a/linked-worktree" -b linked

# Half-finished merge. The plugin reads the marker file, so writing it directly
# keeps the fixture deterministic instead of staging a real conflict.
new_repo group-b/mid-merge
git -C "$T/group-b/mid-merge" rev-parse HEAD > "$T/group-b/mid-merge/.git/MERGE_HEAD"

echo "scenarios created in $T"
