#!/bin/bash
# <swiftbar.title>Colima</swiftbar.title>
# <swiftbar.version>v2.0</swiftbar.version>
# <swiftbar.desc>Colima and Docker container status and controls</swiftbar.desc>
# <swiftbar.dependencies>bash,colima,docker</swiftbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# Icon states:
#   circle.dashed          nothing running
#   shippingbox            service registered, VM stopped
#   shippingbox.fill N     VM up (N = running containers)
#   exclamationmark.triangle  VM up but docker is not answering

# Work in progress, shared as-is, with no warranty of any kind.
# Actions here change real state on this machine — see the README.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export LC_ALL=C

CACHE="${TMPDIR:-/tmp}/colimabar"
mkdir -p "$CACHE"

CONFIG="${SWIFTBAR_CONFIG:-$HOME/.config/swiftbar-devkit/config.sh}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

ACTION="${COLIMA_ACTION:-$HOME/.local/bin/colimabar-action}"
DISK_WARN="${COLIMA_DISK_WARN:-80}"   # VM disk warning threshold (%)
# Off by default on purpose: `docker stats --no-stream` takes a second or two,
# and this bar redraws every fifteen. Turn it on and it is cached for 30 s, so
# the numbers are a recent sample rather than a live reading.
SHOW_STATS="${COLIMA_SHOW_STATS:-0}"
STATS_TTL=30
SLOW_TTL=300                          # cache TTL for the slow lookups (s)

MONO="font=Menlo size=11"

# Long actions run with terminal=false, with no window to show signs of life.
# They leave a marker here so the menu can say what is going on instead of
# looking like the click did nothing. It carries the action's PID: expiring it
# after 300 s hid a first start still pulling its image, and kept a dead
# action's marker up for five minutes.
OPERATION=""
if [[ -f "$CACHE/operation" ]]; then
  read -r OP_PID OP_MSG < "$CACHE/operation"
  if [[ "$OP_PID" =~ ^[0-9]+$ ]] && kill -0 "$OP_PID" 2>/dev/null; then
    OPERATION="$OP_MSG"
  else
    rm -f "$CACHE/operation"
  fi
fi

# ----------------------------------------------------------------- helpers

sep() { echo "---"; }


# The service control belongs at the top level, not inside the instance
# submenu: it gets looked at as often as anything else and it was buried.
# Settings and diagnostics. Printed in every branch, including the ones that
# bail out early: a bar that shows nothing is exactly when you need to see
# which colima it found and with what PATH.
settings_menu() {
  echo "---"
  echo "Settings | sfimage=gearshape"
  if [ -f "$CONFIG" ]; then
    echo "--${CONFIG/#$HOME/~} | $MONO"
  else
    echo "--⚠ no config file yet · using defaults | $MONO"
  fi
  echo "--Open config file | bash=$ACTION param1=openconfig terminal=false"
  echo "-----"
  echo "--VM disk warning: ${DISK_WARN}%"
  for n in 70 80 90; do
    m=""; [ "$n" = "$DISK_WARN" ] && m="  ✓"
    echo "----${n}%$m | bash=$ACTION param1=set param2=COLIMA_DISK_WARN param3=$n terminal=false refresh=true"
  done
  echo "--Registry: ${COLIMA_REGISTRY:-not set} | $MONO"
  if [ "$SHOW_STATS" = "1" ]; then
    echo "--Per-container CPU/RAM: on  ✓ | bash=$ACTION param1=set param2=COLIMA_SHOW_STATS param3=0 terminal=false refresh=true"
  else
    echo "--Per-container CPU/RAM: off | bash=$ACTION param1=set param2=COLIMA_SHOW_STATS param3=1 terminal=false refresh=true"
  fi
  echo "-----"
  if command -v colima >/dev/null 2>&1; then
    # Cached: this is decoration, and it was costing 0.18 s of a 0.26 s render.
    echo "--colima $(cached colimaver colima version | awk '/version/{print $3; exit}') · $(command -v colima) | $MONO"
  else
    echo "--⚠ colima not found | $MONO"
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "--docker · $(command -v docker) | $MONO"
  else
    echo "--⚠ docker not found | $MONO"
  fi
  echo "--DOCKER_HOST: ${DOCKER_HOST:-(unset)} | $MONO"
  echo "--Cache: ${CACHE/#$TMPDIR/\$TMPDIR} | $MONO"
  echo "--Recheck sizes now | bash=$ACTION param1=uncache terminal=false refresh=true"
  echo "-----"
  # Migrating off Docker Desktop leaves ~/.docker/config.json naming a
  # credential helper that no longer exists, and every authenticated pull then
  # fails with an error that does not mention it. The repair was already
  # written and simply had no way to be reached.
  echo "--Fix registry credentials… | bash=$ACTION param1=fixcreds terminal=true"
  if command -v lazydocker >/dev/null 2>&1; then
    echo "--Open lazydocker | bash=$ACTION param1=lazy terminal=true"
  fi
}

