#!/bin/bash
# The ports bar: what it hides, what it names, and the identity check that
# stands between a click and somebody else's process.
S="$(cd "$(dirname "$0")" && pwd)"
. "$S/lib.sh"

PLUGIN="${DEVPORTS_PLUGIN:-$S/../plugins/devports.15s.py}"
ACTION="${DEVPORTS_ACTION_BIN:-$S/../bin/devports-action}"
TMP="${TMPDIR:-/tmp}/devports-tests.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

section "WHAT IS HIDDEN, AND WHAT IS NOT"
# The exclusions are two patterns: one for the executable, one for the command
# line. A single pattern over both is what used to hide a service of yours
# merely for mentioning .vscode/ in an argument.
CLASSIFY="$(python3 - "$PLUGIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
NODE = "/opt/homebrew/bin/node"
VENV = "/Users/x/work/api/venv/bin/python"
cases = [
    ("pycharm-console", VENV,
     "python /Applications/PyCharm.app/Contents/plugins/python/helpers/pydev/pydevconsole.py 1 2"),
    ("maven-importer", "/Applications/IntelliJ IDEA.app/Contents/jbr/Contents/Home/bin/java",
     "java -cp x org.jetbrains.idea.maven.server.RemoteMavenServer36"),
    ("copilot-jetbrains", NODE,
     "node /Users/x/Library/Application Support/JetBrains/I/plugins/github-copilot-intellij/agent.js"),
    ("zed-lsp", NODE,
     "node /Users/x/Library/Application Support/Zed/languages/ts/server.js"),
    ("vscode-extension", NODE, "node /Users/x/.vscode/extensions/foo/server.js"),
    ("vscodium-helper", "/Applications/VSCodium.app/Contents/MacOS/Electron",
     "Electron --type=extensionHost"),
    ("own-service-vscode-arg", NODE,
     "node /Users/x/work/mytool/main.js --config .vscode/launch.json"),
    ("own-project-named-tsserver", "/Users/x/work/tsserver-proxy/venv/bin/python",
     "python /Users/x/work/tsserver-proxy/main.py"),
    ("own-service-javaagent", "/opt/homebrew/opt/openjdk/bin/java",
     "java -javaagent:/Applications/Foo.app/Contents/plugins/a.jar -jar /Users/x/work/app.jar"),
    ("own-service-plain", "/opt/homebrew/opt/openjdk/bin/java",
     "java -jar /Users/x/work/app.jar"),
]
for name, comm, args in cases:
    hidden = bool(m.EXCLUDED_PATH.search(comm) or m.EXCLUDED_ARGS.search(args))
    print("%s %s" % (name, "hidden" if hidden else "shown"))
PY
)"
verdict() { echo "$CLASSIFY" | grep "^$1 " | awk '{print $2}'; }

for c in pycharm-console maven-importer copilot-jetbrains zed-lsp \
         vscode-extension vscodium-helper; do
  equals "hidden: $c" "$(verdict $c)" "hidden"
done
for c in own-service-vscode-arg own-project-named-tsserver \
         own-service-javaagent own-service-plain; do
  equals "shown: $c" "$(verdict $c)" "shown"
done

section "PROJECT NAMES"
# bun and deno were added to the runtime list without their argument tables, so
# `bun run server.ts` reported itself as the word "run".
NAMES="$(python3 - "$PLUGIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cases = [
    ("bun-run",     "bun",    "bun run /Users/x/work/api/server.ts"),
    ("bun-direct",  "bun",    "bun /Users/x/work/api/index.ts"),
    ("deno-run",    "deno",   "deno run -A /Users/x/work/api/main.ts"),
    ("deno-port",   "deno",   "deno run --allow-net --port 8080 /Users/x/work/api/srv.ts"),
    ("deno-serve",  "deno",   "deno serve --port 3000 /Users/x/work/api/main.ts"),
    ("node-plain",  "node",   "node /Users/x/work/api/main.js"),
    ("node-require","node",   "node -r dotenv/config /Users/x/work/api/main.js"),
    ("java-jar",    "java",   "java -jar /Users/x/work/api/target/app.jar"),
]
for name, rt, line in cases:
    print("%s %s" % (name, m.app_name(rt, line, None)[0]))
