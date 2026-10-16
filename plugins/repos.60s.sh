#!/bin/bash
# This script relies on bash array semantics. SwiftBar honours the shebang, but
# anyone running `zsh plugins/repos.60s.sh` by hand got a silently mangled menu.
[ -n "$ZSH_VERSION" ] && exec /bin/bash "$0" "$@"
# Character-aware padding needs a UTF-8 locale; SwiftBar does not set one.
[ -n "$LANG" ] || export LANG=en_US.UTF-8
#
# <swiftbar.title>Repos</swiftbar.title>
# <swiftbar.desc>Current branch and local state of every repository.</swiftbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

# Work in progress, shared as-is, with no warranty of any kind.
# Actions here change real state on this machine — see the README.

# /usr/local/bin matters on Intel Macs, where Homebrew lives there instead.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Paths live in the config file, never in here: this script is meant to be
# shareable as it stands. See config.example.sh for the format.
CONFIG="${SWIFTBAR_CONFIG:-$HOME/.config/swiftbar-devkit/config.sh}"
# The test suite passes these in the environment and must win over the config,
# so they are remembered before sourcing it.
ENV_ROOT="$REPOS_ROOT"; ENV_DEPTH="$REPOS_DEPTH"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

if [ "${#REPOS_ROOTS[@]}" -gt 0 ]; then
  ROOTS=("${REPOS_ROOTS[@]}")
else
  ROOTS=("$HOME/Projects")
fi
[ -n "$ENV_ROOT" ] && ROOTS=("$ENV_ROOT")

DEPTH="${ENV_DEPTH:-${REPOS_DEPTH:-4}}"   # how deep to search
IDE="${REPOS_IDE:-}"
IDE_CMD="${REPOS_IDE_CMD:-}"
FETCH_STALE=$(( ${REPOS_FETCH_STALE_HOURS:-24} * 3600 ))
MAX_FILES="${REPOS_MAX_FILES:-10}"
# Thirty repositories is roughly 1300 menu lines, and the healthy majority
# buries the handful that actually need attention.
ONLY_PENDING="${REPOS_ONLY_PENDING:-0}"
HIDDEN=0
# Background rounds, each off with 0: a fetch so behind/ahead stay honest
# without a click, and the pull request lookup, which talks to GitHub. Neither
# ever runs inside a render; the menu only reads what they left in CACHE.
AUTO_FETCH_MIN="${REPOS_AUTO_FETCH_MINUTES:-30}"
PR_MIN="${REPOS_PR_MINUTES:-5}"
case "$AUTO_FETCH_MIN" in ''|*[!0-9]*) AUTO_FETCH_MIN=0 ;; esac
case "$PR_MIN" in ''|*[!0-9]*) PR_MIN=0 ;; esac
CACHE="${TMPDIR:-/tmp}/reposbar"

# Directories that never hold a repository of yours. Two reasons to skip them:
# they are enormous, and package caches do contain real checkouts — uv keeps
# git sources under .cache/uv, which showed up in the menu as a detached repo
# called sdists-v9. Anything found in here is someone else's code.
PRUNE=(
  -name node_modules -o -name .venv -o -name venv -o -name vendor
  -o -name target -o -name .terraform
  -o -name .cache -o -name Caches -o -name .gradle -o -name .m2
  -o -name site-packages -o -name .tox -o -name .pytest_cache
  -o -name .mypy_cache -o -name .ruff_cache -o -name Pods
)
SELF="$0"
MONO="font=Menlo size=11"
# Read once. This was a fork per repo, and per stash entry, for a number that
# cannot meaningfully change inside a single render.
NOW="$(date +%s)"

# ---------------------------------------------------------------- helpers

# AppleScript is source code, and these strings carry git output and branch
# names. A single " or \ turns the script into a syntax error, and with stderr
# discarded the dialog simply never appears — while the action it was meant to
# report on has already run. Escape before embedding, always.
as_quote() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

# Error dialog carrying git's full output (notifications truncate it).
fail() {
  osascript >/dev/null 2>&1 <<AS
display alert "$(as_quote "$1")" message "$(as_quote "$2")" as critical buttons {"Close"} default button 1
AS
  exit 1
}

ok() {
  osascript -e "display notification \"$(as_quote "$2")\" with title \"$(as_quote "$1")\"" \
    >/dev/null 2>&1
}

# Informational summary (not an error): plain dialog for long text.
info() {
  osascript >/dev/null 2>&1 <<AS
display alert "$(as_quote "$1")" message "$(as_quote "$2")" buttons {"Close"} default button 1
AS
}

# Prompt for text. Returns empty if the user cancels.
ask() {
  osascript 2>/dev/null <<AS
try
  set r to display dialog "$(as_quote "$1")" default answer "$(as_quote "$2")" buttons {"Cancel", "OK"} default button 2
  return text returned of r
on error
  return ""
end try
AS
}

confirm() {
  osascript >/dev/null 2>&1 <<AS
display alert "$(as_quote "$1")" message "$(as_quote "$2")" buttons {"Cancel", "Continue"} default button 1 cancel button 1
AS
}

# Test mode: REPOS_TEST=1 swaps dialogs for stdout text so the logic can be
# checked without clicking buttons. REPOS_IN feeds ask(), and REPOS_CONFIRM=no
# simulates a cancel in confirm().
if [ -n "$REPOS_TEST" ]; then
  fail()    { echo "ALERT|$1|$2"; exit 1; }
  ok()      { echo "NOTICE|$1|$2"; }
  info()    { echo "INFO|$1|$2"; }
  ask()     { echo "$REPOS_IN"; }
  confirm() { [ "$REPOS_CONFIRM" = "no" ] && return 1; return 0; }
  # Otherwise checking what "Open on the remote" builds means launching a
  # browser, and checking the Terminal handoff means opening a window. Written
  # to a file rather than stdout: the call sites redirect stdout to /dev/null,
  # which is exactly where the assertion would have gone looking for it.
  open()    { echo "OPEN|$*" >> "${REPOS_TEST_OPEN:-/dev/null}"; }
fi

# Parameter expansion, not basename: this runs once per repo per render and a
# fork is three orders of magnitude more expensive than a string operation.
repo_name() { local p="${1%/}"; printf '%s' "${p##*/}"; }


plural() {   # $1=n  $2=singular  $3=plural
  [ "$1" -eq 1 ] && printf '%s %s' "$1" "$2" || printf '%s %s' "$1" "$3"
}

# Same wording as the stash ages, so the whole menu reads alike.
ago() {   # $1 = seconds
  local d="${1:-0}"
  if   [ "$d" -lt 60 ];    then echo "just now"
  elif [ "$d" -lt 3600 ];  then echo "$((d / 60)) min ago"
  elif [ "$d" -lt 86400 ]; then echo "$((d / 3600)) h ago"
  else                          echo "$((d / 86400)) d ago"
  fi
}

# Drops the comment from a command. zsh, the default shell on macOS, ships with
# interactive_comments off: when pasted, a '#' is not a comment and breaks the
# line. Returns empty if the line was only a comment.
strip_comment() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//'
}

# The checkout this script lives in. Installed it is a symlink, in ~/.swiftbar
# or ~/.local/bin, and what the scripts share stays in the repository's lib/.
kit_dir() {
  local s="$0" l
  while [ -L "$s" ]; do
    l="$(readlink "$s")"
    case "$l" in
      /*) s="$l" ;;
      *)  case "$s" in */*) s="${s%/*}/$l" ;; *) s="$l" ;; esac ;;
    esac
  done
  case "$s" in */*) s="${s%/*}" ;; *) s="." ;; esac
  (cd "$s/.." 2>/dev/null && pwd)
}

# Every write to config.sh goes through lib/setconfig.py, which escapes the
# value and replaces the file in one rename.
set_config() {   # $1=key, or key[] for the array  rest=value(s)
  local kit; kit="$(kit_dir)"
  [ -f "$kit/lib/setconfig.py" ] || fail "Settings" "lib/setconfig.py is not next to this script. Install with install.sh, which links the bars rather than copying them."
  python3 "$kit/lib/setconfig.py" "$CONFIG" "$@"
}

# Paths under the home directory are stored as $HOME/... so the file still
# works when handed to a teammate.
portable_path() { case "$1" in "$HOME"/*) echo "\$HOME/${1#$HOME/}" ;; *) echo "$1" ;; esac; }

# Sourcing the config expands $HOME, so writing the entries back verbatim would
# bake this machine's paths in. Every entry is folded back, label included.
write_roots() {
  local out=() r p lbl
  for r in "$@"; do
    p="${r%%|*}"; lbl=""; [ "$r" != "$p" ] && lbl="|${r#*|}"
    out+=("$(portable_path "$p")$lbl")
  done
  set_config "REPOS_ROOTS[]" "${out[@]}"
}
pretty_path()   { echo "${1/#$HOME/~}"; }

# SwiftBar splits a line on the first | . Git allows | in ref names, so any
# title built from one has to have it replaced or the whole item is lost.
safe() { printf '%s' "${1//|/¦}"; }

# Shell-quotes a value only when it needs it. Git forbids whitespace and
# control characters in a refname but allows ; & $ ( ) ` — and these strings
# become commands: copied to the clipboard, and written into the runfix
# wrapper to be run. A branch named main;something used to turn one suggested
# command into two. Ordinary names pass through so the menu stays readable.
shq() {
  case "$1" in
    ''|*[!A-Za-z0-9._/@=+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# printf's %-20s pads by bytes, so "Diseño" came out one column short of "Design".
# ${#s} is character based under a UTF-8 locale, so pad by hand.
pad() {
  local s="$1" w="$2" out="$1" i=${#1}
  while [ "$i" -lt "$w" ]; do out="$out "; i=$((i + 1)); done
  printf '%s' "$out"
}

# The JetBrains IDEs are one per language, so opening a Java service in PyCharm
# is simply wrong. Pick by what the project is, and only if that IDE is really
# installed; otherwise fall back to whatever REPOS_IDE says. VS Code and the
# like handle everything, so a configured non-JetBrains editor is left alone.
ide_for() {   # $1 = repo path
  case "$IDE" in
    PyCharm|"IntelliJ IDEA"|GoLand|WebStorm|PhpStorm|RubyMine) ;;
    *) echo "$IDE"; return ;;
  esac
  # A find over three levels of every repository, on every render, to answer a
  # question a handful of stat calls answers: it was the most expensive thing
  # the bar did that had nothing to do with git. Marker files sit either at the
  # root or one directory down — a repo whose code lives in ./code/ is the
  # common shape here — and globbing plus [ -f ] forks nothing at all.
  local want="" found="" d f
  for d in "$1" "$1"/*/; do
    [ -d "$d" ] || continue
    for f in pom.xml build.gradle build.gradle.kts settings.gradle settings.gradle.kts \
             go.mod pyproject.toml setup.py requirements.txt composer.json Gemfile package.json; do
      [ -f "$d/$f" ] && found="$found $f"
    done
  done
  # Walk deeper when the shallow look found nothing, and also when all it
  # found was package.json — that one sits beside almost anything, so a pom.xml
  # two levels down should still win and pick IntelliJ over WebStorm.
  if [ -z "$found" ] || [ "$found" = " package.json" ]; then
    found="$(find "$1" -maxdepth 3 \( "${PRUNE[@]}" \) -prune -o \
      \( -name pom.xml -o -name 'build.gradle*' -o -name 'settings.gradle*' -o -name go.mod \
         -o -name pyproject.toml -o -name setup.py -o -name requirements.txt \
         -o -name composer.json -o -name Gemfile -o -name package.json \) -print 2>/dev/null)"
  fi
  # Order matters: package.json turns up beside almost anything, so it decides
  # only when nothing more specific did.
  case "$found" in
    *pom.xml*|*build.gradle*|*settings.gradle*) want="IntelliJ IDEA" ;;
    *go.mod*)                                   want="GoLand" ;;
    *pyproject.toml*|*setup.py*|*requirements.txt*) want="PyCharm" ;;
    *composer.json*)                            want="PhpStorm" ;;
    *Gemfile*)                                  want="RubyMine" ;;
    *package.json*)                             want="WebStorm" ;;
  esac
  if [ -n "$want" ] && [ -d "/Applications/$want.app" ]; then echo "$want"; else echo "$IDE"; fi
}

