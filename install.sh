#!/bin/bash
# Sets everything up: installs SwiftBar if needed, links the bars, asks where
# your repositories live, and starts SwiftBar pointing at the right folder.
#
#   bash install.sh              install
#   bash install.sh --uninstall  remove the symlinks, keep your config
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
# SWIFTBAR_CONFIG, like every bar honours: without it a test run against a
# temporary BIN_DIR rewrites the REAL config's action paths, and every button
# in every bar then points at a directory that is about to be deleted. The
# bars fail silently when that happens, which makes it a nasty one to find.
CONFIG="${SWIFTBAR_CONFIG:-$HOME/.config/swiftbar-devkit/config.sh}"
CONFIG_DIR="$(dirname "$CONFIG")"

# Arrays, not space-separated strings: `for f in $VAR` only splits into words
# under bash. Run with zsh it would loop once over the whole string and create
# a single broken symlink named after all three files at once.
PLUGINS=(repos.60s.sh colima.15s.sh devports.15s.py llama.5s.sh)
ACTIONS=(colimabar-action devports-action llamabar-action)

# One entry per bar, in the order they are offered. Parallel arrays rather than
# one associative array: macOS ships bash 3.2, which has none.
BAR_NAME=("Repos"        "Dev ports"       "Colima"            "llama-swap")
BAR_PLUGIN=(repos.60s.sh devports.15s.py   colima.15s.sh       llama.5s.sh)
BAR_ACTION=(""           devports-action   colimabar-action    llamabar-action)
BAR_WHAT=("git state across your repositories" \
          "services still holding a local port" \
          "the container VM and everything in it" \
          "the local model server")
# Extra tools each bar needs, beyond what macOS already has. Empty means none.
# llama-swap has no Homebrew dependencies of its own and will happily install
# without llama.cpp — and then every model load fails, because llama-server is
# what it actually runs.
BAR_NEEDS=(""            ""                "colima"            "llama-swap llama-server jq")

# bash arrays start at 0, zsh arrays start at 1, and this script has to survive
# `zsh install.sh`. Indexing them directly silently picked the wrong entry
# there, so every menu selection goes through this instead. It also rejects 0,
# which in bash 3.2 means index -1 — a hard error that killed the whole run.
pick_nth() {   # $1=1-based choice  rest=the options
  local n="$1"; shift
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -lt 1 ] && return 1
  [ "$n" -gt "$#" ] && return 1
  eval "printf '%s' \"\${$n}\""
}

# Where SwiftBar actually looks. An unset preference means it has never been
# pointed at a folder, which is the usual reason for an install that reports
# success and shows no bars at all.
SWIFTBAR_PREF="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -n "${SWIFTBAR_PLUGIN_DIR:-}" ]; then
  PLUGIN_DIR="$SWIFTBAR_PLUGIN_DIR"
elif [ -n "$SWIFTBAR_PREF" ]; then
  PLUGIN_DIR="$SWIFTBAR_PREF"
else
  PLUGIN_DIR="$HOME/.swiftbar"
fi

INTERACTIVE=0; [ -t 0 ] && INTERACTIVE=1
# Overridable so the prompts can be exercised by a test: piping answers in
# removes the tty, which is exactly what the tty check is looking for.
INTERACTIVE="${INSTALL_FORCE_INTERACTIVE:-$INTERACTIVE}"

# Overridable so the install paths can be exercised by a test without actually
# installing or removing an application.
SWIFTBAR_APP="${SWIFTBAR_APP:-/Applications/SwiftBar.app}"
DOCKER_APP="${DOCKER_APP:-/Applications/Docker.app}"

# ------------------------------------------------------------------ uninstall

if [ "${1:-}" = "--uninstall" ]; then
  for f in "${PLUGINS[@]}"; do
    [ -L "$PLUGIN_DIR/$f" ] && rm -f "$PLUGIN_DIR/$f" && echo "removed $PLUGIN_DIR/$f"
  done
  for f in "${ACTIONS[@]}"; do
    [ -L "$BIN_DIR/$f" ] && rm -f "$BIN_DIR/$f" && echo "removed $BIN_DIR/$f"
  done
  echo
  echo "Your settings in $CONFIG_DIR were left alone."
  exit 0
