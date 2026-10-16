#!/bin/bash
# The colima bar, driven through stubbed colima/brew/docker binaries so every
# state can be reached without touching the real VM.
S="$(cd "$(dirname "$0")" && pwd)"
. "$S/lib.sh"

PLUGIN="${COLIMA_PLUGIN:-$S/../plugins/colima.15s.sh}"
TMP="${TMPDIR:-/tmp}/colima-tests.$$"
STUB="$TMP/bin"
mkdir -p "$STUB"
trap 'rm -rf "$TMP"' EXIT

# The plugin sets its own PATH on the way in, prepending the system
# directories, so a stub directory exported from out here would never be seen.
# It has to go into that line, which means running a patched copy.
COPY="$TMP/colima-under-test.sh"
sed "s|^export PATH=\"|export PATH=\"$STUB:|" "$PLUGIN" > "$COPY"

# $1=vm status  $2=brew service line  $3=docker behaviour
stubs() {
  cat > "$STUB/colima" <<EOF
#!/bin/bash
[ "\$1" = "list" ] && { echo '{"name":"default","status":"$1","arch":"aarch64","cpus":4,"memory":8589934592,"disk":64424509440,"runtime":"docker","kubernetes":false}'; exit 0; }
[ "\$1" = "version" ] && { echo "colima version 0.0.0"; exit 0; }
exit 0
EOF
  cat > "$STUB/brew" <<EOF
#!/bin/bash
[ "\$1" = "services" ] && { echo "$2"; exit 0; }
exit 0
EOF
  case "$3" in
    ok)
      cat > "$STUB/docker" <<'EOF'
#!/bin/bash
RUNNING="abc123|web|Up 2 hours|nginx|0.0.0.0:8080->80/tcp, 0.0.0.0:53->53/udp"
STOPPED="def456|old-db|Exited (0) 3 days ago|postgres|"
case "$*" in
  # Remove is only offered for a stopped container, so the fixture needs one.
  *"ps -a"*) printf '%s\n%s\n' "$RUNNING" "$STOPPED"; exit 0 ;;
  ps*)       printf '%s\n' "$RUNNING"; exit 0 ;;
esac
exit 0
EOF
      ;;
    down)
      printf '#!/bin/bash\nexit 1\n' > "$STUB/docker" ;;
  esac
  chmod +x "$STUB/colima" "$STUB/brew" "$STUB/docker"
  # A fresh cache dir per scenario: the service answer is cached for minutes.
  CACHE="$TMP/cache.$RANDOM"; mkdir -p "$CACHE"
}

render() { TMPDIR="$CACHE" bash "$COPY" 2>&1; }

section "STATE: SERVICE OFF, VM DOWN"
stubs Stopped "colima none" down
R="$(render)"
has   "icon is the idle outline"          "$R" "sfimage=circle.dashed"
has   "says the service is stopped"       "$R" "Service stopped"
has   "offers to start it"                "$R" "param1=svcon"

section "STATE: SERVICE OFF, VM UP"
# The bar used to key everything off the service, so a perfectly healthy VM
# that Homebrew was not managing rendered as stopped with everything hidden.
stubs Running "colima none" ok
R="$(render)"
has   "icon counts the containers"        "$R" "sfimage=shippingbox.fill"
has   "says it runs outside the service"  "$R" "Running outside the service"

section "STATE: SERVICE ON, VM UP, DOCKER DOWN"
# Discarding docker's exit status made an unreachable daemon look like an empty
# one: a confident "0 containers" with a broken context underneath.
stubs Running "colima started" down
R="$(render)"
has   "icon warns"                        "$R" "sfimage=exclamationmark.triangle"
has   "says docker is not answering"      "$R" "Docker is not answering"
# Restarting the VM is often what fixes it, so it has to stay reachable.
has   "the VM controls stay reachable"    "$R" "param1=restart"

section "STATE: SERVICE ON, VM UP, DOCKER OK"
stubs Running "colima started" ok
R="$(render)"
has   "the container is listed"           "$R" "● web"
has   "a tcp port is clickable"           "$R" "href=http://localhost:8080"
# A browser has nothing to say to a UDP mapping.
lacks "a udp port is not"                 "$R" "href=http://localhost:53"
has   "the container id can be copied"    "$R" "param1=ccopy"
# The ellipsis is the promise that a dialog comes first.
has   "removing asks first"               "$R" "Remove…"

section "SETTINGS AND DIAGNOSTICS"
has   "credential repair is reachable"    "$R" "param1=fixcreds"

section "THE PROFILE TRAVELS WITH THE ACTION"
# Every call used to speak to the default instance whatever the menu showed.
has   "stop carries the profile"          "$R" "param1=stop param2=default"

section "STOPPING THE VM ASKS FIRST"
# Every container goes down with it. A stubbed osascript records the dialog
# and answers Cancel, and the stubbed colima records whether it was told to stop.
cat > "$STUB/osascript" <<EOF
#!/bin/bash
grep -q "display alert" <<< "\$(cat)" && echo alert >> "$TMP/asked"
exit 1
EOF
printf '#!/bin/bash\necho "$*" >> "%s"\n' "$TMP/colima-calls" > "$STUB/colima"
chmod +x "$STUB/osascript" "$STUB/colima"
ACOPY="$TMP/action-under-test"
sed "s|^export PATH=\"|export PATH=\"$STUB:|" "$S/../bin/colimabar-action" > "$ACOPY"
for verb in stop restart svcoff; do
  : > "$TMP/asked"; : > "$TMP/colima-calls"
  TMPDIR="$CACHE" bash "$ACOPY" "$verb" default >/dev/null 2>&1
  equals "$verb asks first"                 "$(grep -c alert "$TMP/asked")" "1"
  equals "and Cancel leaves the VM alone"   "$(grep -c . "$TMP/colima-calls")" "0"
done

report "colima"