service_and_refresh() {
  if [[ -n "$OPERATION" ]]; then
    echo "$OPERATION | $MONO"
  else
    # No profile: the service only runs default, and that is all it may stop.
    echo "Stop the service… | bash=$ACTION param1=svcoff terminal=false refresh=true"
  fi
  echo "Refresh | refresh=true"
}

# Only caches successful, non-empty results. It used to write the file no
# matter what: if docker was not answering — right after starting the VM, for
# instance — it pinned an empty value and served it for the whole TTL, leaving
# the storage section blank for five minutes. On failure the previous copy is
# served even if stale, which always beats nothing.
cached() {   # $1=key  rest=command
  local key="$1"; shift
  local f="$CACHE/$key"
  if [[ -s "$f" ]]; then
    local age=$(( $(date +%s) - $(stat -f %m "$f") ))
    [[ $age -lt $SLOW_TTL ]] && { cat "$f"; return; }
  fi
  local tmp="$f.$$"
  if "$@" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv -f "$tmp" "$f"
    cat "$f"
    return
  fi
  rm -f "$tmp"
  [[ -s "$f" ]] && cat "$f"
}

human() { awk -v b="$1" 'BEGIN{ if(b=="")print "?"; else printf "%.0f GiB", b/1073741824 }'; }

# Caps a command at $1 seconds: a wedged lima or a daemon that accepts and
# never answers blocked the render, and SwiftBar waits for it. Not the usual
# `alarm; exec`: colima and docker are Go, which ignores SIGALRM, and both
# leave a child (limactl, ssh, the compose plugin) holding the pipe open — so
# the whole process group gets killed. macOS has no timeout(1); it has perl.
tmo() {
  perl -e '
    my $t = shift; my $p = fork; exit 125 unless defined $p;
    if (!$p) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127 }
    setpgrp($p, $p);
    $SIG{ALRM} = sub { kill "KILL", -$p }; alarm $t;
    waitpid $p, 0; exit($? & 127 ? 124 : $? >> 8)' "$@"
}

# ------------------------------------------------------------------- state

if ! command -v colima >/dev/null 2>&1; then
  echo " | sfimage=exclamationmark.triangle"
  sep
  echo "Colima is not installed"
  settings_menu
  exit 0
fi

# The state itself, not just started-or-not: `error` and `unknown` read as
# "Service stopped", and its Start cannot recover a job launchd still holds.
read_service() {
  SVC_STATE="$(awk '$1 == "colima" { print $2; exit }' <<< "$(cached svc brew services list)")"
  SERVICE_ON=0; [[ "$SVC_STATE" == started ]] && SERVICE_ON=1
}
read_service

RUNNING_VM=0
NAME="default"
INSTANCES="$(LIST_JSON="$(tmo 5 colima list --json 2>/dev/null)" python3 -c '
import os, json

raw = os.environ.get("LIST_JSON", "").strip()
keys = ("name", "status", "arch", "cpus", "memory", "disk", "runtime", "kubernetes")

def emit(d):
    print("|".join(str(d.get(k, "")) for k in keys))

if raw:
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            data = [data]
        for d in data:
            emit(d)
    except Exception:
        for line in raw.splitlines():
            line = line.strip()
            if line:
                try:
                    emit(json.loads(line))
                except Exception:
                    pass
')"

# Last-instance-wins was wrong the moment there is more than one profile: with
# alpha running and default stopped it left NAME=default, so "Adopt into the
# service" checked the wrong VM, skipped the stop, and launchd started a SECOND
# one alongside the live one. A running instance always wins.
FIRST_NAME=""
while IFS='|' read -r n status _rest; do
  [[ -z "$n" ]] && continue
  [[ -z "$FIRST_NAME" ]] && FIRST_NAME="$n"
  if [[ "$status" == "Running" ]]; then
    RUNNING_VM=1
    NAME="$n"
  fi
done <<< "$INSTANCES"
[[ $RUNNING_VM -eq 0 && -n "$FIRST_NAME" ]] && NAME="$FIRST_NAME"