fi

# -------------------------------------------------------------- config edits

# Rewrites one key in config.sh in place. python3 rather than sed because
# REPOS_ROOTS is a multi-line array, which sed handles badly. Values are
# escaped: config.sh is sourced by every bar every few seconds, so an
# unescaped $(…) in a path would re-execute forever.
set_config() {   # $1=key  $2=value, or for arrays: $2.. = the entries
  local key="$1"; shift
  python3 - "$CONFIG" "$key" "$@" <<'PY'
import re, sys
path, key, values = sys.argv[1], sys.argv[2], sys.argv[3:]

def quote(v):
    # $HOME is meant to survive; anything else that the shell would act on is not.
    out = v.replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`")
    return re.sub(r'\$(?!HOME\b)', r'\\$', out)

txt = open(path).read()
if key.endswith("[]"):
    key = key[:-2]
    block = key + "=(\n" + "".join('  "%s"\n' % quote(v) for v in values) + ")"
    pat = re.compile(r'^%s=\(.*?^\)' % re.escape(key), re.M | re.S)
else:
    block = '%s="%s"' % (key, quote(values[0]))
    pat = re.compile(r'^%s=.*$' % re.escape(key), re.M)
txt = pat.sub(lambda _: block, txt, count=1) if pat.search(txt) else txt.rstrip() + "\n" + block + "\n"
open(path, "w").write(txt)
PY
}

# Writes paths under the home directory as $HOME/... so the file survives being
# copied to a teammate's machine.
portable_path() { case "$1" in "$HOME"/*) echo "\$HOME/${1#$HOME/}" ;; *) echo "$1" ;; esac; }

# --------------------------------------------------------------- SwiftBar

# git and python3 both come with Apple's Command Line Tools. The installer is a
# system dialog, so this waits for it — but with a deadline, because cancelling
# that dialog used to leave the loop spinning silently forever.
if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "Installing Apple's Command Line Tools — accept the dialog that opens."
  xcode-select --install >/dev/null 2>&1 || true
  WAITED=0
  until command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; do
    sleep 5; WAITED=$((WAITED + 5))
    if [ "$WAITED" -ge 900 ]; then
      echo "error: still no git and python3 after 15 minutes." >&2
      echo "Install the Command Line Tools, then run this again:  xcode-select --install" >&2
      exit 1
    fi
  done
  echo "Command Line Tools ready."
fi

# Homebrew, only if it is missing. Its own installer asks for your password.
if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew — it will ask for your password."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Newly installed brew is not on PATH in this shell yet.
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && eval "$("$p" shellenv)"
  done
fi
command -v brew >/dev/null 2>&1 || { echo "error: Homebrew is still not available" >&2; exit 1; }

[ -d "$SWIFTBAR_APP" ] || { echo "Installing SwiftBar…"; brew install --cask swiftbar; }

# ----------------------------------------------------------------- selection

# Which bars to install. Everything by default, including when there is no
# terminal to ask in — `curl | bash` and CI must not stall on a prompt.
SELECTED=()
choose_bars() {
  local i n
  if [ "$INTERACTIVE" != "1" ]; then
    for i in $(seq 1 ${#BAR_NAME[@]}); do SELECTED+=("$i"); done
    return
  fi
  echo
  echo "Which bars do you want?"
  echo
  for i in $(seq 1 ${#BAR_NAME[@]}); do
    n="$(pick_nth "$i" "${BAR_NAME[@]}")"
    printf '  %d) %-11s %s' "$i" "$n" "$(pick_nth "$i" "${BAR_WHAT[@]}")"
    [ -n "$(pick_nth "$i" "${BAR_NEEDS[@]}")" ] && \
      printf '\n     %s' "needs $(pick_nth "$i" "${BAR_NEEDS[@]}")"
    echo
  done
  echo
  printf "All of them by default. Numbers separated by spaces, or 'all': "
  read -r reply || reply=""
  # Commas are the other thing people type, so accept both.
  reply="$(printf '%s' "$reply" | tr ',' ' ')"
  case "$reply" in
    ""|all|ALL|a)
      for i in $(seq 1 ${#BAR_NAME[@]}); do SELECTED+=("$i"); done ;;
    none|NONE)
      echo "Nothing selected — no bars will be linked." ;;
    *)
      for i in $reply; do
        if pick_nth "$i" "${BAR_NAME[@]}" >/dev/null 2>&1; then
          SELECTED+=("$i")
        else
          echo "  ignoring '$i': not one of the choices"
        fi
      done
      # An `[ … ] && { … }` here would be the last command of the branch, and
      # when the test is false the whole function returns 1 — which under
      # `set -e` kills the installer right after the prompt.
      if [ "${#SELECTED[@]}" -eq 0 ]; then
        echo "  nothing valid was selected; taking all of them"
        for i in $(seq 1 ${#BAR_NAME[@]}); do SELECTED+=("$i"); done
      fi
      ;;
  esac
}
choose_bars

# Convenience: does the selection include the bar with this 1-based number?
selected() { local i; for i in ${SELECTED[@]+"${SELECTED[@]}"}; do [ "$i" = "$1" ] && return 0; done; return 1; }

# ------------------------------------------------------------------- linking

mkdir -p "$PLUGIN_DIR" "$BIN_DIR" "$CONFIG_DIR"

# Symlinks, not copies: one source of truth, and `git pull` updates the bars.
# Anything already there is moved aside, never overwritten — including symlinks,
# because pointing a plugin at your own dotfiles is a normal thing to do and
# only our own link is safe to replace.
link() {   # $1=source  $2=destination
  [ -e "$1" ] || { echo "error: $1 is missing from the repository" >&2; exit 1; }
  if [ -e "$2" ] || [ -L "$2" ]; then
    if [ "$(readlink "$2" 2>/dev/null)" != "$1" ]; then
      mv "$2" "$2.backup-$(date +%Y%m%d%H%M%S)"
      echo "moved the existing $2 aside"
    fi
  fi
  ln -sfn "$1" "$2"
}

LINKED=0
for i in ${SELECTED[@]+"${SELECTED[@]}"}; do
  f="$(pick_nth "$i" "${BAR_PLUGIN[@]}")"
  link "$REPO/plugins/$f" "$PLUGIN_DIR/$f"
  a="$(pick_nth "$i" "${BAR_ACTION[@]}")"
  [ -n "$a" ] && link "$REPO/bin/$a" "$BIN_DIR/$a"
  LINKED=$((LINKED + 1))
done

# A bar that was linked before and is not in this selection stays where it is:
# removing something the user did not ask to remove is not this script's job.
for i in $(seq 1 ${#BAR_NAME[@]}); do
  selected "$i" && continue
  f="$(pick_nth "$i" "${BAR_PLUGIN[@]}")"
  [ -L "$PLUGIN_DIR/$f" ] && \
    echo "$(pick_nth "$i" "${BAR_NAME[@]}") is already installed and was not selected — left alone."
done
# find, not globs: an absent directory makes zsh abort the whole chmod.
find "$REPO/plugins" "$REPO/bin" -type f -exec chmod +x {} + 2>/dev/null || true
find "$REPO/test" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

# A broken link shows up as no bar at all, with no error anywhere.
for i in ${SELECTED[@]+"${SELECTED[@]}"}; do
  f="$(pick_nth "$i" "${BAR_PLUGIN[@]}")"
  [ -e "$PLUGIN_DIR/$f" ] || { echo "error: $PLUGIN_DIR/$f does not resolve" >&2; exit 1; }
done
echo "Linked $LINKED $([ "$LINKED" = 1 ] && echo bar || echo bars) into $PLUGIN_DIR"

# -------------------------------------------------------------------- config

if [ -f "$CONFIG" ]; then
  echo "Kept your existing $CONFIG"
  FRESH=0
else
  cp "$REPO/config.example.sh" "$CONFIG"
  echo "Created $CONFIG"
  FRESH=1
fi

# shellcheck source=/dev/null
. "$CONFIG" 2>/dev/null || true

# The action scripts default to ~/.local/bin. With BIN_DIR pointing elsewhere
# the bars would keep emitting the default and every click would do nothing.
if [ "$BIN_DIR" != "$HOME/.local/bin" ]; then
  selected 2 && set_config DEVPORTS_ACTION "$(portable_path "$BIN_DIR/devports-action")"
  selected 3 && set_config COLIMA_ACTION   "$(portable_path "$BIN_DIR/colimabar-action")"
  selected 4 && set_config LLAMA_ACTION    "$(portable_path "$BIN_DIR/llamabar-action")"
fi

roots_ok() {
  local r
  for r in "${REPOS_ROOTS[@]}"; do [ -d "${r%%|*}" ] && return 0; done
  return 1
}

# Where people actually keep repositories. Only offered if the directory holds
# at least one, so an empty ~/Projects is not suggested.
# Deduplicated by inode: the default macOS filesystem is case-insensitive, so
# ~/Repos and ~/repos are the same directory and would otherwise be offered
# twice as if they were a choice.
detect_roots() {
  local d n key seen=""
  for d in "$HOME/Repos" "$HOME/repos" "$HOME/Projects" "$HOME/projects" \
           "$HOME/Workspace" "$HOME/workspace" "$HOME/Developer" "$HOME/dev" \
           "$HOME/src" "$HOME/code" "$HOME/git"; do
    [ -d "$d" ] || continue
    key="$(stat -f '%d:%i' "$d" 2>/dev/null)"
    case " $seen " in *" $key "*) continue ;; esac
    seen="$seen $key"
    n="$(find "$d" -maxdepth 3 -name .git -print -quit 2>/dev/null)"
    [ -n "$n" ] && echo "$d"
  done
}

# Only the Repos bar uses these, so there is no reason to ask otherwise.
if selected 1 && { [ "$FRESH" = "1" ] || ! roots_ok; }; then
  echo
  CANDIDATES=()
  while IFS= read -r line; do [ -n "$line" ] && CANDIDATES+=("$line"); done <<< "$(detect_roots)"

  if [ "$INTERACTIVE" = "1" ]; then
    if [ "${#CANDIDATES[@]}" -gt 0 ]; then
      echo "Found repositories in:"
      i=1
      for d in "${CANDIDATES[@]}"; do
        printf '  %d) %s  (%s repositories)\n' "$i" "${d/#$HOME/~}" \
          "$(find "$d" -maxdepth 3 -name .git 2>/dev/null | grep -c .)"
        i=$((i + 1))
      done
      printf 'Which one? [1, or type another path]: '
    else
      printf 'Where do you keep your repositories? [path]: '
    fi
    read -r answer || answer=""
    [ -z "$answer" ] && answer="1"
    CHOSEN=""
    case "$answer" in
      # Digits only, otherwise it is a path: "2ndbrain/repos" is a folder name.
      *[!0-9]*) CHOSEN="${answer/#\~/$HOME}" ;;
      *)        CHOSEN="$(pick_nth "$answer" "${CANDIDATES[@]}" 2>/dev/null || true)" ;;
    esac
    if [ -n "$CHOSEN" ] && [ -d "$CHOSEN" ]; then
      set_config "REPOS_ROOTS[]" "$(portable_path "$CHOSEN")"
      echo "Set REPOS_ROOTS to $(portable_path "$CHOSEN")"
    else
      echo "warning: '$answer' is not one of the choices or a folder that exists."
      echo "  Edit REPOS_ROOTS in $CONFIG, or use Settings in the bar."
    fi

  else
    echo "warning: REPOS_ROOTS does not point anywhere that exists."
    echo "  Edit $CONFIG — this run was not interactive, so it was left alone."
  fi
fi

# The IDE for "Open in …". The Repos bar uses it for a repository and the Dev
# ports bar for a service's project, so either one is reason enough to ask.
if [ "$INTERACTIVE" = "1" ] && { selected 1 || selected 2; }; then
  # The IDE the "Open in …" item uses. Only the ones actually installed.
  IDES=()
  for app in "PyCharm" "IntelliJ IDEA" "GoLand" "WebStorm" "PhpStorm" \
             "RubyMine" "Visual Studio Code" "Cursor" "Zed"; do
    [ -d "/Applications/$app.app" ] && IDES+=("$app")
  done
  if [ "${#IDES[@]}" -gt 0 ]; then
    echo
    echo "Editors installed:"
    i=1
    for a in "${IDES[@]}"; do printf '  %d) %s\n' "$i" "$a"; i=$((i + 1)); done
    printf 'Which one for "Open in …"? [1, or Enter to skip]: '
    read -r answer || answer=""
    if [ -n "$answer" ]; then
      pick="$(pick_nth "$answer" "${IDES[@]}" 2>/dev/null || true)"
      if [ -n "$pick" ]; then
        set_config REPOS_IDE "$pick"; echo "Set REPOS_IDE to $pick"
      else
        echo "warning: '$answer' is not one of the choices. REPOS_IDE left as it was."
      fi
    fi
  fi
fi

# --------------------------------------------------------- container runtime
#
# Deliberately after the bars are installed and configured: Colima is optional,
# and a failure here used to abort the whole run under set -e, leaving someone
# with no bars at all because an extra they did not need would not install.
set +e

# Docker Desktop and Colima both provide `docker`. Flagged, never touched:
# removing it deletes every image and volume it holds, and that is not this
# script's call to make.
if [ -d "$DOCKER_APP" ]; then
  echo "Docker Desktop is installed."
  echo
  echo "  It and Colima both provide the \`docker\` command, and running both is a"
  echo "  steady source of confusion: which daemon answered depends on the context"
  echo "  you happen to have selected."
  echo
  echo "  Consider removing it if you are moving to Colima — Docker's own"
  echo "  documentation covers how. This installer will not touch it."
  echo
fi

# The command you look for is not always the formula that provides it.
formula_for() {
  case "$1" in
    llama-server) echo "llama.cpp" ;;
    *)            echo "$1" ;;
  esac
}

# What the bars you picked need and this machine does not have. Asked once, as
# a single list, rather than one prompt per tool.
MISSING=()
for i in ${SELECTED[@]+"${SELECTED[@]}"}; do
  for tool in $(pick_nth "$i" "${BAR_NEEDS[@]}"); do
    command -v "$tool" >/dev/null 2>&1 && continue
    case " ${MISSING[*]-} " in *" $tool "*) ;; *) MISSING+=("$tool") ;; esac
  done
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "The bars you selected need these, and they are not installed:"
  for tool in "${MISSING[@]}"; do
    case "$tool" in
      colima)       echo "  colima        the container VM the Colima bar controls" ;;
      llama-swap)   echo "  llama-swap    the model server the llama-swap bar controls" ;;
      llama-server) echo "  llama.cpp     what llama-swap actually runs; without it every" ;
                    echo "                model load fails" ;;
      jq)           echo "  jq            the llama-swap bar parses its API with it" ;;
      *)          echo "  $tool" ;;
    esac
  done
  echo
  if [ "$INTERACTIVE" = "1" ]; then
    printf 'Install them now with Homebrew? [Y/n]: '
    read -r reply || reply=""
    case "$reply" in
      n|N|no|NO)
        echo "Skipped. The bars that need them will say so until you do:"
        FORMULAE=""; for tool in "${MISSING[@]}"; do FORMULAE="$FORMULAE $(formula_for "$tool")"; done
        echo "  brew install$FORMULAE"
        ;;
      *)
        # The docker CLI comes with colima's usefulness, not with colima itself.
        FORMULAE=""
        for tool in "${MISSING[@]}"; do FORMULAE="$FORMULAE $(formula_for "$tool")"; done
        case " ${MISSING[*]} " in *" colima "*) FORMULAE="$FORMULAE docker docker-compose" ;; esac
        if brew install $FORMULAE; then
          echo "Installed."
          # The launchd agent runs `colima start -f` and IS the service, so the
          # VM has to be down when it takes over. Registering first and letting
          # the agent bring the VM up avoids the relaunch loop that leaves
          # `brew services list` saying "stopped" forever.
          if command -v colima >/dev/null 2>&1 && selected 3; then
            echo "Registering Colima to start at login and bringing the VM up…"
            brew services start colima || \
              echo "Could not register the service. Start it by hand:  colima start"
          fi
        else
          echo "Some of them did not install. The bars will say which are missing."
        fi
        ;;
    esac
  else
    echo "Not running interactively, so nothing was installed. When you can:"
    FORMULAE=""; for tool in "${MISSING[@]}"; do FORMULAE="$FORMULAE $(formula_for "$tool")"; done
    echo "  brew install$FORMULAE"
  fi
  echo
fi

set -e

# ------------------------------------------------------------------ start it

# Everything past this point touches the machine outside this repository: it
# rewrites SwiftBar's own preferences and restarts the app.
#
# INSTALL_NO_SYSTEM_CHANGES=1 stops exactly here. Running this script against a
# temporary plugin directory — which is the only sane way to test it — otherwise
# repoints the REAL SwiftBar at that directory, and when the directory goes away
# so do all of the user's bars. Learned the hard way.
if [ -n "${INSTALL_NO_SYSTEM_CHANGES:-}" ]; then
  echo
  echo "INSTALL_NO_SYSTEM_CHANGES is set: leaving SwiftBar's preferences and the"
  echo "app itself alone. The symlinks above were still created."
  exit 0
fi

# Preferences written while SwiftBar runs get undone when it quits, so anything
# set here happens with it closed and takes effect on the next launch.
PREF_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
NEEDS_PREFS=""
[ "$PREF_DIR" = "$PLUGIN_DIR" ] || NEEDS_PREFS=1
[ "$(defaults read com.ameba.SwiftBar StealthMode 2>/dev/null)" = "1" ] || NEEDS_PREFS=1

if [ -n "$NEEDS_PREFS" ]; then
  pgrep -x SwiftBar >/dev/null 2>&1 && { osascript -e 'quit app "SwiftBar"' >/dev/null 2>&1 || true; sleep 1; }
  if [ "$PREF_DIR" != "$PLUGIN_DIR" ]; then
    defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR"
    echo "Pointed SwiftBar at $PLUGIN_DIR"
  fi
  # Its own icon adds nothing once the bars are there. Set once and not forced
  # again, so turning it back on stays turned on:
  #   defaults write com.ameba.SwiftBar StealthMode -bool false
  if [ -z "$(defaults read com.ameba.SwiftBar StealthMode 2>/dev/null)" ]; then
    defaults write com.ameba.SwiftBar StealthMode -bool true
    echo "Hid SwiftBar's own menu bar icon"
  fi
fi

# Launch at login. SwiftBar drives this through a bundled helper that cannot be
# set with `defaults`, so it goes in as a normal login item — the same thing
# System Settings › General › Login Items shows. Adding it twice would show it
# twice, hence the check. The first run may ask to control System Events.
if ! osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q "$(basename "$SWIFTBAR_APP" .app)"; then
  if osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$SWIFTBAR_APP\", hidden:false}" >/dev/null 2>&1; then
    echo "Set SwiftBar to start at login"
  else
    echo "Could not add SwiftBar to your login items — add it by hand in"
    echo "System Settings › General › Login Items, or from SwiftBar's own preferences."
  fi
fi

# Never fatal: right after installing SwiftBar, Launch Services may not have
# indexed it yet, and dying here would skip the summary and report failure.
if open -a "$SWIFTBAR_APP" 2>/dev/null; then
  sleep 2
  # An already-running SwiftBar will not notice new plugin files on its own.
  open "swiftbar://refreshallplugins" >/dev/null 2>&1 || true
else
  echo "Could not launch SwiftBar automatically — open it yourself."
fi

echo
echo "Done. The bars are in your menu bar."
echo "Settings: $CONFIG"
