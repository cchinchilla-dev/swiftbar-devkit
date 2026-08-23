#!/bin/bash
# The llama-swap bar, driven through a stubbed curl and launchctl so every
# state can be reached without a model server, a launch agent, or 13 GB of
# disk reads.
S="$(cd "$(dirname "$0")" && pwd)"
. "$S/lib.sh"

PLUGIN="${LLAMA_PLUGIN:-$S/../plugins/llama.5s.sh}"
ACTION="${LLAMA_ACTION_BIN:-$S/../bin/llamabar-action}"
TMP="${TMPDIR:-/tmp}/llama-tests.$$"
STUB="$TMP/bin"
mkdir -p "$STUB"
trap 'rm -rf "$TMP"' EXIT

# The plugin fixes its own PATH on the way in, prepending the system
# directories, so a stub exported from out here would never be seen.
COPY="$TMP/llama-under-test.sh"
sed "s|^export PATH=\"|export PATH=\"$STUB:|" "$PLUGIN" > "$COPY"

CFG="$TMP/config.sh"
cat > "$CFG" <<EOF
LLAMA_ADDR="http://127.0.0.1:9999"
LLAMA_CONFIG="$TMP/swap.yaml"
LLAMA_LOG="$TMP/llama.log"
LLAMA_SERVICE_LABEL="test.llama-swap"
LLAMA_ACTION="$ACTION"
EOF
export SWIFTBAR_CONFIG="$CFG"

# $1 = health body ("OK" or empty)   $2 = models json   $3 = launchd loaded?
stubs() {
  cat > "$STUB/curl" <<EOF
#!/bin/bash
url="\${@: -1}"
case "\$url" in
  */health)   printf '%s' '$1' ;;
  */models)   printf '%s' '$2' ;;
  */metrics)  printf 'llamaswap_memory_used_bytes 26706182144\nllamaswap_memory_total_bytes 51539607552\nllamaswap_gpu_util_percent{id="0",name="GPU"} 13\n' ;;
  */slots)    printf '%s' '[{"n_ctx":30720,"n_past":1234}]' ;;
  *)          printf '' ;;
esac
exit 0
EOF
  cat > "$STUB/launchctl" <<EOF
#!/bin/bash
[ "$3" = "yes" ] || exit 1
[ "\$1" = "print" ] && { printf '\tpid = 4242\n'; exit 0; }
exit 0
EOF
  chmod +x "$STUB/curl" "$STUB/launchctl"
  CACHE="$TMP/cache.$RANDOM"; mkdir -p "$CACHE"
}

render() { TMPDIR="$CACHE" bash "$COPY" 2>&1; }

BOTH_UNLOADED='{"data":[{"id":"qwen3.5-9b","status":{"value":"unloaded"}},{"id":"qwen3.8-27b","status":{"value":"unloaded"}}]}'
NINE_LOADED='{"data":[{"id":"qwen3.5-9b","status":{"value":"loaded"}},{"id":"qwen3.8-27b","status":{"value":"unloaded"}}]}'
MID_LOAD='{"data":[{"id":"qwen3.5-9b","status":{"value":"unloaded"}},{"id":"qwen3.8-27b","status":{"value":"loading"}}]}'

section "STATE: SERVICE STOPPED"
stubs "" "$BOTH_UNLOADED" no
R="$(render)"
has   "icon is the idle outline"       "$R" "sfimage=circle.dashed"
has   "says the service is stopped"    "$R" "Service stopped"
has   "offers to start it"             "$R" "param1=svcstart"

section "STATE: REGISTERED BUT NOT ANSWERING"
# Loaded in launchd yet /health is silent: a different problem from "stopped",
# and the fix is to look at the log, not to press Start again.
stubs "" "$BOTH_UNLOADED" yes
R="$(render)"
has   "icon warns"                     "$R" "sfimage=exclamationmark.triangle"