# Commands travel base64-encoded, so neither the quotes in -m "..." nor the &&
# break SwiftBar's parameter parsing.
b64()   { printf '%s' "$1" | base64 | tr -d '\n'; }
unb64() { printf '%s' "$1" | base64 -D 2>/dev/null || printf '%s' "$1" | base64 -d 2>/dev/null; }

# Values travelling in param3 used to be base64 encoded unconditionally. That
# is three processes per menu item, and with a few hundred branches on screen
# it was the single most expensive thing the plugin did — to protect against
# characters that a branch name almost never contains.
#
# So: encode only what actually needs it, and mark it. A value with a b64:
# prefix is encoded, anything else is literal. enc/dec assign to a global
# instead of echoing, because $(…) forks a subshell and that was half the point.
#
# Anything that could confuse SwiftBar's own parser counts as unsafe: | splits
# the line, spaces split the parameters, and " and \ end up inside a quoted
# bash= argument.
# $'' quoting, not $(printf …): command substitution strips trailing newlines,
# so NL came out empty, the pattern *""* matched every value on earth and the
# encoding stayed unconditional — the exact cost this is here to avoid.
TAB=$'\t'; NL=$'\n'
enc() {   # $1 = value -> ENC
  case "$1" in
    *'|'*|*'"'*|*'\'*|*' '*|*"$TAB"*|*"$NL"*|b64:*)
      ENC="b64:$(b64 "$1")" ;;
    *) ENC="$1" ;;
  esac
}
dec() {   # $1 = value -> DEC
  case "$1" in
    b64:*) DEC="$(unb64 "${1#b64:}")" ;;
    *)     DEC="$1" ;;
  esac
}

# A background round is due when its stamp is missing or older than $2
# minutes. The stamp is touched as the round starts, so the next render, a
# minute later, does not start the same one again while it is still running.
due() {   # $1=stamp name  $2=minutes
  local s="$CACHE/$1.stamp"
  [ -n "$(find "$s" -mmin -"$2" 2>/dev/null)" ] && return 1
  mkdir -p "$CACHE" && touch "$s"
}

# Redraws this bar once a background round has something new to show.
redraw() { local n="${SELF##*/}"; open -g "swiftbar://refreshplugin?name=${n%%.*}" >/dev/null 2>&1; }

# The open pull request for a repo's branch, as refresh-prs cached it. Unit
# separated, not tab: tab is whitespace to read, and an empty review decision
# would have shifted every field after it. A cache written for another branch
# is ignored, so switching does not show the old branch's PR for minutes.
read_pr() {   # $1=repo  $2=branch -> PR_N PR_URL PR_REVIEW PR_CI PR_DRAFT
  PR_N=""; PR_URL=""; PR_REVIEW=""; PR_CI=""; PR_DRAFT=""
  local f="$CACHE/pr/${1//\//%}" head=""
  [ "$PR_MIN" -gt 0 ] && [ -n "$2" ] && [ -s "$f" ] || return 0
  IFS=$'\037' read -r head PR_N PR_URL PR_REVIEW PR_CI PR_DRAFT < "$f"
  # Every field, not just the number: a leftover "fail" marked the row of a
  # branch whose PR this is not.
  [ "$head" = "$2" ] || { PR_N=""; PR_URL=""; PR_REVIEW=""; PR_CI=""; PR_DRAFT=""; }
}