PY
)"
name_of() { echo "$NAMES" | grep "^$1 " | cut -d' ' -f2-; }

equals "bun run names the script"     "$(name_of bun-run)"     "server.ts"
equals "deno run names the script"    "$(name_of deno-run)"    "api/main.ts"
equals "deno --port takes its value"  "$(name_of deno-port)"   "srv.ts"

section "THE BRANCH A SERVICE RUNS FROM"
# Read from HEAD files, so plain directories stand in for repositories.
G="$TMP/git"; mkdir -p "$G/repo/.git" "$G/repo/svc/sub" "$G/main/.git/worktrees/wt" "$G/wt" "$G/det/.git" "$G/none"
echo "ref: refs/heads/feature/login" > "$G/repo/.git/HEAD"
echo "ref: refs/heads/hotfix/vat" > "$G/main/.git/worktrees/wt/HEAD"
echo "gitdir: $G/main/.git/worktrees/wt" > "$G/wt/.git"
echo "4f9c2a1d0e8b7c6a5f4e3d2c1b0a9f8e7d6c5b4a" > "$G/det/.git/HEAD"
BRANCHES="$(python3 - "$PLUGIN" "$G" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
g = sys.argv[2]
for case, d in [("sub", "repo/svc/sub"), ("worktree", "wt"), ("detached", "det"), ("none", "none")]:
    print("%s %s" % (case, m.git_branch(g + "/" + d)))
PY
)"
branch_of() { echo "$BRANCHES" | grep "^$1 " | cut -d' ' -f2-; }
equals "found from a folder inside the repo" "$(branch_of sub)"      "feature/login"
equals "a worktree reads its own HEAD"       "$(branch_of worktree)" "hotfix/vat"
equals "a bare commit says detached"         "$(branch_of detached)" "detached"
equals "outside a repository, nothing"       "$(branch_of none)"     "None"

section "A KILL VERIFIES WHAT IT KILLS"
# The identity is built the way the PLUGIN builds it — Python .strip() over
# `ps -o pid=,lstart=`. Re-deriving it in the shell keeps the shell's own
# trailing padding on both sides and hides the exact mismatch this guards.
ident_for() {   # $1=pid -> base64 of "comm<TAB>start"
  python3 -c "
import base64, subprocess, sys
out = subprocess.run(['/bin/ps','-o','pid=,lstart=','-p',sys.argv[1]],
                     capture_output=True, text=True).stdout
start = out.strip().split(None, 1)[1].strip()
print(base64.b64encode(('sleep\t' + start).encode()).decode())" "$1"
}
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

/bin/sleep 120 & VICTIM=$!
disown $VICTIM 2>/dev/null
sleep 0.3
bash "$ACTION" kill "$VICTIM" "$(printf 'sleep\tMon Jan  1 00:00:00 2001' | base64)" >/dev/null 2>&1
equals "a wrong start time is refused"   "$(alive $VICTIM)" "yes"

bash "$ACTION" kill "$VICTIM" "$(printf 'sleep\t' | base64)" >/dev/null 2>&1
equals "an empty start time fails closed" "$(alive $VICTIM)" "yes"

bash "$ACTION" kill "$VICTIM" "$(printf 'notsleep\tx' | base64)" >/dev/null 2>&1
equals "a wrong name is refused"          "$(alive $VICTIM)" "yes"

# CPU, memory and uptime now share the plugin's ps call with lstart: the start
# time it parses out of the wider line must be the one the action compares.
PLUGIN_IDENT="$(python3 - "$PLUGIN" "$VICTIM" <<'PY'
import base64, importlib.util, sys
spec = importlib.util.spec_from_file_location("dp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
start, usage = m.start_times([sys.argv[2]])[sys.argv[2]]
print(base64.b64encode(("sleep\t" + start).encode()).decode(), "CPU" in usage)
PY
)"
equals "the plugin's start time still matches" "$PLUGIN_IDENT" "$(ident_for $VICTIM) True"

bash "$ACTION" kill "$VICTIM" "$(ident_for $VICTIM)" >/dev/null 2>&1
equals "the real identity does kill"      "$(alive $VICTIM)" "no"

