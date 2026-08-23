#!/bin/bash
# <swiftbar.title>llama-swap</swiftbar.title>
# <swiftbar.version>v1.0</swiftbar.version>
# <swiftbar.desc>Local model server: the service, which model is loaded, and what it costs</swiftbar.desc>
# <swiftbar.dependencies>bash,curl,jq,llama-swap,llama.cpp</swiftbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# Icon states:
#   circle.dashed             the service is not running
#   square.stack.3d.up        running, no model loaded
#   square.stack.3d.up.fill <model>  running with a model loaded
#   exclamationmark.triangle  running but not answering, or a missing dependency
#
# llama-swap needs llama.cpp: it is llama-server that actually holds the model,
# and llama-swap will install and run happily without it while every load fails.
#
# llama-swap owns the lifecycle of llama-server: with `swap: true` in a group,
# loading one model unloads the other. There is no second service to control —
# only the daemon, and which model it is holding.
# Work in progress, shared as-is, with no warranty of any kind.
# Actions here change real state on this machine — see the README.

[ -n "$ZSH_VERSION" ] && exec /bin/bash "$0" "$@"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LC_ALL=C

CONFIG="${SWIFTBAR_CONFIG:-$HOME/.config/swiftbar-devkit/config.sh}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

ADDR="${LLAMA_ADDR:-http://127.0.0.1:8083}"
SWAP_CONFIG="${LLAMA_CONFIG:-$HOME/.llama-swap/config.yaml}"
LOG="${LLAMA_LOG:-$HOME/Library/Logs/llama-swap.log}"
LABEL="${LLAMA_SERVICE_LABEL:-com.mostlygeek.llama-swap}"
ACTION="${LLAMA_ACTION:-$HOME/.local/bin/llamabar-action}"

MONO="font=Menlo size=11"
CACHE="${TMPDIR:-/tmp}/llamabar"
mkdir -p "$CACHE"

# Loading a 13 GB model takes minutes with no window to watch, so the action
# leaves a marker and the menu says what is going on instead of looking dead.
OPERATION=""
if [ -f "$CACHE/operation" ]; then
  if [ $(( $(date +%s) - $(stat -f %m "$CACHE/operation") )) -lt 1800 ]; then
    OPERATION="$(cat "$CACHE/operation" 2>/dev/null)"
  else
    rm -f "$CACHE/operation"
  fi
fi

sep() { echo "---"; }

settings_menu() {
  echo "---"
  echo "Settings | sfimage=gearshape"
  if [ -f "$CONFIG" ]; then
    echo "--${CONFIG/#$HOME/~} | $MONO"
  else
    echo "--⚠ no config file yet · using defaults | $MONO"
  fi
  echo "--Open config file | bash=\"$ACTION\" param1=openconfig terminal=false"
  echo "-----"
  echo "--Endpoint: $ADDR | $MONO"
  echo "--Service: $LABEL | $MONO"
  echo "--llama-swap config: ${SWAP_CONFIG/#$HOME/~} | $MONO"
  echo "-----"
  if command -v llama-swap >/dev/null 2>&1; then
    echo "--llama-swap $(llama-swap --version 2>/dev/null | awk '/version/{print $2; exit}') · $(command -v llama-swap) | $MONO"
  else
    echo "--⚠ llama-swap not found on PATH | $MONO"
  fi
  echo "--Edit llama-swap config… | bash=\"$ACTION\" param1=editswap terminal=false"
  echo "--View log… | bash=\"$ACTION\" param1=logs terminal=false"
  echo "--Copy base URL | bash=\"$ACTION\" param1=copyurl terminal=false sfimage=doc.on.doc"
}

# ------------------------------------------------------------ dependencies

# jq is used for every model row. Without it the old version rendered an empty
# list and looked like "no models", which is a lie: the daemon was fine.
if ! command -v jq >/dev/null 2>&1; then
  echo " | sfimage=exclamationmark.triangle"
  sep
  echo "jq is not installed"
  echo "--This bar parses the llama-swap API with jq. | $MONO"
  echo "--Install it with:  brew install jq | $MONO"
  settings_menu
  sep
  echo "Refresh | refresh=true"
  exit 0
fi

# ------------------------------------------------------------------- state

HEALTH="$(curl -s -m 2 "$ADDR/health" 2>/dev/null)"
LOADED_IN_LAUNCHD=0
launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && LOADED_IN_LAUNCHD=1

if [ "$HEALTH" != "OK" ]; then
  # Registered but not answering is a different problem from not registered at
  # all: one needs starting, the other needs looking at the log.
  if [ "$LOADED_IN_LAUNCHD" -eq 1 ]; then
    echo " | sfimage=exclamationmark.triangle"
    sep
    echo "Service registered but not answering"
    echo "--launchd has $LABEL loaded, yet $ADDR/health does not reply. | $MONO"
    if [ -n "$OPERATION" ]; then
      echo "$OPERATION | $MONO"
    else
      echo "Restart the service | bash=\"$ACTION\" param1=svcrestart terminal=false refresh=true"
      echo "Stop the service… | bash=\"$ACTION\" param1=svcstop terminal=false refresh=true"
    fi
  else
    echo " | sfimage=circle.dashed"
    sep
    echo "Service stopped"
    if [ -n "$OPERATION" ]; then
      echo "$OPERATION | $MONO"
    else
      echo "Start the service | bash=\"$ACTION\" param1=svcstart terminal=false refresh=true"
    fi
  fi
  settings_menu
  sep
  echo "Refresh | refresh=true"
  exit 0