# Reads a repo's state into globals.
read_state() {
  local R="$1"

  # Branch, upstream, ahead/behind and the working tree all come out of one
  # call. This used to be four separate ones — symbolic-ref, rev-parse
  # @{upstream}, status and rev-list — per repo, on every render.
  local ST; ST="$(git -C "$R" status --porcelain=v2 --branch 2>/dev/null)"

  BRANCH=""; UP=""; BEHIND=0; AHEAD=0; UPGONE=""; DIRTY=0; CONFLICTS=0
  local HDR="" AB="" line ab
  while IFS= read -r line; do
    case "$line" in
      '# branch.head '*)
        HDR=1
        BRANCH="${line#\# branch.head }"
        # v2 writes a detached HEAD as the literal (detached); the rest of the
        # plugin decides "detached" by BRANCH being empty.
        [ "$BRANCH" = "(detached)" ] && BRANCH="" ;;
      '# branch.upstream '*) UP="${line#\# branch.upstream }" ;;
      '# branch.ab '*)
        AB=1
        # "+2 -5" is ahead 2, behind 5 — the opposite order to the rev-list
        # form this replaced, which is exactly how you end up showing one as
        # the other.
        ab="${line#\# branch.ab }"
        AHEAD="${ab%% *}";  AHEAD="${AHEAD#+}"
        BEHIND="${ab##* }"; BEHIND="${BEHIND#-}" ;;
      '#'*) ;;
      # Body lines, counted right here rather than by piping the same text
      # through grep twice afterwards. 1/2 are tracked changes, u is unmerged,
      # ? is untracked — the set plain --porcelain used to print. ! (ignored)
      # is deliberately not counted, matching it.
      '1 '*|'2 '*|'? '*) DIRTY=$((DIRTY + 1)) ;;
      'u '*)             DIRTY=$((DIRTY + 1)); CONFLICTS=$((CONFLICTS + 1)) ;;
      *) ;;
    esac
  done <<< "$ST"

  # An upstream in the config whose ref does not exist: the branch was set up
  # to track something that has never been pushed. v2 says so by giving a
  # branch.upstream with no branch.ab — it cannot count against a missing ref.
  # Worth a warning of its own: it is neither "no upstream" nor "up to date",
  # and it is exactly when you need push -u.
  [ -n "$UP" ] && [ -z "$AB" ] && [ -n "$BRANCH" ] && UPGONE=1

  # No header: git could not read the repository at all. A worktree whose main
  # repo was moved is the usual one, its .git a pointer to nowhere. This was
  # rendered as "Detached HEAD", with the advice that commits only living
  # there would be lost — and a fallback for pre-2016 git ran five more
  # failing git calls for it on every render.
  BROKEN=""; [ -z "$HDR" ] && BROKEN=1
  DIRTY="${DIRTY// /}"; CONFLICTS="${CONFLICTS// /}"
  : "${DIRTY:=0}"; : "${CONFLICTS:=0}"; : "${BEHIND:=0}"; : "${AHEAD:=0}"

  # Which remote this branch actually belongs to. Hardcoding 'origin' breaks
  # forks, where origin is your copy and upstream is the real project: the menu
  # would flag a branch tracking upstream as wrong and offer to "fix" it.
  # When there is an upstream the name is already in it, for free.
  if [ -n "$UP" ]; then
    REMOTE="${UP%%/*}"
  else
    REMOTE="$(git -C "$R" config --get "branch.$BRANCH.remote" 2>/dev/null)"
    if [ -z "$REMOTE" ]; then
      local rs; rs="$(git -C "$R" remote 2>/dev/null)"
      if [ "$(printf '%s' "$rs" | grep -c .)" = "1" ]; then REMOTE="$rs"; else REMOTE="origin"; fi
    fi
  fi

  # $R/.git only holds for a plain repo. In a worktree or submodule it is a
  # file, and the real directories have to be asked for. Two of them: the
  # private one, where the in-progress markers live, and the common one, which
  # is where the stash is shared from.
  # Read the pointers instead of asking git for them: this ran once per repo
  # per render and cost more than the status call it sits next to. A plain repo
  # needs no process at all, and a worktree or submodule needs only the builtin
  # read of the two small files git would have read anyway.
  local g
  if [ -d "$R/.git" ]; then
    GITDIR="$R/.git"
  elif [ -f "$R/.git" ]; then
    # A worktree or submodule leaves "gitdir: <path>" behind, absolute or
    # relative to the repo. read, not cut: the path may contain spaces.
    read -r _ g < "$R/.git" 2>/dev/null || g=""
    case "$g" in
      /*) GITDIR="$g" ;;
      "") GITDIR="$R/.git" ;;
      *)  GITDIR="$R/$g" ;;
    esac
  else
    GITDIR="$R/.git"
  fi
  # The common dir is where the stash lives, shared by every worktree.
  if [ -f "$GITDIR/commondir" ]; then
    read -r g < "$GITDIR/commondir" 2>/dev/null || g=""
    case "$g" in
      /*) COMMONDIR="$g" ;;
      "") COMMONDIR="$GITDIR" ;;
      *)  COMMONDIR="$GITDIR/$g" ;;
    esac
  else
    COMMONDIR="$GITDIR"
  fi

  # From the refs/stash reflog rather than `git stash list`: same source, one
  # process less. Without the ref, the lines are leftovers of dropped entries.
  STASH=0
  if [ -s "$COMMONDIR/logs/refs/stash" ] &&
     { [ -f "$COMMONDIR/refs/stash" ] || grep -q ' refs/stash$' "$COMMONDIR/packed-refs" 2>/dev/null; }; then
    STASH="$(grep -c . "$COMMONDIR/logs/refs/stash" 2>/dev/null | tr -d ' ')"
  fi
  : "${STASH:=0}"

  # A half-finished operation leaves HEAD detached, so without this the repo
  # would just be reported as "Detached HEAD" and the menu would cheerfully
  # offer a pull that cannot possibly work.
  INPROGRESS=""
  if   [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ]; then INPROGRESS="rebase"
  elif [ -f "$GITDIR/MERGE_HEAD" ];       then INPROGRESS="merge"
  elif [ -f "$GITDIR/CHERRY_PICK_HEAD" ]; then INPROGRESS="cherry-pick"
  elif [ -f "$GITDIR/REVERT_HEAD" ];      then INPROGRESS="revert"
  elif [ -f "$GITDIR/BISECT_LOG" ];       then INPROGRESS="bisect"
  fi

  # Behind/ahead are measured against what the last fetch brought down, so an
  # old fetch means those numbers are stale, not wrong-looking. Empty = never.
  FETCH_AGE=""
  [ -f "$COMMONDIR/FETCH_HEAD" ] && \
    FETCH_AGE=$(( NOW - $(stat -f %m "$COMMONDIR/FETCH_HEAD" 2>/dev/null || echo 0) ))

  WARN=""
  if [ -n "$BROKEN" ];                then WARN="git cannot read this repository"
  elif [ -n "$INPROGRESS" ];          then WARN="$INPROGRESS in progress"
  elif [ -z "$BRANCH" ];              then WARN="Detached HEAD"
  elif [ -z "$UP" ];                  then WARN="No upstream branch"
  elif [ -n "$UPGONE" ];              then WARN="'$UP' is not on the remote yet"
  elif [ "$UP" != "$REMOTE/$BRANCH" ]; then WARN="Tracks '$UP', not '$REMOTE/$BRANCH'"
  fi
}

# Stash entries: "N<TAB>age<TAB>message", newest first.
# Reflog line: <sha> <sha> <author> <<email>> <ts> <tz>\t<msg>
# The author spans a variable number of words, so the date is counted from the
# end. stash@{0} is the last line, hence the reverse walk.
stash_entries() {   # $1 = common git dir, not the repo: in a worktree they differ
  local log="$1/logs/refs/stash"
  [ -s "$log" ] || return 0
  awk -F'\t' -v now="$NOW" '
    {
      n = split($1, f, " ")
      d = now - f[n-1]
      if      (d < 60)    age = "just now"
      else if (d < 3600)  age = int(d/60)    " min ago"
      else if (d < 86400) age = int(d/3600)  " h ago"
      else                age = int(d/86400) " d ago"
      line[NR] = age "\t" $2
    }
    END { for (i = NR; i >= 1; i--) printf "%d\t%s\n", NR - i, line[i] }
  ' "$log"
}

stash_cmd() {   # $1=index  $2=show|apply|pop
  case "$2" in
    show)  echo "git stash show -p stash@{$1}" ;;
    apply) echo "git stash apply stash@{$1}" ;;
    pop)   echo "git stash pop stash@{$1}" ;;
  esac
}

# Can git sign without prompting? If signing is on and the key is not in the
# ssh agent, anything that creates or rewrites commits would sit waiting for a
# passphrase nobody can type here.
signing_blocked() {
  local R="$1" key fp
  [ "$(git -C "$R" config --get commit.gpgsign)" = "true" ] || return 1
  [ "$(git -C "$R" config --get gpg.format)" = "ssh" ] || return 1
  key="$(git -C "$R" config --get user.signingkey)"
  [ -n "$key" ] && [ -f "$key" ] || return 1
  fp="$(ssh-keygen -lf "$key" 2>/dev/null | awk '{print $2}')"
  [ -n "$fp" ] || return 1
  ssh-add -l 2>/dev/null | grep -qF "$fp" && return 1
  KEY_PATH="${key%.pub}"
  return 0
}

# Commands that would resolve the current state, in the order they must run.
# Uses the globals left by read_state.
commands_for() {
  local R="$1"

  if [ -n "$BROKEN" ]; then
    echo "git status   # says why it cannot read it"
    return
  fi

  # --- Something is half-done. Nothing else is worth suggesting until it is
  #     finished or aborted, so this returns early.
  if [ -n "$INPROGRESS" ]; then
    if [ "$CONFLICTS" -gt 0 ]; then
      echo "git status   # $(plural "$CONFLICTS" "file" "files") with conflicts to resolve"
      echo "git add <file>   # once resolved, mark it"
    fi
    case "$INPROGRESS" in
      rebase)      echo "git rebase --continue"
                   echo "git rebase --abort   # back to how it was" ;;
      merge)       echo "git merge --continue"
                   echo "git merge --abort   # back to how it was" ;;
      cherry-pick) echo "git cherry-pick --continue"
                   echo "git cherry-pick --abort" ;;
      revert)      echo "git revert --continue"
                   echo "git revert --abort" ;;
      bisect)      echo "git bisect reset   # end the bisect" ;;
    esac
    return
  fi

  # --- Detached HEAD: the urgent part is not losing stray commits.
  if [ -z "$BRANCH" ]; then
    [ "$DIRTY" -gt 0 ] && echo "git stash push -u   # changes do not follow you across branches"
    # `branch --contains` always prints the "* (HEAD detached…)" pseudo-entry,
    # so testing for empty output meant this never fired. Ask for real branches.
    if [ -n "$R" ] && [ -z "$(git -C "$R" for-each-ref --contains HEAD --format='%(refname)' refs/heads 2>/dev/null)" ]; then
      echo "git switch -c <new-branch>   # there ARE commits only here: they would be lost"
    else
      echo "git switch <branch>"
    fi
    return
  fi

  # --- Broken tracking. The fix depends on whether the branch is already on
  #     the remote: attach it if it exists, create it otherwise.
  local FIX_UP=""
  if [ -z "$UP" ] || [ "$UP" != "$REMOTE/$BRANCH" ] || [ -n "$UPGONE" ]; then
    if [ -n "$R" ] && git -C "$R" rev-parse --verify --quiet "$REMOTE/$BRANCH" >/dev/null 2>&1; then
      FIX_UP="git branch --set-upstream-to=$(shq "$REMOTE/$BRANCH") $(shq "$BRANCH")"
    else
      FIX_UP="git push -u $(shq "$REMOTE") $(shq "$BRANCH")"
    fi
  fi
  [ -n "$FIX_UP" ] && echo "$FIX_UP"

  # --- Sync. Careful: committing pending changes ADDS a local commit, so the
  #     branch starts diverging and ff-only no longer applies. That is why the
  #     commit path always ends in a rebase when the branch is behind.
  if [ "$DIRTY" -gt 0 ]; then
    echo "git add -A && git commit -m \"...\""
    if [ "$BEHIND" -gt 0 ]; then
      echo "git pull --rebase"
      echo "git push"
      echo "# without committing: git stash push -u && git pull --ff-only && git stash pop"
    else
      echo "git push"
      echo "# without committing: git stash push -u"
    fi
  elif [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ]; then
    echo "git pull --rebase"
    echo "git push"
  elif [ "$BEHIND" -gt 0 ]; then
    echo "git pull --ff-only"
  elif [ "$AHEAD" -gt 0 ]; then
    echo "git push"
  fi

  # The counters were measured against the old upstream: after re-attaching,
  # the real state may differ.
  [ -n "$FIX_UP" ] && [ "${FIX_UP#git branch}" != "$FIX_UP" ] && \
    echo "# after re-attaching, check the state again"
}

# The Settings submenu. A function because the early exit for a config that
# scans nothing needs it most: that is where a dead root has to be removed.
settings_menu() {
  local r p lbl n cpath cn app mark
  echo "Settings | sfimage=gearshape"
  if [ -f "$CONFIG" ]; then
    echo "--$(pretty_path "$CONFIG") | $MONO"
  else
    echo "--⚠ no config file yet · using defaults | $MONO"
  fi
  echo "--Open config file | bash=\"$SELF\" param1=openconfig terminal=false"
  echo "-----"
  echo "--Scanning: | $MONO"
  for r in "${ROOTS[@]}"; do
    p="${r%%|*}"; lbl=""; [ "$r" != "$p" ] && lbl="  ·  ${r#*|}"
    if [ -d "$p" ]; then
      n=""
      while IFS="$SEP" read -r cpath cn; do
        [ "$cpath" = "$p" ] && { n="$cn"; break; }
      done <<< "$COUNTS"
      echo "--  $(pretty_path "$p")  ·  $(plural "${n:-0}" "repo" "repos")$lbl | $MONO"
    else
      echo "--  ⚠ $(pretty_path "$p")  ·  folder not found$lbl | $MONO"
    fi
  done
  echo "--Add a folder… | bash=\"$SELF\" param1=addroot terminal=false refresh=true"
  if [ "${#ROOTS[@]}" -gt 1 ]; then
    echo "--Stop scanning"
    for r in "${ROOTS[@]}"; do
      enc "$r"
      echo "----$(pretty_path "${r%%|*}") | bash=\"$SELF\" param1=delroot param2=$ENC terminal=false refresh=true"
    done
  fi
  echo "-----"
  echo "--Open in: ${IDE:-none}"
  for app in "PyCharm" "IntelliJ IDEA" "GoLand" "WebStorm" "PhpStorm" "RubyMine" \
             "Visual Studio Code" "Cursor" "Zed"; do
    [ -d "/Applications/$app.app" ] || continue
    mark=""; [ "$app" = "$IDE" ] && mark="  ✓"
    echo "----$app$mark | bash=\"$SELF\" param1=setide param2=\"$app\" terminal=false refresh=true"
  done
  echo "----(none) | bash=\"$SELF\" param1=setide param2=\"\" terminal=false refresh=true"
  echo "--Search depth: $DEPTH$([ "$DEEPER" -gt 0 ] && echo "  ·  ⚠ $DEEPER not reached") | bash=\"$SELF\" param1=setnum param2=REPOS_DEPTH param3=\"How many folders deep to search:\" param4=\"$DEPTH\" terminal=false refresh=true"
  if [ "$ONLY_PENDING" = "1" ]; then
    echo "--Showing: only repos needing attention  ✓ | bash=\"$SELF\" param1=set param2=REPOS_ONLY_PENDING param3=0 terminal=false refresh=true"
  else
    echo "--Showing: all repos | bash=\"$SELF\" param1=set param2=REPOS_ONLY_PENDING param3=1 terminal=false refresh=true"
  fi
  echo "--Fetch stale after: ${REPOS_FETCH_STALE_HOURS:-24} h | bash=\"$SELF\" param1=setnum param2=REPOS_FETCH_STALE_HOURS param3=\"Warn when the last fetch is older than, in hours:\" param4=\"${REPOS_FETCH_STALE_HOURS:-24}\" terminal=false refresh=true"
  local every
  every="off"; [ "$AUTO_FETCH_MIN" -gt 0 ] && every="every $AUTO_FETCH_MIN min"
  echo "--Fetch in the background: $every | bash=\"$SELF\" param1=setnum param2=REPOS_AUTO_FETCH_MINUTES param3=\"Fetch every how many minutes? 0 turns it off.\" param4=\"$AUTO_FETCH_MIN\" terminal=false refresh=true"
  every="off"; [ "$PR_MIN" -gt 0 ] && every="every $PR_MIN min"
  command -v gh >/dev/null 2>&1 || every="needs gh"
  echo "--Pull requests: $every | bash=\"$SELF\" param1=setnum param2=REPOS_PR_MINUTES param3=\"Look up pull requests every how many minutes? 0 turns it off.\" param4=\"$PR_MIN\" terminal=false refresh=true"
  echo "-----"
  echo "--git $(git --version 2>/dev/null | awk '{print $3}')  ·  $(command -v git) | $MONO"
}

# ---------------------------------------------------------------- actions

case "$1" in

  update)
    R="$2"; N="$(repo_name "$R")"
    # Rule 1: never touch a repo with unsaved changes.
    if [ -n "$(git -C "$R" status --porcelain 2>/dev/null)" ]; then
      fail "$N: update cancelled" \
"There are uncommitted changes in the working tree.

Commit or stash them before updating. Nothing was touched."
    fi
    # Rule 2: --ff-only only aborts when the merge is not a clean fast-forward.
    OUT="$(git -C "$R" pull --ff-only 2>&1)"
    if [ $? -ne 0 ]; then
      # A missing upstream and an unreachable host are not divergence, and
      # saying so sent people looking for a merge that was never the problem.
      case "$OUT" in
        *"no tracking information"*|*"no upstream"*)
          WHY="This branch is not tracking anything, so there is nothing to pull from." ;;
        *"Could not resolve host"*|*"Connection refused"*|*"Could not read from remote"*|*"timed out"*)
          WHY="The remote could not be reached." ;;
        *"Authentication failed"*|*"Permission denied"*)
          WHY="The remote refused your credentials." ;;
        *"non-fast-forward"*|*"diverged"*|*"Not possible to fast-forward"*)
          WHY="The branch has diverged from the remote: it cannot move forward without merging." ;;
        *) WHY="git refused the update." ;;
      esac
      fail "$N: update aborted" \
"$WHY

Nothing was modified. git output:

$OUT"
    fi
    ok "$N updated" "$(echo "$OUT" | tail -1)"
    exit 0 ;;

  update-all)
    DONE=""; SKIP=""; ERR=""
    while IFS= read -r R; do
      [ -n "$R" ] || continue
      N="$(repo_name "$R")"
      if [ -n "$(git -C "$R" status --porcelain 2>/dev/null)" ]; then
        SKIP="$SKIP\n  · $N (uncommitted changes)"; continue
      fi
      OUT="$(git -C "$R" pull --ff-only 2>&1)"
      if [ $? -eq 0 ]; then
        DONE="$DONE\n  · $N"
      else
        # Same triage as the single-repo update. Calling a flaky VPN or a
        # missing upstream "diverged" sent people hunting for a merge that
        # was never the problem.
        case "$OUT" in
          *"no tracking information"*|*"no upstream"*) WHY="no upstream" ;;
          *"Could not resolve host"*|*"Connection refused"*|*"Could not read from remote"*|*"timed out"*)
            WHY="remote unreachable" ;;
          *"Authentication failed"*|*"Permission denied"*) WHY="auth refused" ;;
          *"non-fast-forward"*|*"diverged"*|*"Not possible to fast-forward"*) WHY="diverged" ;;
          *) WHY="refused by git" ;;
        esac
        ERR="$ERR\n  · $N ($WHY)"
      fi
    done <<< "$(unb64 "$2" | tr '|' '\n')"
    MSG=""
    [ -n "$DONE" ] && MSG="Updated:$DONE\n\n"
    [ -n "$SKIP" ] && MSG="${MSG}Skipped:$SKIP\n\n"
    [ -n "$ERR" ]  && MSG="${MSG}Aborted:$ERR"
    [ -z "$MSG" ]  && MSG="There was nothing to update."
    info "Update all" "$(printf "%b" "$MSG")"
    exit 0 ;;

  # Started by the render, detached, once the last round is older than
  # REPOS_AUTO_FETCH_MINUTES. Nothing in here may ask for anything: with no
  # terminal prompt a remote that wants a password fails, quietly, until the
  # next round, instead of hanging a process nobody can see.
  autofetch)
    unb64 "$2" | tr '|' '\0' \
      | GIT_TERMINAL_PROMPT=0 xargs -0 -P 8 -I {} sh -c '[ -n "$1" ] || exit 0
         git -C "$1" fetch --all --prune --quiet >/dev/null 2>&1' _ {}
    redraw
    exit 0 ;;

  # The open pull request for each repository's current branch, with its
  # checks and review, cached for the render to read: gh talks to GitHub,
  # which is exactly why this never runs inside a render. Only an answer of
  # "no pull request" clears a cache — a network error keeps the last one.
  refresh-prs)
    mkdir -p "$CACHE/pr"
    JQ='if .state != "OPEN" then "" else
      ([.statusCheckRollup[]? | (.conclusion // .state // "") | ascii_upcase]) as $c
      | [.headRefName, .number, .url, (.reviewDecision // ""),
         (if ($c | length) == 0 then ""
          elif any($c[]; . == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT"
                         or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE") then "fail"
          elif all($c[]; . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "pass"
          else "pending" end),
         (if .isDraft then "draft" else "" end)]
      | map(tostring) | join("\u001f") end'
    unb64 "$2" | tr '|' '\0' \
      | GH_PROMPT_DISABLED=1 xargs -0 -P 4 -I {} sh -c '[ -n "$1" ] && cd "$1" 2>/dev/null || exit 0
         out="$2/pr/$(printf %s "$1" | tr / %)"
         err="$(gh pr view --json state,headRefName,number,url,reviewDecision,statusCheckRollup,isDraft \
                  --jq "$3" 2>&1 >"$out.tmp")"
         # A closed or merged PR comes back as an empty line, not as nothing.
         if [ $? -eq 0 ] && grep -q . "$out.tmp"; then mv "$out.tmp" "$out"
         else
           rm -f "$out.tmp"
           case "$err" in *"no pull requests found"*|*"not a git repository"*|*"none of the git remotes"*|"") rm -f "$out" ;; esac
         fi' _ {} "$CACHE" "$JQ"
    redraw
    exit 0 ;;

  fetch-all)
    # Eight at a time. Serially this was one network round trip per repository
    # with the menu blocked behind it — minutes on a VPN, with nothing on
    # screen to say it was still working.
    PATHS="$(unb64 "$2")"
    # Counted by splitting on the | that joined them, not by lines. A path may
    # legally contain a newline, and reading line by line counted such a repo
    # twice — then reported "9 of 10 updated" for eight repositories.
    NREPOS=0; REST="$PATHS"
    while [ -n "$REST" ]; do
      case "$REST" in
        *"|"*) ONE="${REST%%|*}"; REST="${REST#*|}" ;;
        *)     ONE="$REST"; REST="" ;;
      esac
      [ -n "$ONE" ] && NREPOS=$((NREPOS + 1))
    done
    ok "Fetching" "$(plural "$NREPOS" "repository" "repositories"), 8 at a time…"
    # NUL separated in both directions: bash cannot hold a NUL in a variable,
    # so the failures go to a file rather than through a command substitution
    # — which is also what makes a newline in a path harmless here.
    FAILFILE="$(mktemp -t reposfetch)" || fail "Fetch" "Could not create a temporary file."
    printf '%s' "$PATHS" | tr '|' '\0' \
      | xargs -0 -P 8 -I {} sh -c '[ -n "$1" ] || exit 0
         git -C "$1" fetch --all --prune >/dev/null 2>&1 || printf "%s\0" "$1"' _ {} \
      > "$FAILFILE" 2>/dev/null
    NFAIL="$(tr -cd '\0' < "$FAILFILE" | wc -c | tr -d ' ')"
    if [ "$NFAIL" -gt 0 ]; then
      FLIST=""
      while IFS= read -r -d '' f; do
        [ -n "$f" ] && FLIST="$FLIST  · ${f##*/}"$'\n'
      done < "$FAILFILE"
      rm -f "$FAILFILE"
      info "Fetch finished with errors" \