# Batch: one live row and one that no longer matches. The batch used to send
# SIGTERM to every PID with no check at all.
/bin/sleep 120 & V2=$!
disown $V2 2>/dev/null
sleep 0.3
V2_START="$(python3 -c "
import subprocess, sys
out = subprocess.run(['/bin/ps','-o','pid=,lstart=','-p',sys.argv[1]],
                     capture_output=True, text=True).stdout
print(out.strip().split(None,1)[1].strip())" "$V2")"
BATCH="$(printf '%s\tsleep\t%s\n999999\tjava\t%s' "$V2" "$V2_START" "$V2_START" | base64 | tr -d '\n')"
OUT="$(bash "$ACTION" killall "$BATCH" </dev/null 2>&1)"
equals "the matching row is killed"       "$(alive $V2)" "no"
has   "the stale row is skipped"          "$OUT" "skipped, no longer java"

section "THE CONFIG CANNOT DISARM THE CONFIRMATIONS"
# The action sources the config, so a value in it is shell code. Neither the
# bypass flag nor a command substitution may survive that.
#
# The end-to-end half of this waits on a real dialog, so a modal left on screen
# by an earlier run would make it read the wrong result. Clear the decks first.
pkill -f 'display alert' 2>/dev/null; sleep 1

# The deterministic half, which needs no window at all: whatever the config
# says, the flag must not be set by the time the confirmations are reached.
LEAK="$(printf 'DEVPORTS_ASSUME_YES=1\n' > "$TMP/leak.sh"; \
  SWIFTBAR_CONFIG="$TMP/leak.sh" bash -c '
    CONFIG="$SWIFTBAR_CONFIG"
    _ENV_ASSUME_YES="${DEVPORTS_ASSUME_YES:-}"
    . "$CONFIG"
    DEVPORTS_ASSUME_YES="$_ENV_ASSUME_YES"
    printf "[%s]" "${DEVPORTS_ASSUME_YES:-}"')"
equals "the flag does not survive sourcing"  "$LEAK" "[]"

# End to end, but deterministic: a stubbed osascript records the call and
# reports Cancel, so the assertion never waits on a real modal window. The
# action fixes its own PATH on the way in, so the stub goes into that line.
STUB="$TMP/bin"; mkdir -p "$STUB"
printf '#!/bin/bash\ncat >/dev/null 2>&1\necho called >> "%s/asked"\nexit 1\n' "$TMP" > "$STUB/osascript"
chmod +x "$STUB/osascript"
ACTION_COPY="$TMP/devports-under-test"
sed "s|^export PATH=\"|export PATH=\"$STUB:|" "$ACTION" > "$ACTION_COPY"

CFG="$TMP/config.sh"
printf 'DEVPORTS_ASSUME_YES=1\n' > "$CFG"
/bin/sleep 120 & V3=$!
disown $V3 2>/dev/null
sleep 0.3
V3_ID="$(python3 -c "
import subprocess, sys
out = subprocess.run(['/bin/ps','-o','pid=,lstart=','-p',sys.argv[1]],
                     capture_output=True, text=True).stdout
print(out.strip().split(None,1)[1].strip())" "$V3")"
B3="$(printf '%s\tsleep\t%s' "$V3" "$V3_ID" | base64 | tr -d '\n')"
: > "$TMP/asked"
OUT="$(SWIFTBAR_CONFIG="$CFG" bash "$ACTION_COPY" forceall "$B3" </dev/null 2>&1)"
equals "the confirmation is still asked for" \
       "$(grep -c called "$TMP/asked")" "1"
equals "so the process is untouched"      "$(alive $V3)" "yes"
kill -9 $V3 2>/dev/null

# A value written through the settings menu is escaped, not executed.
CFG2="$TMP/config2.sh"; : > "$CFG2"
MARK="$TMP/executed"
SWIFTBAR_CONFIG="$CFG2" bash "$ACTION" set TESTKEY "a\$(touch $MARK)b" >/dev/null 2>&1
bash -c ". '$CFG2' >/dev/null 2>&1; true"
equals "a written value is not executed on source" \
       "$([ -f "$MARK" ] && echo ran || echo inert)" "inert"

report "devports"