# The service answer is cached for 5 minutes, which is right for the cost but
# wrong when something outside this bar changes it — `brew services stop` in a
# shell, or the launchd relaunch loop flipping the status. The VM state is read
# fresh every time, so when the two disagree the cached one is the stale one:
# throw it away and ask again. Costs a quarter of a second, and only in the
# window where the icon would otherwise be lying.
if [[ ( $SERVICE_ON -eq 1 && $RUNNING_VM -eq 0 ) || ( $SERVICE_ON -eq 0 && $RUNNING_VM -eq 1 ) ]]; then
  rm -f "$CACHE/svc"
  read_service
fi

# --------------------------------------------------------------- menu bar

# The daemon of the profile on show, not whatever the current context or
# DOCKER_HOST point at: with two VMs up it listed the other VM's containers.
# --context wins over DOCKER_HOST. Colima names the default's context "colima".
DOCKER_CTX="colima"; [[ "$NAME" != default ]] && DOCKER_CTX="colima-$NAME"

# The VM decides the icon, not the service. Keying it off the service meant a
# perfectly healthy VM that Homebrew did not happen to be managing rendered as
# "stopped" with everything hidden — the same class of bug as the original
# stale icon, just in the opposite quadrant.
DOCKER_OK=1
if [[ $RUNNING_VM -eq 1 ]]; then
  ALL_RAW="$(tmo 5 docker --context "$DOCKER_CTX" ps -a --format '{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}|{{.Ports}}' 2>/dev/null)" \
    || { DOCKER_RC=$?; DOCKER_OK=0; }
  # Running is what `docker ps` would list, and its Status always starts "Up":
  # counted from the same listing instead of asking the daemon twice a render.
  N_UP=0; N_ALL=0
  while IFS='|' read -r _ _ st _; do
    [[ -n "$st" ]] || continue
    N_ALL=$((N_ALL + 1)); [[ "$st" == Up* ]] && N_UP=$((N_UP + 1))
  done <<< "$ALL_RAW"
  if [[ $DOCKER_OK -eq 0 ]]; then
    # Discarding the exit code made an unreachable daemon look like an empty
    # one: "0 containers", confidently, with a broken context underneath.
    echo " | sfimage=exclamationmark.triangle"
  else
    echo "$N_UP | sfimage=shippingbox.fill"
  fi
elif [[ $SERVICE_ON -eq 1 ]]; then
  echo " | sfimage=shippingbox"
else
  echo " | sfimage=circle.dashed"
fi

sep

# ---------------------------------------------- service stopped: exit early

# Only bail out when there is genuinely nothing running. A VM that is up while
# the service is unregistered still has containers worth showing.
if [[ $SERVICE_ON -eq 0 && $RUNNING_VM -eq 0 ]]; then
  SVC_BAD=0
  case "$SVC_STATE" in error|unknown|other) SVC_BAD=1 ;; esac
  if [[ $SVC_BAD -eq 1 ]]; then
    echo "⚠ Service $SVC_STATE | $MONO"
  else
    echo "Service stopped"
  fi
  if [[ -n "$OPERATION" ]]; then
    echo "$OPERATION | $MONO"
  elif [[ $SVC_BAD -eq 1 ]]; then
    # svcon restarts the job, unloading the failed one first; why it failed is
    # in the log, and nowhere else.
    echo "Restart service | bash=$ACTION param1=svcon param2=default terminal=false refresh=true"
    echo "Open log | bash=$ACTION param1=openlog terminal=false"
  else
    echo "Start | bash=$ACTION param1=svcon param2=$NAME terminal=false refresh=true"
  fi
  settings_menu
  sep
  echo "Refresh | refresh=true"
  exit 0
fi

# The VM is up but Homebrew is not managing it. Worth saying out loud, because
# it will not survive a reboot and because the fix restarts the VM — the old
# menu offered a bare "Start" here that silently stopped the containers first.
if [[ $SERVICE_ON -eq 0 && $RUNNING_VM -eq 1 ]]; then
  echo "⚠ Running outside the service | $MONO"
  echo "--Homebrew is not managing this VM, so it will not come back after a reboot. | $MONO"
  if [[ "$NAME" == "default" ]]; then
    if [[ -n "$OPERATION" ]]; then
      echo "--$OPERATION | $MONO"
    else
      echo "--Adopt into the service (restarts the VM) | bash=$ACTION param1=svcon param2=$NAME terminal=false refresh=true"
    fi
  else
    # Homebrew's colima service only ever runs the default profile, so adopting
    # this one would stop your VM and start a different one in its place.
    echo "--Homebrew's service only manages the 'default' profile | $MONO"
    echo "--This instance ($NAME) has to be started by hand. | $MONO"
  fi