"$((NREPOS - NFAIL)) of $NREPOS updated.

Could not reach the remote for:
$FLIST"
    else
      rm -f "$FAILFILE"
      ok "Fetch complete" "$(plural "$NREPOS" "repository" "repositories") refreshed."
    fi
    exit 0 ;;

  # Deletes local branches whose upstream is gone: the usual leftovers after a
  # pull request is merged and the remote branch removed. Uses -d, never -D, so
  # git itself refuses anything holding unmerged commits — and the list is put
  # in front of you before a single one is touched.
  prunegone)
    R="$2"; N="$(repo_name "$R")"; read_state "$R"
    [ -n "$INPROGRESS" ] && fail "$N: cannot clean up" \
"A $INPROGRESS is in progress. Finish or abort it first. Nothing was touched."
    GONE=""; NGONE=0
    while IFS="$TAB" read -r b track; do
      [ -n "$b" ] || continue
      [ "$track" = "[gone]" ] || continue
      [ "$b" = "$BRANCH" ] && continue
      GONE="$GONE$b"$'\n'; NGONE=$((NGONE + 1))
    done <<< "$(git -C "$R" for-each-ref --format="%(refname:short)$TAB%(upstream:track)" refs/heads 2>/dev/null)"
    [ "$NGONE" -eq 0 ] && { ok "$N" "No branches with a deleted upstream."; exit 0; }
    confirm "Delete $(plural "$NGONE" "branch" "branches") in $N?" \
"Their upstream no longer exists on the remote:

$(printf '%s' "$GONE" | sed 's/^/  · /')

Anything holding unmerged commits will be refused and left alone." || exit 0
    DELETED=""; KEPT=""
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      if git -C "$R" branch -d "$b" >/dev/null 2>&1; then
        DELETED="$DELETED  · $b"$'\n'
      else
        KEPT="$KEPT  · $b"$'\n'
      fi
    done <<< "$GONE"
    NDEL="$(printf '%s' "$DELETED" | grep -c .)"
    if [ -n "$KEPT" ]; then
      info "$N: $NDEL deleted, $(printf '%s' "$KEPT" | grep -c .) kept" \
