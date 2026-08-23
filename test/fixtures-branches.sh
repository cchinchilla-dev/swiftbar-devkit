#!/bin/bash
# Repositories for the branch, prune and filter tests.
# Usage: fixtures-branches.sh <target-directory>
set -e
T="$1"; rm -rf "$T"; mkdir -p "$T/group-a"

g() { git -C "$1" -c commit.gpgsign=false -c user.email=t@t -c user.name=T "${@:2}"; }

new_repo() {
  local path="$T/group-a/$1"
  mkdir -p "$path"
  git init -q --bare "$path.git"
  git init -q -b main "$path"
  git -C "$path" config commit.gpgsign false
  g "$path" remote add origin "$path.git"
  echo base > "$path/base.txt"
  g "$path" add .
  g "$path" commit -qm initial
  g "$path" push -q -u origin main
}

commit_on() {   # $1=repo  $2=branch  $3=file
  local path="$T/group-a/$1"
  g "$path" switch -q -c "$2"
  echo x > "$path/$3"
  g "$path" add .
  g "$path" commit -qm "$3"
}

# ---- branches: a slash in the name is the ordinary case, not the exotic one.
# Treating it as "must be a remote" is what used to create a junk branch named
# after the last segment.
new_repo branches
commit_on branches feature/login login.txt
g "$T/group-a/branches" push -q -u origin feature/login
commit_on branches release/2.0 rel.txt
g "$T/group-a/branches" switch -q main

# ---- gone: two branches whose upstream was deleted on the remote. One is
# merged into main and can go; the other holds a commit that is nowhere else
# and must be refused by `branch -d`.
new_repo gone
commit_on gone merged-gone m.txt
g "$T/group-a/gone" push -q -u origin merged-gone
g "$T/group-a/gone" switch -q main
g "$T/group-a/gone" merge -q --no-ff -m "merge merged-gone" merged-gone
commit_on gone unmerged-gone u.txt
g "$T/group-a/gone" push -q -u origin unmerged-gone
g "$T/group-a/gone" switch -q main
# Delete both on the remote, then prune so the local refs read [gone].
g "$T/group-a/gone" push -q origin --delete merged-gone
g "$T/group-a/gone" push -q origin --delete unmerged-gone
g "$T/group-a/gone" fetch -q --prune

# ---- clean and pending: for the "only what needs attention" filter.
new_repo untouched
new_repo pending
echo change >> "$T/group-a/pending/base.txt"

# ---- ssh-remote: never fetched from, it only has to carry the URL shape that
# "Open on the remote" has to rewrite.
new_repo ssh-remote
g "$T/group-a/ssh-remote" remote set-url origin "git@github.com:acme/app.git"