fi

# A reachable VM with an unreachable daemon is almost always the docker context
# pointing somewhere else, so offer that as the fix rather than just the fact.
# Not when the VM has no socket yet (still booting, or not the docker runtime)
# or the daemon took too long: no context reaches either of those.
SOCK="${COLIMA_HOME:-$HOME/.colima}/$NAME/docker.sock"
if [[ ${DOCKER_OK:-1} -eq 0 ]]; then
  echo "⚠ Docker is not answering | $MONO"
  if ! command -v docker >/dev/null 2>&1; then
    echo "--There is no docker command on PATH. Install it with: brew install docker | $MONO"
  elif [[ ! -S "$SOCK" ]]; then
    echo "--The VM is up but has no docker socket — still starting, or not running docker. | $MONO"
  elif [[ ${DOCKER_RC:-0} -eq 124 ]]; then
    echo "--The daemon did not answer within 5 s. | $MONO"
  else
    echo "--The VM is up but docker cannot reach it through the $DOCKER_CTX context. | $MONO"
    echo "--Point docker at Colima | bash=$ACTION param1=usecontext param2=$NAME terminal=false refresh=true"
  fi
  # Restarting the VM is often what fixes an unresponsive daemon, so these have
  # to stay reachable. The old early exit removed them in exactly that state.
  sep
  if [[ -n "$OPERATION" ]]; then
    echo "$OPERATION | $MONO"
  else
    echo "Restart the VM… | bash=$ACTION param1=restart param2=$NAME terminal=false refresh=true"
    echo "Stop Colima… | bash=$ACTION param1=stop param2=$NAME terminal=false refresh=true"
    echo "Shell into the VM | bash=$ACTION param1=shell param2=$NAME terminal=false"
  fi
  settings_menu
  sep
  echo "Refresh | refresh=true"
  exit 0
fi

# ------------------------------------------------- service running: the VM

while IFS='|' read -r name status arch cpus mem disk runtime k8s; do
  [[ -z "$name" ]] && continue
  if [[ "$status" == "Running" ]]; then
    echo "$name — $runtime"
  else
    echo "$name — stopped"
  fi
  echo "--$arch · ${cpus} CPU · $(human "$mem") RAM · $(human "$disk") disk | $MONO"
  # Only worth a line when the profile actually has it turned on.
  case "$k8s" in
    True|true) echo "--Kubernetes enabled | $MONO" ;;
  esac
  echo "-----"
  # While a start/stop/restart is running, show what it is doing instead of
  # offering a second one to stack on top of the first.
  if [[ -n "$OPERATION" ]]; then
    echo "--$OPERATION | $MONO"
  elif [[ "$status" == "Running" ]]; then
    echo "--Stop Colima… | bash=$ACTION param1=stop param2=$name terminal=false refresh=true"
    echo "--Restart… | bash=$ACTION param1=restart param2=$name terminal=false refresh=true"
    echo "--Shell into the VM | bash=$ACTION param1=shell param2=$name terminal=false"
  else
    echo "--Start Colima | bash=$ACTION param1=start param2=$name terminal=false refresh=true"
  fi
done <<< "$INSTANCES"

if [[ $RUNNING_VM -eq 0 ]]; then
  settings_menu
  sep
  service_and_refresh
  exit 0
fi

# -------------------------------------------------------------- containers

sep
if [[ $N_UP -eq 0 ]]; then
  echo "No containers"
else
  echo "Containers $N_UP/$N_ALL"
fi

# One call for every container, not one per container.
STATS=""
if [[ "$SHOW_STATS" = "1" && $RUNNING_VM -eq 1 && ${DOCKER_OK:-1} -eq 1 ]]; then
  SF="$CACHE/stats"
  if [[ -s "$SF" ]] && (( $(date +%s) - $(stat -f %m "$SF") < STATS_TTL )); then
    STATS="$(cat "$SF")"
  else
    STATS="$(tmo 10 docker --context "$DOCKER_CTX" stats --no-stream --format '{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null)"
    [[ -n "$STATS" ]] && printf '%s' "$STATS" > "$SF"
  fi
fi