section "STATE: RUNNING, NOTHING LOADED"
stubs "OK" "$BOTH_UNLOADED" yes
R="$(render)"
has   "icon is the outlined stack"     "$R" "sfimage=square.stack.3d.up"
has   "each can be loaded"             "$R" "param1=load param2=\"qwen3.8-27b\""
has   "memory is reported"             "$R" "RAM 24.9 / 48 GB"

section "STATE: RUNNING WITH A MODEL LOADED"
stubs "OK" "$NINE_LOADED" yes
R="$(render)"
has   "icon is the filled stack"       "$R" "sfimage=square.stack.3d.up.fill"
# The context in use is what decides whether the next request fits.
has   "context in use is shown"        "$R" "ctx 1234 / 30720"
has   "it can be unloaded"             "$R" "param1=unloadone param2=\"qwen3.5-9b\""

section "STATE: A MODEL IS LOADING"
stubs "OK" "$MID_LOAD" yes
R="$(render)"
has   "loading is its own state"       "$R" "◍ qwen3.8-27b"

section "A MISSING DEPENDENCY IS SAID OUT LOUD"
# jq drives every model row. Without it the recovered version drew an empty
# list, which reads as "no models" when the daemon is perfectly fine.
stubs "OK" "$NINE_LOADED" yes
printf '#!/bin/bash\nexit 127\n' > "$STUB/jq"; chmod +x "$STUB/jq"
NOJQ="$TMP/nojq.sh"
sed "s|command -v jq|command -v definitely-not-jq|" "$COPY" > "$NOJQ"
R="$(TMPDIR="$CACHE" bash "$NOJQ" 2>&1)"
has   "warns instead of drawing empty" "$R" "jq is not installed"
rm -f "$STUB/jq"

section "AN UNREADABLE MODEL LIST IS NOT AN EMPTY ONE"
stubs "OK" 'not json at all' yes
R="$(render)"
has   "says the list is unreadable"    "$R" "unreadable"

section "DESTRUCTIVE ACTIONS ASK FIRST"
# A stubbed osascript records the call and reports Cancel, so nothing here
# waits on a real modal window.
# confirm() feeds "display alert" on stdin; notify() passes "display
# notification" in argv. Counting bare osascript calls conflates the two, and
# an action that only notifies looked like it was asking for permission.
cat > "$STUB/osascript" <<EOF
#!/bin/bash
case "\$*" in
  *"display notification"*) echo notify >> "$TMP/asked"; exit 0 ;;
esac
if grep -q "display alert" <<< "\$(cat)"; then echo alert >> "$TMP/asked"; fi
exit 1
EOF
chmod +x "$STUB/osascript"
ACOPY="$TMP/action-under-test"
sed "s|^export PATH=\"|export PATH=\"$STUB:|" "$ACTION" > "$ACOPY"

: > "$TMP/asked"
OUT="$(SWIFTBAR_CONFIG="$CFG" bash "$ACOPY" load qwen3.8-27b 2>&1)"
equals "loading a model asks first"    "$(grep -c alert "$TMP/asked")" "1"

: > "$TMP/asked"
OUT="$(SWIFTBAR_CONFIG="$CFG" bash "$ACOPY" svcstop 2>&1)"
equals "stopping the service asks too" "$(grep -c alert "$TMP/asked")" "1"

# Unloading is cheap and reversible, so it does not interrupt.
: > "$TMP/asked"
OUT="$(SWIFTBAR_CONFIG="$CFG" bash "$ACOPY" unload 2>&1)"
equals "unloading does not ask"        "$(grep -c alert "$TMP/asked")" "0"
equals "but it does report back"       "$(grep -c notify "$TMP/asked")" "1"

section "THE CONFIG CANNOT DISARM THE CONFIRMATIONS"
cat > "$TMP/leak.sh" <<EOF
LLAMA_ADDR="http://127.0.0.1:9999"
LLAMA_ASSUME_YES=1
EOF
: > "$TMP/asked"
OUT="$(SWIFTBAR_CONFIG="$TMP/leak.sh" bash "$ACOPY" svcstop 2>&1)"
equals "a config value is overridden"  "$(grep -c alert "$TMP/asked")" "1"

report "llama"