"Deleted:
$DELETED
Kept, because they hold commits that are not merged anywhere:
$KEPT
Delete those by hand if you are sure."
    else
      ok "$N" "$(plural "$NDEL" "branch" "branches") deleted."
    fi
    exit 0 ;;

  # Opens the current branch on the forge. Works out the web URL from the
  # remote, which may be ssh or https.
  browse)
    R="$2"; N="$(repo_name "$R")"; read_state "$R"
    URL="$(git -C "$R" config --get "remote.$REMOTE.url" 2>/dev/null)"
    [ -z "$URL" ] && fail "$N: cannot open" "No URL configured for remote '$REMOTE'."
    # git@host:group/repo.git and https://host/group/repo.git both become
    # https://host/group/repo
    # Rewrite the host:path colon FIRST, then prepend the scheme. Doing it the
    # other way round meant sed's first-colon match hit the scheme's own colon
    # and produced https///host:group/repo — every scp-style SSH remote, which
    # is the default clone form on GitHub and GitLab both.
    case "$URL" in
      git@*)
        WEB="https://$(printf '%s' "${URL#git@}" | sed 's|:|/|')" ;;
      ssh://git@*)
        WEB="${URL#ssh://git@}"
        # ssh://git@host:2222/group/repo — the SSH port means nothing to a
        # browser, so drop it rather than pointing at a closed https port.
        case "$WEB" in
          *:[0-9]*/*) WEB="${WEB%%:*}/${WEB#*/}" ;;
        esac
        WEB="https://$WEB" ;;
      https://*|http://*)
        # A remote carrying credentials would put them in the address bar and
        # in browser history. Strip anything before the @.
        WEB="$URL"
        case "$WEB" in
          https://*@*) WEB="https://${WEB#https://*@}" ;;
          http://*@*)  WEB="http://${WEB#http://*@}" ;;
        esac ;;
      *) WEB="$URL" ;;
    esac
    WEB="${WEB%.git}"
    if [ -n "$BRANCH" ]; then
      case "$WEB" in
        *gitlab*) WEB="$WEB/-/tree/$BRANCH" ;;
        *)        WEB="$WEB/tree/$BRANCH" ;;
      esac
    fi
    open "$WEB" >/dev/null 2>&1 || fail "$N: could not open" "$WEB"
    exit 0 ;;

  # Drops the fix-it commands into a Terminal already sitting in the repo,
  # instead of leaving them on the clipboard for you to paste.
  runfix)
    R="$2"; N="$(repo_name "$R")"; read_state "$R"
    CMDS="$(commands_for "$R")"
    LINES=""
    while IFS= read -r C; do
      L="$(strip_comment "$C")"
      [ -n "$L" ] && LINES="$LINES$L"$'\n'
    done <<< "$CMDS"
    [ -z "$LINES" ] && { ok "$N" "Nothing to run."; exit 0; }
    confirm "Run $(printf '%s' "$LINES" | grep -c .) command(s) in $N?" \
"A Terminal opens in the repository with these ready to run:

$(printf '%s' "$LINES" | sed 's/^/  /')

Each one asks before it runs, and nothing runs after one fails. Lines with a placeholder are shown for you to finish by hand." || exit 0
    # A wrapper, because Terminal cannot be handed a working directory and a
    # command at once. mktemp so the path is not predictable; the script
    # removes itself before handing control over.
    W="$(mktemp -t reposbar)" || fail "$N" "Could not create the helper script."
    mv "$W" "$W.command"; W="$W.command"
    # Return used to run the line, as written: git commit -m "..." with every
    # untracked file staged, git switch <branch> as a syntax error, and after a
    # --continue that stopped on a conflict, the next Return ran --abort and
    # threw the resolution away. Each line now defaults to skip, a failure ends
    # the sequence, and a placeholder is never run at all.
    {
      printf '#!/bin/bash\n'
      printf 'rm -f "$0"\n'
      printf 'cd %q || exit 1\n' "$R"
      printf 'run() { printf "\\n> %%s\\n  run it? [y/N] " "$1"; read -r a; case "$a" in y|Y) eval "$1" || { echo "  It failed, so the rest was skipped."; exec $SHELL; } ;; esac; }\n'
      printf 'echo %q\n' "Ready in $N. y runs a line, Return skips it."
      while IFS= read -r L; do
        case "$L" in
          '') ;;
          *'<'*'>'*|*'"..."'*) printf 'printf "\\n%%s\\n" %q\n' "  finish by hand: $L" ;;
          *) printf 'run %q\n' "$L" ;;
        esac
      done <<< "$LINES"
      printf 'echo; echo "Done."; exec $SHELL\n'
    } > "$W"
    chmod 700 "$W"
    open -a Terminal "$W" >/dev/null 2>&1 || fail "$N" "Could not open Terminal."
    exit 0 ;;

  newbranch)
    R="$2"; N="$(repo_name "$R")"
    NAME="$(ask "Name of the new branch in $N:" "")"
    [ -z "$NAME" ] && exit 0
    OUT="$(git -C "$R" switch -c "$NAME" 2>&1)"
    [ $? -ne 0 ] && fail "$N: could not create the branch" "$OUT"
    ok "$N" "Branch '$NAME' created. Local only: it does not exist on origin yet."
    exit 0 ;;

  rename)
    R="$2"; dec "$3"; OLD="$DEC"; N="$(repo_name "$R")"
    [ -z "$OLD" ] && fail "$N: cannot rename" \
"The repository is not on any branch (detached HEAD)."
    NAME="$(ask "New name for '$OLD' in $N:" "$OLD")"
    if [ -z "$NAME" ] || [ "$NAME" = "$OLD" ]; then exit 0; fi
    confirm "Rename '$OLD' to '$NAME'" \
"Only the LOCAL branch is renamed. On origin it will still be called '$OLD', so tracking will be out of sync until you push it under the new name." || exit 0
    OUT="$(git -C "$R" branch -m "$OLD" "$NAME" 2>&1)"
    [ $? -ne 0 ] && fail "$N: could not rename" "$OUT"
    ok "$N" "Branch renamed to '$NAME' (local only)."
    exit 0 ;;

  push)
    R="$2"; N="$(repo_name "$R")"; read_state "$R"
    [ -z "$BRANCH" ] && fail "$N: cannot push" "Detached HEAD: there is no branch to push."
    if [ "$BEHIND" -gt 0 ]; then
      fail "$N: push cancelled" \
"The remote has $(plural "$BEHIND" "commit" "commits") you do not have, so the push would be rejected.

Update first. Nothing was sent."
    fi
    # UPGONE excepted: the upstream is configured but has never been pushed, so
    # "nothing to push" was false — the branch itself is what is missing.
    if [ "$AHEAD" -eq 0 ] && [ -n "$UP" ] && [ -z "$UPGONE" ]; then
      ok "$N" "Nothing to push."; exit 0
    fi
    # With no upstream — or one that is not on the remote yet — the push creates
    # the branch there: confirm that.
    if [ -z "$UP" ] || [ -n "$UPGONE" ]; then
      confirm "Create '$BRANCH' on $REMOTE" \
"'$BRANCH' does not exist on $REMOTE. It will be created and tracked." || exit 0
      OUT="$(git -C "$R" push -u "$REMOTE" "$BRANCH" 2>&1)"
    else
      OUT="$(git -C "$R" push 2>&1)"
    fi
    [ $? -ne 0 ] && fail "$N: push failed" "$OUT"
    ok "$N" "Pushed to $REMOTE/$BRANCH."
    exit 0 ;;

  rebase)
    R="$2"; N="$(repo_name "$R")"; read_state "$R"
    if [ "$DIRTY" -gt 0 ]; then
      fail "$N: rebase cancelled" \
"There are uncommitted changes. Commit or stash them first. Nothing was touched."
    fi
    if signing_blocked "$R"; then
      fail "$N: rebase cancelled" \
"A rebase rewrites commits and your config signs them, but the key is not loaded in the ssh agent. It would sit waiting for a passphrase that cannot be typed here.

Load it first:

    ssh-add $KEY_PATH

Nothing was touched."
    fi
    # Never touch a rebase somebody else started: aborting it destroys their
    # work and the old code then claimed nothing had changed.
    [ -n "$INPROGRESS" ] && fail "$N: rebase cancelled" \
"A $INPROGRESS is already in progress. Finish or abort it yourself — this will
not do it for you."
    BEFORE="$(git -C "$R" rev-parse HEAD)"
    # stdin closed: if something still asks for input, it fails instead of hanging.
    OUT="$(git -C "$R" pull --rebase 2>&1 </dev/null)"
    if [ $? -ne 0 ]; then
      # Only unwind a rebase this command started.
      git -C "$R" rebase --abort >/dev/null 2>&1
      NOW="$(git -C "$R" rev-parse HEAD)"
      fail "$N: rebase aborted by conflicts" \
"Reverted: the repo is back to how it was$([ "$BEFORE" = "$NOW" ] && echo " (verified)").

Resolve it by hand. git output:

$OUT"
    fi
    ok "$N" "Rebased onto $UP."
    exit 0 ;;

  setupstream)
    R="$2"; N="$(repo_name "$R")"; read_state "$R"
    [ -z "$BRANCH" ] && fail "$N: no branch" "Detached HEAD."
    if git -C "$R" rev-parse --verify --quiet "$REMOTE/$BRANCH" >/dev/null 2>&1; then
      OUT="$(git -C "$R" branch --set-upstream-to="$REMOTE/$BRANCH" "$BRANCH" 2>&1)"
      [ $? -ne 0 ] && fail "$N: could not set upstream" "$OUT"
      ok "$N" "Now tracking $REMOTE/$BRANCH."
    else
      fail "$N: $REMOTE/$BRANCH does not exist" \
"The branch is not on the remote, so there is nothing to track.

