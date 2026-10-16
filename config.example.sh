# Settings for the SwiftBar bars.
#
# Copy to ~/.config/swiftbar-devkit/config.sh and edit. Everything here is
# optional: without this file the plugins fall back to the defaults shown.
#
# Plain KEY="value" assignments only. The bash plugins source this file; the
# Python one parses it, and it only understands scalars — no logic, no command
# substitution, no arrays other than REPOS_ROOTS.
#
# Being sourced means anything in here is shell code that runs every few
# seconds. The settings menus escape $, backticks and quotes when they write a
# value for you; $HOME is deliberately left working so this file stays portable
# between machines.
#
# You only need the sections for the bars you installed. `bash install.sh` lets
# you pick which ones, and the rest of this file is simply ignored.

# --- repos bar -------------------------------------------------------------

# Where to look for repositories. One entry per root, with an optional label
# after '|' that gets prepended to the group name.
# Default: $HOME/Projects
REPOS_ROOTS=(
  "$HOME/Projects"
  "$HOME/work/repos|WORK"
)

# How deep to search under each root. Default: 4
REPOS_DEPTH=4

# IDE for the "Open in …" item. The application name as it appears in
# /Applications, handed to `open -a`. Leave empty to hide the item.
# Default: empty
REPOS_IDE="PyCharm"

# Optional command-line launcher (JetBrains Toolbox installs these as pycharm,
# idea, goland…). Used instead of REPOS_IDE when it is on PATH.
# Default: empty
REPOS_IDE_CMD=""

# Behind/ahead counts are only as fresh as the last fetch, which is manual.
# Past this many hours the menu says so instead of pretending to be current.
# Default: 24
REPOS_FETCH_STALE_HOURS=24

# How many changed files to list per repo before summarising the rest.
# Default: 10
REPOS_MAX_FILES=10

# Hide repositories that are up to date, so the ones needing attention are not
# buried. Toggled from the bar itself. Default: 0
REPOS_ONLY_PENDING=0

# Fetch every repository in the background once its last fetch is older than
# this many minutes, so behind/ahead stay honest without a click. Never asks
# for a password: a remote that wants one is skipped. 0 turns it off.
# Default: 30
REPOS_AUTO_FETCH_MINUTES=30

# Look up the pull request for each repository's current branch, with its
# checks and review, every this many minutes. Needs gh, signed in; runs in the
# background and the menu reads what it found. 0 turns it off. Default: 5
REPOS_PR_MINUTES=5

# --- dev ports bar ---------------------------------------------------------

# Reverse-domain prefixes trimmed off project names, comma separated. Useful
# when your package.json names look like com.example.my-service.
# Default: empty
DEVPORTS_TRIM_PREFIXES="com.example.,org.example."

# 1 = list only services launched from PyCharm/IntelliJ.
# 0 = also list what was started from a terminal, labelled by origin.
# Default: 0
DEVPORTS_IDE_ONLY=0

# --- colima bar ------------------------------------------------------------

# Container registry the "fix credentials" action tells you to log back into,
# and the environment variable holding the username for it. Leave both empty
# and the action prints a generic placeholder instead.
# Default: empty
COLIMA_REGISTRY="registry.example.com"
COLIMA_REGISTRY_USER_VAR="REGISTRY_USERNAME"

# VM disk usage above this percentage gets a ⚠ in the menu. Default: 80
COLIMA_DISK_WARN=80

# Show CPU and memory per container. Off by default: reading them takes a second
# or two and this bar redraws every fifteen. Cached 30 s. Default: 0
COLIMA_SHOW_STATS=0

# --- llama-swap ------------------------------------------------------------
# The local model server. llama-swap owns llama-server: with `swap: true` in a
# group, loading one model unloads the other, so there is only ever one to
# control.

# Where llama-swap listens. Default: http://127.0.0.1:8083
LLAMA_ADDR="http://127.0.0.1:8083"

# Its own config, the one that declares your models.
# Default: $HOME/.llama-swap/config.yaml
LLAMA_CONFIG="$HOME/.llama-swap/config.yaml"

# Where it writes its log. Default: $HOME/Library/Logs/llama-swap.log
LLAMA_LOG="$HOME/Library/Logs/llama-swap.log"

# The launchd agent that runs it. Default: com.mostlygeek.llama-swap
LLAMA_SERVICE_LABEL="com.mostlygeek.llama-swap"

# --- where the action scripts live -----------------------------------------
# Defaults shown; change if you install them elsewhere.

COLIMA_ACTION="$HOME/.local/bin/colimabar-action"
DEVPORTS_ACTION="$HOME/.local/bin/devports-action"
LLAMA_ACTION="$HOME/.local/bin/llamabar-action"