fi

MODELS_JSON="$(curl -s -m 3 "$ADDR/models" 2>/dev/null)"
# A daemon that answers /health but not /models is mid-restart or wedged. Say
# so rather than drawing an empty model list.
if ! printf '%s' "$MODELS_JSON" | jq -e '.data' >/dev/null 2>&1; then
  echo " | sfimage=exclamationmark.triangle"
  sep
  echo "Answering, but the model list is unreadable"
  echo "--$ADDR/models returned nothing usable. | $MONO"
  echo "Restart the service | bash=\"$ACTION\" param1=svcrestart terminal=false refresh=true"
  echo "View log… | bash=\"$ACTION\" param1=logs terminal=false"
  settings_menu
  sep
  echo "Refresh | refresh=true"
  exit 0
fi

LOADED="$(printf '%s' "$MODELS_JSON" | jq -r '[.data[]|select(.status.value=="loaded")|.id]|join(", ")')"
SVC_PID="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/^\tpid = /{print $3}')"

MET="$(curl -s -m 3 "$ADDR/metrics" 2>/dev/null)"
RAM_USED="$(printf '%s' "$MET" | awk '/^llamaswap_memory_used_bytes/{printf "%.1f", $2/1073741824}')"
RAM_TOT="$(printf '%s' "$MET" | awk '/^llamaswap_memory_total_bytes/{printf "%.0f", $2/1073741824}')"
GPU="$(printf '%s' "$MET" | awk -F'} ' '/^llamaswap_gpu_util_percent/{printf "%.0f", $2}')"
SWAPUSE="$(sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}')"

# --------------------------------------------------------------- menu bar

if [ -n "$LOADED" ]; then
  echo "$LOADED | sfimage=square.stack.3d.up.fill"
else
  echo " | sfimage=square.stack.3d.up"
fi

sep
echo "llama-swap${SVC_PID:+ · PID $SVC_PID}"
echo "--$ADDR | $MONO"
[ -n "$RAM_TOT" ] && echo "--RAM ${RAM_USED:-?} / ${RAM_TOT} GB  ·  GPU ${GPU:-0}%  ·  swap ${SWAPUSE:-?} | $MONO"

# ------------------------------------------------------------------ models

sep
if [ -n "$OPERATION" ]; then
  echo "$OPERATION | $MONO"
else
  echo "Models"
fi

while IFS= read -r M; do
  [ -z "$M" ] || [ "$M" = "null" ] && continue
  STATE="$(printf '%s' "$MODELS_JSON" | jq -r --arg m "$M" '.data[]|select(.id==$m)|.status.value')"
  case "$STATE" in
    loaded)
      echo "--● $M"
      # The context window in use is the number that decides whether the next
      # request fits, so it belongs next to the model, not buried in /slots.
      SLOT="$(curl -sL -m 3 "$ADDR/upstream/$M/slots" 2>/dev/null)"
      NCTX="$(printf '%s' "$SLOT" | jq -r '.[0].n_ctx // "?"' 2>/dev/null)"
      USED="$(printf '%s' "$SLOT" | jq -r '.[0].n_past // .[0].n_prompt_tokens // 0' 2>/dev/null)"
      [ "$NCTX" != "?" ] && echo "----ctx ${USED:-0} / $NCTX | $MONO"
      echo "----Unload | bash=\"$ACTION\" param1=unloadone param2=\"$M\" terminal=false refresh=true"
      echo "----Open /slots | href=$ADDR/upstream/$M/slots"
      ;;
    loading|starting)
      echo "--◍ $M  ·  $STATE… | $MONO"
      ;;
    *)
      echo "--○ $M"
      # Confirmed in the action: the group is exclusive, so loading this one
      # evicts whatever is currently held.
      echo "----Load… | bash=\"$ACTION\" param1=load param2=\"$M\" terminal=false refresh=true"
      ;;
  esac
done <<< "$(printf '%s' "$MODELS_JSON" | jq -r '.data[].id')"

if [ -n "$LOADED" ]; then
  echo "--Unload everything | bash=\"$ACTION\" param1=unload terminal=false refresh=true"
fi

# ----------------------------------------------------------------- service

sep
echo "Service"
if [ -n "$OPERATION" ]; then
  echo "--$OPERATION | $MONO"
else
  echo "--Restart | bash=\"$ACTION\" param1=svcrestart terminal=false refresh=true"
  echo "--Stop… | bash=\"$ACTION\" param1=svcstop terminal=false refresh=true"
fi
echo "Open web UI | bash=\"$ACTION\" param1=ui terminal=false sfimage=globe"

settings_menu
sep
echo "Refresh | refresh=true"