Use 'Push' to create it on origin."
    fi
    exit 0 ;;

  stash)
    R="$2"; N="$(repo_name "$R")"; read_state "$R"
    [ "$DIRTY" -eq 0 ] && { ok "$N" "No changes to stash."; exit 0; }
    OUT="$(git -C "$R" stash push -u -m "modeswitch $(date +%Y-%m-%d\ %H:%M)" 2>&1)"
    [ $? -ne 0 ] && fail "$N: could not stash" "$OUT"
    ok "$N" "$(plural "$DIRTY" "change" "changes") stashed. Restore with git stash pop."
    exit 0 ;;

  copy-one)
    dec "$3"; C="$DEC"
    [ -z "$C" ] && exit 1
    printf '%s\n' "$C" | pbcopy
    ok "$(repo_name "$2")" "Copied:  $C"
    exit 0 ;;

  copy-all)
    R="$2"; N="$(repo_name "$R")"; read_state "$R"
    CLEAN=""
    while IFS= read -r C; do
      C="$(strip_comment "$C")"
      [ -n "$C" ] && CLEAN="$CLEAN$C"$'\n'
    done <<< "$(commands_for "$R")"
    if [ -z "$CLEAN" ]; then
      ok "$N" "Nothing to copy."; exit 0
    fi
    printf '%s' "$CLEAN" | pbcopy
    ok "$N" "$(plural "$(printf '%s' "$CLEAN" | grep -c .)" "command copied" "commands copied")."
    exit 0 ;;

  terminal)
    open -a Terminal "$2" >/dev/null 2>&1; exit 0 ;;

  # ---- settings, edited from the menu so nothing needs a text editor

  addroot)
    NEW="$(ask "Folder to scan for repositories:" "$HOME/")"
    [ -z "$NEW" ] && exit 0
    NEW="${NEW/#\~/$HOME}"; NEW="${NEW%/}"
    [ -d "$NEW" ] || fail "Not a folder" "'$NEW' does not exist."
    # ROOTS, not REPOS_ROOTS: with no config the array is empty but the bar is
    # scanning the default, and adding a folder used to silently drop it.
    KEEP=()
    for r in "${ROOTS[@]}"; do
      [ "${r%%|*}" = "$NEW" ] && fail "Already there" "'$NEW' is already being scanned."
      KEEP+=("$r")
    done
    KEEP+=("$NEW")
    write_roots "${KEEP[@]}"
    ok "Settings" "Now scanning $(pretty_path "$NEW")."
    exit 0 ;;

  delroot)
    # The entry can carry a "|LABEL" suffix, and | is SwiftBar's own separator,
    # so it travels base64-encoded like the commands do.
    dec "$2"; TARGET="$DEC"
    KEEP=()
    for r in "${REPOS_ROOTS[@]}"; do [ "$r" = "$TARGET" ] || KEEP+=("$r"); done
    # Reporting success without having removed anything is worse than failing.
    if [ "${#KEEP[@]}" -eq "${#REPOS_ROOTS[@]}" ]; then
      fail "Not found" "'${TARGET%%|*}' is not in the list any more."
    fi
    if [ "${#KEEP[@]}" -eq 0 ]; then
      fail "Cannot remove" "That is the only folder left. Add another one first."
    fi
    write_roots "${KEEP[@]}"
    ok "Settings" "Stopped scanning ${TARGET%%|*}."
    exit 0 ;;

  # Generic single-key writer, for the toggles that are just a 0/1.
  set)
    set_config "$2" "$3"
    ok "Settings" "$2 = $3"
    exit 0 ;;

  setide)
    set_config REPOS_IDE "$2"
    ok "Settings" "${2:-No IDE} for \"Open in …\"."
    exit 0 ;;

  setnum)
    VAL="$(ask "$3" "$4")"
    [ -z "$VAL" ] && exit 0
    case "$VAL" in ''|*[!0-9]*) fail "Not a number" "'$VAL' is not a whole number." ;; esac
    set_config "$2" "$VAL"
    ok "Settings" "$2 = $VAL"
    exit 0 ;;

  openconfig)
    [ -f "$CONFIG" ] || { mkdir -p "$(dirname "$CONFIG")"; : > "$CONFIG"; }
    if [ -n "$IDE_CMD" ] && command -v "$IDE_CMD" >/dev/null 2>&1; then
      "$IDE_CMD" "$CONFIG" >/dev/null 2>&1 &
    elif [ -n "$IDE" ]; then
      open -a "$IDE" "$CONFIG" >/dev/null 2>&1 || open -e "$CONFIG"
    else
      open -e "$CONFIG"
    fi
    exit 0 ;;

  switch)
    R="$2"; dec "$3"; TARGET="$DEC"; N="$(repo_name "$R")"; read_state "$R"
    # Switching with a dirty tree either fails or drags the changes along, and
    # neither is what someone clicking a branch name expects. Offer the way out
    # rather than just refusing: stashing is what you were going to do anyway.
    # This guard comes FIRST. Below it the working tree gets stashed, and
    # stashing on top of a half-finished merge consumes the merge itself:
    # MERGE_HEAD disappears, the resolution ends up inside the stash, and the
    # refusal that used to come afterwards told the user nothing had been
    # touched. It had.
    [ -n "$INPROGRESS" ] && fail "$N: cannot switch" \
"A $INPROGRESS is in progress. Finish or abort it first. Nothing was touched."

    STASHED=""
    if [ "$DIRTY" -gt 0 ]; then
      confirm "Stash before switching to ${TARGET#*/}?" \
"$N has $(plural "$DIRTY" "uncommitted change" "uncommitted changes"). They cannot come along.

Continue and they are stashed first, ready to restore with git stash pop. Cancel and nothing is touched." || exit 0
      OUT="$(git -C "$R" stash push -u -m "switch to ${TARGET#*/} $(date +%Y-%m-%d\ %H:%M)" 2>&1)" \
        || fail "$N: could not stash" "$OUT"
      STASHED=1
    fi
    # Ask git what the name is instead of guessing from the slash: local
    # branches are routinely called feature/x, and treating those as remote
    # created a junk branch named after the last segment.
    NEWBRANCH="$TARGET"
    if git -C "$R" show-ref --verify --quiet "refs/heads/$TARGET"; then
      OUT="$(git -C "$R" switch "$TARGET" 2>&1)"
    elif git -C "$R" show-ref --verify --quiet "refs/remotes/$TARGET"; then
      LOCAL="${TARGET#*/}"; NEWBRANCH="$LOCAL"
      if git -C "$R" show-ref --verify --quiet "refs/heads/$LOCAL"; then
        OUT="$(git -C "$R" switch "$LOCAL" 2>&1)"
      else
        OUT="$(git -C "$R" switch -c "$LOCAL" --track "$TARGET" 2>&1)"
      fi
    else
      fail "$N: no such branch" "'$TARGET' is neither a local branch nor a remote-tracking one any more."
    fi
    if [ $? -ne 0 ]; then
      # The stash already happened; say so, or the changes look lost.
      [ -n "$STASHED" ] && fail "$N: could not switch" \
"$OUT

Your changes were stashed and are still there — restore them with a stash pop."
      fail "$N: could not switch" "$OUT"
    fi
    if [ -n "$STASHED" ]; then
      ok "$N" "Now on $NEWBRANCH. Changes stashed, ready to pop."
    else
      ok "$N" "Now on $NEWBRANCH."
    fi
    exit 0 ;;

  delbranch)
    R="$2"; dec "$3"; TARGET="$DEC"; N="$(repo_name "$R")"; read_state "$R"
    [ "$TARGET" = "$BRANCH" ] && fail "$N: cannot delete" \
"'$TARGET' is the branch you are on. Switch somewhere else first."
    # -d is the safe form: git refuses when the branch holds commits that are
    # not merged anywhere, which is exactly the case worth asking about.
    OUT="$(git -C "$R" branch -d "$TARGET" 2>&1)"
    if [ $? -eq 0 ]; then
      ok "$N" "Deleted $TARGET."
      exit 0
    fi
    case "$OUT" in
      *"not fully merged"*)
        confirm "Delete '$TARGET' anyway?" \
"$TARGET has commits that are not merged into any other branch, so deleting it
loses them. They stay in the reflog for a while, but nothing else points at them.

Cancel and the branch is kept." || exit 0
        OUT="$(git -C "$R" branch -D "$TARGET" 2>&1)" || fail "$N: could not delete" "$OUT"
        ok "$N" "Deleted $TARGET, unmerged commits and all."
        ;;
      *) fail "$N: could not delete" "$OUT" ;;
    esac
    exit 0 ;;

  ide)
    R="$2"; N="$(repo_name "$R")"
    # The bar already worked out which IDE suits this project; honour it.
    [ -n "${3:-}" ] && IDE="$3"
    if [ -n "$IDE_CMD" ] && command -v "$IDE_CMD" >/dev/null 2>&1; then
      "$IDE_CMD" "$R" >/dev/null 2>&1 &
    elif [ -n "$IDE" ]; then
      # `open -a` works for any installed app, no CLI launcher required.
      open -a "$IDE" "$R" >/dev/null 2>&1 || fail "$N: could not open $IDE" \
"macOS found no application called '$IDE'.

Set REPOS_IDE in $CONFIG to the name as it appears in /Applications."
    else
      fail "$N: no IDE configured" "Set REPOS_IDE in $CONFIG."
    fi
    exit 0 ;;

esac
# ----------------------------------------------------------------- reading
#
# Two passes: first collect every repo's data so column widths can be computed,
# then paint. Without that the columns do not line up, because the menu uses a
# proportional font unless one is forced.

if ! command -v git >/dev/null 2>&1; then
  echo " | sfimage=exclamationmark.triangle"
  echo "---"
  echo "git not found"
  echo "The plugin runs with a fixed PATH, not your shell's: | $MONO"
  echo "$PATH | $MONO"
  echo "---"
  echo "Refresh | refresh=true"
  exit 0
fi

SEP=$'\037'
DATA=(); ALL_PATHS=""; PENDING=0; W_NAME=0; W_BRANCH=0
N_BEHIND=0; N_AHEAD=0; N_DIRTY=0; N_WARN=0; N_STASH=0; N_BUSY=0; N_CI=0
STALE=""; ON_BRANCH=""

# A flat "root<SEP>repo" list, walking each root separately so the group can be
# computed relative to its own root.
LIST=""
DEEPER=0
COUNTS=""
GONE=""
for ENTRY in "${ROOTS[@]}"; do
  RPATH="${ENTRY%%|*}"; RLABEL=""
  [ "$ENTRY" != "$RPATH" ] && RLABEL="${ENTRY#*|}"
  [ -d "$RPATH" ] || { GONE="$GONE$RPATH$NL"; continue; }

  # A repository one level below the limit is completely invisible, and the
  # menu looks perfectly healthy without it — eleven were missing here before
  # anyone noticed. So the walk goes a few levels past the limit and counts
  # what it finds down there.
  # One walk, split by depth here, where this used to be three over the same
  # tree. -H because BSD find does not descend into a root that is itself a
  # symlink: the bar read "All up to date · 0 repos". .git is pruned so the
  # walk stays out of the object store, a third of everything it visited.
  # Not -type d: in a worktree or a submodule, .git is a FILE pointing at the
  # real git dir. Matching only directories left both invisible.
  N_HERE=0; N_DEEP=0; HERE=""
  # read, not word splitting: a repository under "Client Work" used to render
  # as two phantom rows and never as itself.
  while IFS= read -r G; do
    [ -n "$G" ] || continue
    N_DEEP=$((N_DEEP + 1))
    REL="${G#"$RPATH"}"; REL="${REL#/}"; SLASHES="${REL//[!\/]/}"
    [ "${#SLASHES}" -lt "$DEPTH" ] || continue
    N_HERE=$((N_HERE + 1)); HERE="$HERE${G%/.git}$NL"
  done <<< "$(find -H "$RPATH" -maxdepth $((DEPTH + 3)) \( "${PRUNE[@]}" \) -prune -o \
                  -name .git -prune -print 2>/dev/null)"
  DEEPER=$((DEEPER + N_DEEP - N_HERE))
  # Kept for the Settings section, which used to run this identical find a
  # second time — a tenth of the whole render, for a number already in hand.
  COUNTS="$COUNTS$RPATH$SEP$N_HERE$NL"
  while IFS= read -r R; do
    [ -n "$R" ] || continue
    LIST="$LIST$RPATH$SEP$RLABEL$SEP$R"$'\n'
  done <<< "$(printf '%s' "$HERE" | sort)"