while IFS='|' read -r id nm st img ports; do
  [[ -z "$id" ]] && continue
  case "$st" in
    Up*unhealthy*) echo "◍ $nm" ;;
    Up*)           echo "● $nm" ;;
    *)             echo "○ $nm" ;;
  esac
  echo "--${img##*/} | $MONO"
  echo "--$st | $MONO"
  if [[ -n "$STATS" ]]; then
    while IFS='|' read -r sid scpu smem; do
      [[ "$sid" == "$id"* ]] || continue
      echo "--$scpu CPU · $smem | $MONO"
      break
    done <<< "$STATS"
  fi
  # Ports come as 0.0.0.0:8080->80/tcp. The published one is worth a click,
  # and the rest of the line is worth keeping visible.
  if [[ -n "$ports" ]]; then
    while IFS= read -r pmap; do
      [[ -z "$pmap" ]] && continue
      hostport="${pmap%%->*}"; hostport="${hostport##*:}"
      # Only TCP gets a link: a browser cannot speak to a UDP port, and
      # offering http://localhost:53 for a DNS mapping is just wrong.
      case "$pmap" in
        */udp*) echo "--$pmap | $MONO"; continue ;;
      esac
      case "$hostport" in
        ''|*[!0-9]*) echo "--$pmap | $MONO" ;;
        *) echo "--$pmap | href=http://localhost:$hostport sfimage=globe $MONO" ;;
      esac
    done <<< "${ports//, /$'\n'}"
  fi
  echo "-----"
  # The profile rides along: the action must reach the daemon these came from.
  echo "--Logs | bash=$ACTION param1=logs param2=$id param3=$NAME terminal=false sfimage=doc.text"
  echo "--Shell | bash=$ACTION param1=exec param2=$id param3=$NAME terminal=false sfimage=terminal"
  echo "--Stats | bash=$ACTION param1=stats param2=$id param3=$NAME terminal=false sfimage=chart.bar"
  echo "--Copy container ID | bash=$ACTION param1=ccopy param2=$id terminal=false sfimage=doc.on.doc"
  echo "-----"
  if [[ "$st" == Up* ]]; then
    echo "--Stop | bash=$ACTION param1=cstop param2=$id param3=$NAME terminal=false refresh=true"
    echo "--Restart | bash=$ACTION param1=crestart param2=$id param3=$NAME terminal=false refresh=true"
  else
    echo "--Start | bash=$ACTION param1=cstart param2=$id param3=$NAME terminal=false refresh=true"
    echo "-----"
    # The name rides along so the confirmation can say what is about to go.
    echo "--Remove… | bash=$ACTION param1=crm param2=$id param3=\"$nm\" param4=$NAME terminal=false refresh=true"
  fi
done <<< "$ALL_RAW"

# ----------------------------------------------------------------- compose

COMPOSE="$(tmo 5 docker --context "$DOCKER_CTX" compose ls --format json 2>/dev/null)"
if [[ -n "$COMPOSE" && "$COMPOSE" != "[]" ]]; then
  sep
  echo "Compose"
  COMPOSE="$COMPOSE" python3 -c '
import os, json
try:
    data = json.loads(os.environ["COMPOSE"])
except Exception:
    raise SystemExit
for p in data:
    print("--{} — {}".format(p.get("Name", "?"), p.get("Status", "?")))
'
fi

# ----------------------------------------------------------------- storage

sep
echo "Storage"
DF="$(cached "df-$NAME" tmo 10 docker --context "$DOCKER_CTX" system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}')"
while IFS=$'\t' read -r type size recl; do
  [[ -z "$type" ]] && continue
  echo "--$type: $size ($recl reclaimable) | $MONO"
done <<< "$DF"

VMDF="$(cached "vmdf-$NAME" tmo 10 colima ssh --profile "$NAME" -- df -h /var/lib/docker)"
PCT="$(awk 'NR==2{gsub("%","",$5); print $5}' <<< "$VMDF")"
USED="$(awk 'NR==2{print $3" / "$2}' <<< "$VMDF")"
if [[ -n "$PCT" ]]; then
  if [[ "$PCT" -ge "$DISK_WARN" ]]; then
    echo "--⚠ VM disk: $USED (${PCT}%) | $MONO"
  else
    echo "--VM disk: $USED (${PCT}%) | $MONO"
  fi
fi
echo "-----"
echo "--Prune stopped and cache | bash=$ACTION param1=prune param2=$NAME terminal=false refresh=true"
echo "--Prune images too | bash=$ACTION param1=prune-all param2=$NAME terminal=false refresh=true"
echo "--Recheck sizes | bash=$ACTION param1=uncache terminal=false refresh=true"

settings_menu

sep
service_and_refresh