done

# A root that no longer exists was skipped in silence, and the summary below
# then read "All up to date · 0 repos" — a healthy-looking menu for a bar that
# is scanning nothing at all. Moving a workspace is all it takes.
if [ -z "$LIST" ] && [ -n "$GONE" ]; then
  echo " | sfimage=exclamationmark.triangle"
  echo "---"
  echo "Nothing is being scanned"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    echo "$(pretty_path "$g") does not exist | $MONO"
  done <<< "$GONE"
  echo "---"
  settings_menu
  echo "---"
  echo "Refresh | refresh=true"
  exit 0
fi

while IFS="$SEP" read -r RPATH RLABEL R; do
  [ -n "$R" ] || continue
  ALL_PATHS="$ALL_PATHS|$R"
  NAME="${R##*/}"
  # Quoted, or the root is a pattern: under "~/Work [x]" the brackets matched
  # nothing and the group header became the whole absolute path.
  REL="${R#"$RPATH"/}"
  case "$REL" in */*) GROUP="${REL%/*}" ;; *) GROUP="${RPATH%/}"; GROUP="${GROUP##*/}" ;; esac
  [ -n "$RLABEL" ] && GROUP="$RLABEL / $GROUP"

  read_state "$R"
  read_pr "$R" "$BRANCH"
  # What the background rounds will look at: tracked repos whose last fetch is
  # older than the interval, and every repo that is on a branch.
  if [ -n "$UP" ] && { [ -z "$FETCH_AGE" ] || [ "$FETCH_AGE" -ge $((AUTO_FETCH_MIN * 60)) ]; }; then
    STALE="$STALE|$R"
  fi
  [ -n "$BRANCH" ] && ON_BRANCH="$ON_BRANCH|$R"

  [ "$BEHIND" -gt 0 ] && N_BEHIND=$((N_BEHIND + 1))
  [ "$AHEAD"  -gt 0 ] && N_AHEAD=$((N_AHEAD + 1))
  [ "$DIRTY"  -gt 0 ] && N_DIRTY=$((N_DIRTY + 1))
  [ -n "$WARN" ]      && N_WARN=$((N_WARN + 1))
  [ "$STASH"  -gt 0 ] && N_STASH=$((N_STASH + 1))
  [ -n "$INPROGRESS" ] && N_BUSY=$((N_BUSY + 1))
  [ "$PR_CI" = "fail" ] && N_CI=$((N_CI + 1))
  # Stashes do not count towards PENDING: stashing can be deliberate.
  if [ "$BEHIND" -gt 0 ] || [ "$AHEAD" -gt 0 ] || [ "$DIRTY" -gt 0 ] || [ -n "$WARN" ] \
     || [ "$PR_CI" = "fail" ]; then
    PENDING=$((PENDING + 1))
  fi

  SHOWN="${BRANCH:-detached}"; [ -n "$BROKEN" ] && SHOWN="?"
  [ ${#NAME}   -gt "$W_NAME" ]   && W_NAME=${#NAME}
  [ ${#SHOWN}  -gt "$W_BRANCH" ] && W_BRANCH=${#SHOWN}

  DATA+=("$GROUP$SEP$NAME$SEP$SHOWN$SEP$BEHIND$SEP$AHEAD$SEP$DIRTY$SEP$WARN$SEP$R$SEP$BRANCH$SEP$UP$SEP$STASH$SEP$INPROGRESS$SEP$CONFLICTS$SEP$COMMONDIR$SEP$REMOTE$SEP$FETCH_AGE$SEP$UPGONE$SEP$BROKEN")
done <<< "$LIST"

# Background rounds, detached so the menu never waits on the network, at most
# one per interval. Never in the test suite: a fetch landing in the middle of
# it would move the fixtures under its feet.
if [ -z "$REPOS_TEST" ]; then
  if [ "$AUTO_FETCH_MIN" -gt 0 ] && [ -n "$STALE" ] && due autofetch "$AUTO_FETCH_MIN"; then
    ( "$SELF" autofetch "$(b64 "$STALE")" >/dev/null 2>&1 & )
  fi
  if [ "$PR_MIN" -gt 0 ] && [ -n "$ON_BRANCH" ] && command -v gh >/dev/null 2>&1 && due prs "$PR_MIN"; then
    ( "$SELF" refresh-prs "$(b64 "$ON_BRANCH")" >/dev/null 2>&1 & )
  fi
fi

# ------------------------------------------------------------------ menu bar

if [ "$PENDING" -gt 0 ]; then
  echo "$PENDING | sfimage=arrow.triangle.branch"
else
  echo " | sfimage=arrow.triangle.branch"
fi

echo "---"

# One-line summary: only what is actually pending.
SUM=""
[ "$N_BEHIND" -gt 0 ] && SUM="$SUM   ↓ $N_BEHIND behind"
[ "$N_AHEAD"  -gt 0 ] && SUM="$SUM   ↑ $N_AHEAD ahead"
[ "$N_DIRTY"  -gt 0 ] && SUM="$SUM   ● $N_DIRTY with changes"
[ "$N_WARN"   -gt 0 ] && SUM="$SUM   ! $N_WARN with warnings"
[ "$N_STASH"  -gt 0 ] && SUM="$SUM   ⚑ $N_STASH with stash"
[ "$N_BUSY"   -gt 0 ] && SUM="$SUM   ⚠ $N_BUSY mid-operation"
[ "$N_CI"     -gt 0 ] && SUM="$SUM   ✗ $N_CI failing checks"
if [ -n "$SUM" ]; then
  echo "${SUM# } | $MONO"
else
  echo "  All up to date · ${#DATA[@]} repos | $MONO"
fi
if [ "$DEEPER" -gt 0 ]; then
  echo "  ⚠ $(plural "$DEEPER" "repository is" "repositories are") deeper than the search depth of $DEPTH | $MONO"
fi

# Some roots resolved and some did not: the rows below are real but incomplete,
# so the missing ones are named instead of quietly dropped.
if [ -n "$GONE" ]; then
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    echo "  ⚠ $(pretty_path "$g") does not exist | $MONO"
  done <<< "$GONE"
fi

LAST_GROUP=""
for ROW in "${DATA[@]}"; do
  # noglob: the fields are data, and unquoted expansion was matching them
  # against the plugin's own directory — a repo named re[po] rendered as "rep".
  OLDIFS="$IFS"; IFS="$SEP"; set -f; set -- $ROW; set +f; IFS="$OLDIFS"
  GROUP="$1"; NAME="$2"; SHOWN="$3"; BEHIND="$4"; AHEAD="$5"; DIRTY="$6"; WARN="$7"; R="$8"
  # Git allows | in a ref name and SwiftBar splits the line on the first one,
  # so a branch called fea|ture cut the row short and spilled the rest into
  # parameters. Substitute in every field that reaches a title.
  GROUP="${GROUP//|/¦}"; NAME="${NAME//|/¦}"; SHOWN="${SHOWN//|/¦}"; WARN="${WARN//|/¦}"
  BRANCH="$9"; UP="${10}"; STASH="${11:-0}"; INPROGRESS="${12:-}"; CONFLICTS="${13:-0}"; COMMONDIR="${14:-}"; REMOTE="${15:-origin}"; FETCH_AGE="${16:-}"; UPGONE="${17:-}"; BROKEN="${18:-}"

  read_pr "$R" "$BRANCH"

  # A stash counts here even though it does not count towards PENDING: hiding
  # a repository that is holding stashed work would be losing sight of it.
  if [ "$ONLY_PENDING" = "1" ] && [ "$BEHIND" -eq 0 ] && [ "$AHEAD" -eq 0 ] \
     && [ "$DIRTY" -eq 0 ] && [ -z "$WARN" ] && [ "$STASH" -eq 0 ] && [ "$PR_CI" != "fail" ]; then
    HIDDEN=$((HIDDEN + 1))
    continue
  fi

  if [ "$GROUP" != "$LAST_GROUP" ]; then
    echo "---"
    echo "$(echo "$GROUP" | tr '[:lower:]' '[:upper:]') | $MONO"
    LAST_GROUP="$GROUP"
  fi

  # Marker column, right of the branch.
  M=""
  [ "$BEHIND" -gt 0 ] && M="$M ↓$BEHIND"
  [ "$AHEAD"  -gt 0 ] && M="$M ↑$AHEAD"
  [ "$DIRTY"  -gt 0 ] && M="$M ●"
  [ -n "$WARN" ]      && M="$M !"
  [ "$STASH"  -gt 0 ] && M="$M ⚑$STASH"
  [ -n "$INPROGRESS" ] && M="$M ⚠"
  [ "$PR_CI" = "fail" ] && M="$M ✗"

  printf "  %s   %s  %s | $MONO\n" "$(pad "$NAME" "$W_NAME")" "$(pad "$SHOWN" "$W_BRANCH")" "${M# }"

  # ---- submenu: diagnosis first
  [ -n "$WARN" ] && echo "--! $WARN | $MONO"
  [ "$CONFLICTS" -gt 0 ] && echo "--⚠ $(plural "$CONFLICTS" "file with conflicts" "files with conflicts") | $MONO"
  [ "$BEHIND" -gt 0 ] && echo "--↓ $(plural "$BEHIND" "commit to pull" "commits to pull") | $MONO"
  [ "$AHEAD"  -gt 0 ] && echo "--↑ $(plural "$AHEAD" "commit to push" "commits to push") | $MONO"
  [ "$DIRTY"  -gt 0 ] && echo "--● $(plural "$DIRTY" "file changed" "files changed") | $MONO"
  [ "$STASH"  -gt 0 ] && echo "--⚑ $(plural "$STASH" "stashed change" "stashed changes") | $MONO"
  if [ "$BEHIND" -eq 0 ] && [ "$AHEAD" -eq 0 ] && [ "$DIRTY" -eq 0 ] && [ -z "$WARN" ] && [ "$STASH" -eq 0 ] \
     && [ "$PR_CI" != "fail" ]; then
    echo "--Up to date | $MONO"
  fi

  # Behind/ahead are only as fresh as the last fetch, and fetching is manual.
  # Saying so beats quietly reporting "up to date" from week-old data.
  if [ -n "$UP" ]; then
    if [ -z "$FETCH_AGE" ]; then
      echo "--↻ never fetched · counts may be stale | $MONO"
    elif [ "$FETCH_AGE" -ge "$FETCH_STALE" ]; then
      echo "--↻ fetched $(ago "$FETCH_AGE") · counts may be stale | $MONO"
    else
      echo "--↻ fetched $(ago "$FETCH_AGE") | $MONO"
    fi
  fi

  # The pull request for this branch, as the last background lookup saw it.
  # Clicking it opens the PR: that is where the failing check is.
  if [ -n "$PR_N" ]; then
    PRT="⇅ PR #$PR_N"
    [ -n "$PR_DRAFT" ] && PRT="$PRT · draft"
    case "$PR_CI" in
      fail)    PRT="$PRT · checks failing" ;;
      pending) PRT="$PRT · checks running" ;;
      pass)    PRT="$PRT · checks passing" ;;
    esac
    case "$PR_REVIEW" in
      APPROVED)          PRT="$PRT · approved" ;;
      CHANGES_REQUESTED) PRT="$PRT · changes requested" ;;
      REVIEW_REQUIRED)   PRT="$PRT · review required" ;;
    esac
    echo "--$PRT | href=$PR_URL $MONO"
  fi

  # ---- what is actually changed, not just how much
  if [ "$DIRTY" -gt 0 ]; then
    echo "-----"
    NF=0
    while IFS= read -r F; do
      [ -n "$F" ] || continue
      NF=$((NF + 1))
      if [ "$NF" -gt "$MAX_FILES" ]; then
        echo "--  … and $((DIRTY - MAX_FILES)) more | $MONO"
        break
      fi
      echo "--  ${F//|/¦} | $MONO"
    done <<< "$(git -C "$R" status --porcelain 2>/dev/null)"
  fi

  # ---- every stash entry with its commands: clicking one copies it
  if [ "$STASH" -gt 0 ]; then
    echo "-----"
    while IFS="$(printf '\t')" read -r IDX AGE MSG; do
      [ -n "$IDX" ] || continue
      # A stash message or a file name is free text, and the first | in a line
      # is where SwiftBar's parameters start: "wip | refresh=true" was one.
      echo "--stash@{$IDX} · $AGE · ${MSG//|/¦} | $MONO"
      for V in show apply pop; do
        C="$(stash_cmd "$IDX" "$V")"
        enc "$C"
        echo "----$C | bash=\"$SELF\" param1=copy-one param2=\"$R\" param3=$ENC terminal=false sfimage=doc.on.doc $MONO"
      done
    done <<< "$(stash_entries "$COMMONDIR")"
  fi

  # ---- the commands that would resolve this state
  CMDS="$(commands_for "$R")"
  if [ -n "$CMDS" ]; then
    echo "-----"
    echo "--How to fix it | $MONO"
    NCMD=0
    while IFS= read -r C; do
      [ -n "$C" ] || continue
      L="$(strip_comment "$C")"
      if [ -n "$L" ]; then
        NCMD=$((NCMD + 1))
        enc "$L"
        echo "--$C | bash=\"$SELF\" param1=copy-one param2=\"$R\" param3=$ENC terminal=false sfimage=doc.on.doc $MONO"
      else
        echo "--$C | $MONO"
      fi
    done <<< "$CMDS"
    [ "$NCMD" -gt 1 ] && \
      echo "--Copy $(plural "$NCMD" "command" "commands") | bash=\"$SELF\" param1=copy-all param2=\"$R\" terminal=false sfimage=doc.on.doc.fill"
      echo "--Run them in Terminal… | bash=\"$SELF\" param1=runfix param2=\"$R\" terminal=false sfimage=terminal"
  fi

  # ---- actions, only the ones that make sense in this state
  echo "-----"
  if [ -n "$BROKEN" ]; then
    echo "--Branch actions need a repository git can read | $MONO"
  elif [ -n "$INPROGRESS" ]; then
    # Mid-operation every one of these either fails outright or makes things
    # worse: pulling, pushing, stashing a half-resolved tree, branching off it.
    echo "--Finish or abort the $INPROGRESS first | $MONO"
  else
  [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -eq 0 ] && \
    echo "--Update (pull --ff-only) | bash=\"$SELF\" param1=update param2=\"$R\" terminal=false refresh=true"
  [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ] && \
    echo "--Pull and rebase | bash=\"$SELF\" param1=rebase param2=\"$R\" terminal=false refresh=true"
  # Pushing makes sense if there are unsent commits, or if the branch is not on
  # the remote yet. Never with a detached HEAD. UPGONE belongs here too: the
  # branch has an upstream in its config that was never pushed, so AHEAD is 0
  # and UP is set — the row warned about exactly this state and then offered no
  # way out of it.
  if [ -n "$BRANCH" ] && { [ "$AHEAD" -gt 0 ] || [ -z "$UP" ] || [ -n "$UPGONE" ]; }; then
    echo "--Push | bash=\"$SELF\" param1=push param2=\"$R\" terminal=false refresh=true"
  fi
  [ "$DIRTY" -gt 0 ] && \
    echo "--Stash changes | bash=\"$SELF\" param1=stash param2=\"$R\" terminal=false refresh=true"
  [ -n "$WARN" ] && [ -n "$BRANCH" ] && [ "$UP" != "$REMOTE/$BRANCH" ] && \
    echo "--Track ${REMOTE//|/¦}/${BRANCH//|/¦} | bash=\"$SELF\" param1=setupstream param2=\"$R\" terminal=false refresh=true"
  # ---- branches, grouped: local first, then one section per remote.
  #
  # Nothing is hidden. An earlier version dropped every remote branch that had
  # a local of the same name, which reads as "branches are missing" and is
  # plain wrong with two remotes: origin/main and upstream/main are different
  # branches that both shorten to "main".
  #
  # One for-each-ref for both, full refname so the remote can be split off.
  echo "--Switch branch"
  REFS="$(git -C "$R" for-each-ref --format='%(refname)' --sort=-committerdate refs/heads refs/remotes 2>/dev/null)"

  # Real nesting, one level per group. Faking it with indentation and separators
  # does not work: the dash count IS the depth, so a 5-dash separator inside a
  # 4-dash list belongs to the parent menu and scrambles everything after it.
  echo "----local"
  while IFS= read -r ref; do
    case "$ref" in refs/heads/*) ;; *) continue ;; esac
    b="${ref#refs/heads/}"
    if [ "$b" = "$BRANCH" ]; then
      echo "------${b//|/¦}  ✓ | $MONO"
    else
      enc "$b"
      echo "------${b//|/¦} | bash=\"$SELF\" param1=switch param2=\"$R\" param3=$ENC terminal=false refresh=true"
    fi
  done <<< "$REFS"

  # The remote names are already in the refs just fetched, so asking git for
  # them again is a process per repo for something we are holding.
  REMOTES=""
  while IFS= read -r ref; do
    case "$ref" in refs/remotes/*) ;; *) continue ;; esac
    rest="${ref#refs/remotes/}"
    rn="${rest%%/*}"
    case "$NL$REMOTES" in *"$NL$rn$NL"*) continue ;; esac
    REMOTES="$REMOTES$rn$NL"
  done <<< "$REFS"

  while IFS= read -r RNAME; do
    [ -n "$RNAME" ] || continue
    HEADER=""
    while IFS= read -r ref; do
      case "$ref" in refs/remotes/"$RNAME"/*) ;; *) continue ;; esac
      b="${ref#refs/remotes/$RNAME/}"
      # refs/remotes/<remote>/HEAD is a symbolic ref, not a branch.
      [ "$b" = "HEAD" ] && continue
      [ -z "$HEADER" ] && { echo "----${RNAME//|/¦}"; HEADER=1; }
      enc "$RNAME/$b"
      echo "------${b//|/¦} | bash=\"$SELF\" param1=switch param2=\"$R\" param3=$ENC terminal=false refresh=true"
    done <<< "$REFS"
  done <<< "$REMOTES"

  # ---- deleting, local only: removing a remote branch is a push, not a click
  DELETABLE=""
  while IFS= read -r ref; do
    case "$ref" in refs/heads/*) ;; *) continue ;; esac
    b="${ref#refs/heads/}"
    [ "$b" = "$BRANCH" ] && continue
    DELETABLE="$DELETABLE$b"$'\n'
  done <<< "$REFS"
  if [ -n "$DELETABLE" ]; then
    echo "--Delete local branch"
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      enc "$b"
      echo "----${b//|/¦} | bash=\"$SELF\" param1=delbranch param2=\"$R\" param3=$ENC terminal=false refresh=true"
    done <<< "$DELETABLE"
  fi

  echo "-----"
  echo "--Delete branches whose upstream is gone… | bash=\"$SELF\" param1=prunegone param2=\"$R\" terminal=false refresh=true"
  echo "-----"
  echo "--New branch… | bash=\"$SELF\" param1=newbranch param2=\"$R\" terminal=false refresh=true"
  enc "$BRANCH"
  echo "--Rename branch… | bash=\"$SELF\" param1=rename param2=\"$R\" param3=$ENC terminal=false refresh=true"
  fi
  echo "-----"
  echo "--Open in Terminal | bash=\"$SELF\" param1=terminal param2=\"$R\" terminal=false sfimage=terminal"
  echo "--Open on the remote | bash=\"$SELF\" param1=browse param2=\"$R\" terminal=false sfimage=globe"
  if [ -n "$IDE" ] || [ -n "$IDE_CMD" ]; then
    PICK="$(ide_for "$R")"
    echo "--Open in ${PICK:-$IDE_CMD} | bash=\"$SELF\" param1=ide param2=\"$R\" param3=\"$PICK\" terminal=false sfimage=chevron.left.forwardslash.chevron.right"
  fi
done

echo "---"
# base64: the list is | separated and | is SwiftBar's own separator.
ALL_B64="$(b64 "$ALL_PATHS")"
echo "Fetch all | bash=\"$SELF\" param1=fetch-all param2=$ALL_B64 terminal=false refresh=true"
echo "Update all | bash=\"$SELF\" param1=update-all param2=$ALL_B64 terminal=false refresh=true"

# ---- settings, in the bar itself: editing a file to find out why nothing
#      shows up is exactly the wrong moment to have to open an editor.
# The filter hid repositories; say how many, or they have simply vanished.
if [ "$ONLY_PENDING" = "1" ] && [ "$HIDDEN" -gt 0 ]; then
  echo "---"
  echo "$(plural "$HIDDEN" "repo" "repos") up to date, hidden  ·  show all | bash=\"$SELF\" param1=set param2=REPOS_ONLY_PENDING param3=0 terminal=false refresh=true $MONO"
fi

echo "---"
settings_menu

echo "---"
echo "Refresh | refresh=true"
