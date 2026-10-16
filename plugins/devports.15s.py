#!/usr/bin/env python3
# <swiftbar.title>Dev ports</swiftbar.title>
# <swiftbar.version>v1.0</swiftbar.version>
# <swiftbar.desc>Java/Python/Node services listening on local ports, with a way to kill them</swiftbar.desc>
# <swiftbar.dependencies>python3,lsof</swiftbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
#   powerplug        nothing listening
#   powerplug.fill N N dev services listening
#
# Only lists your own processes whose executable is java, python or node. Never
# lists the IDE itself or system processes: see EXCLUDED_* and is_system().

# Work in progress, shared as-is, with no warranty of any kind.
# Actions here change real state on this machine — see the README.

import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

# ------------------------------------------------------------------- config

def _expand(text):
    """$VAR / ${VAR} the way bash does when it sources the file: an unset name
    becomes empty, not the literal $NAME that os.path.expandvars leaves behind.
    That difference turned an unset variable into a path made of the variable's
    own name, and the button built from it pointed nowhere."""
    return re.sub(
        r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)",
        lambda m: os.environ.get(m.group(1) or m.group(2), ""),
        text)


def load_config():
    """Reads the shared config.sh. Only scalars: the bash plugins source that
    same file, so it stays plain KEY="value" and needs no shell to read.

    The two readers have to agree exactly, or a path here points somewhere the
    bars never wrote. Single quotes take the value literally, double quotes
    expand and honour backslash escapes, and `export` may prefix either."""
    path = os.environ.get("SWIFTBAR_CONFIG") or os.path.expanduser(
        "~/.config/swiftbar-devkit/config.sh")
    values = {}
    # Double-quoted: \" and \\ are escapes, so the value cannot simply be
    # "everything up to the next quote" — that is what mangled the very lines
    # set_config writes when a value contains a quote of its own.
    dq = re.compile(r'\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)="((?:[^"\\]|\\.)*)"\s*(?:#.*)?$')
    sq = re.compile(r"\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)='([^']*)'\s*(?:#.*)?$")
    # No spaces around = : in bash `KEY = value` is a command, not an
    # assignment, and the variable stays unset. And a # only starts a comment
    # when whitespace precedes it, so val#nothash is a value, not a truncation.
    bare = re.compile(r'\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=([^\s(]*)(?:\s+#.*)?\s*$')
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                m = dq.match(line)
                if m:
                    raw = re.sub(r'\\(.)', r'\1', m.group(2))
                    values[m.group(1)] = _expand(raw)
                    continue
                m = sq.match(line)
                if m:
                    # Single quotes are literal in bash: no expansion at all.
                    values[m.group(1)] = m.group(2)
                    continue
                m = bare.match(line)
                if m:
                    values[m.group(1)] = _expand(m.group(2).strip())
    except Exception:
        pass
    return values


CFG = load_config()

# True = show only what hangs off PyCharm/IntelliJ. False = also show what was
# launched from a terminal, which leaves ports open just as easily when
# forgotten. The origin is shown on each entry, so False still tells them apart.
IDE_ONLY = CFG.get("DEVPORTS_IDE_ONLY", "0") == "1"

ACTION = os.path.expanduser(
    CFG.get("DEVPORTS_ACTION") or "~/.local/bin/devports-action")
LSOF = "/usr/sbin/lsof"
PS = "/bin/ps"
MONO = "font=Menlo size=11"
MAX_CMD = 110          # command line trimmed to this in the submenu

# Debug ports: opened by the IDE, not by the application. A Java service
# started in debug mode listens on 5005 on top of its own, and since 5005 is
# lower it would become the primary port, which is exactly the wrong number.
DEBUG_PORTS = {
    5005: "JDWP debug",
    9229: "Node debug",
    5678: "debugpy",
}

# Executables that count as a dev service. Case-insensitive: the python in
# /usr/bin resolves to a binary called "Python" inside Python.app, and a
# lowercase-only pattern left it out.
RUNTIMES = (
    ("java", re.compile(r"^java$", re.I)),
    ("python", re.compile(r"^python[0-9.]*$", re.I)),
    ("node", re.compile(r"^node(js)?$", re.I)),
    # Bun and Deno serve HTTP exactly like node does, so a service started with
    # either was invisible here while still holding the port.
    ("bun", re.compile(r"^bun$", re.I)),
    ("deno", re.compile(r"^deno$", re.I)),
)

# Go has no fixed executable to match: it compiles to a binary with whatever
# name the module has. What gives a dev build away is where it lives — `go run`
# builds into a temp dir, Delve and GoLand produce __debug_bin — or who
# launched it.
GO_TEMP = re.compile(r"/go-build[^/]*/|/__debug_bin")
GO_PARENTS = ("go", "dlv")

# Processes that are the environment itself, not a service you started. The
# VS Code family matters as much as JetBrains here: its extension host and its
# language servers are node processes that listen, so without this the menu
# would happily offer to kill your editor.
#
# Two patterns, not one. The old single regex was matched against both the
# executable path and the whole command line, so bare fragments like "tsserver"
# hid any service whose *arguments* happened to contain them: a perfectly
# normal `node main.js --config .vscode/launch.json` vanished from the bar, and
# so did every project called tsserver-something.
#
# EXCLUDED_PATH only ever sees the executable's own path.
EXCLUDED_PATH = re.compile(
    r"/(Visual Studio Code|Code|Code - Insiders|VSCodium|Cursor|Windsurf"
    r"|Zed|Sublime Text|Fleet)\.app/"
    r"|/JetBrains/Toolbox/apps/"
    r"|JetBrains Toolbox\.app/"
    # Scoped to editor and IDE bundles, NOT to any bundle. A bare
    # .app/Contents/MacOS/ fragment also matches macOS's own python, which
    # lives in Python.app/Contents/MacOS/Python — so every service started with
    # the python3 that ships with the system was invisible here.
    r"|/(IntelliJ IDEA|PyCharm|WebStorm|GoLand|RubyMine|PhpStorm|DataGrip"
    r"|RustRover|Fleet|Android Studio)[^/]*\.app/Contents/"
    # Editor-managed trees. Anchored on the directories editors actually run
    # from, so a repository's own .vscode/ folder is not a match.
    r"|\.vscode(-server|-insiders)?/(extensions|bin)/"
    r"|/\.cursor(-server)?/"
    r"|/Application Support/(JetBrains|Code|Code - Insiders|VSCodium|Cursor|Zed)/"
    r"|/\.(vscode-oss|windsurf)/"
)

# EXCLUDED_ARGS only ever sees the full command line, and every entry here is
# specific enough that a service of your own will not carry it by accident.
EXCLUDED_ARGS = re.compile(
    # JetBrains itself, and the helpers it launches with *your* interpreter —
    # the Python console runs your venv's python against a script inside the
    # IDE bundle, so the executable looks exactly like one of your services.
    r"com\.intellij\.idea\.Main"
    r"|-Didea\."
    r"|idea\.paths\.selector"
    # Only JetBrains bundles, not any bundle: a generic .app/Contents/ fragment
    # in the ARGS pattern hid legitimate services merely for referencing a path
    # inside some application — an -javaagent, or assets under
    # SomeApp.app/Contents/Resources. The executable-path pattern keeps the
    # broad form, where it is correct.
    r"|/(IntelliJ IDEA|PyCharm|WebStorm|GoLand|RubyMine|PhpStorm|DataGrip"
    r"|RustRover|Fleet|Android Studio)[^/]*\.app/Contents/"
    r"|pydevconsole\.py|pydevd[_./]|pydev_run_in_console"
    r"|org\.jetbrains\.idea\.maven\.server"
    r"|org\.jetbrains\.jps\."
    r"|fsnotifier|jcef_helper|KotlinCompileDaemon|GradleDaemon"
    # VS Code family internals, as flags and script names rather than as loose
    # words that could appear anywhere on a command line.
    r"|--type=(extensionHost|bootstrap-fork|ptyHost|fileWatcher|utilityProcess)"
    r"|/(tsserver|tsserver\.js|typingsInstaller\.js|bootstrap-fork\.js"
    r"|serverProcess\.js|watchDog\.js)(\s|$)"
    r"|vscode-[a-z-]+-language-server"
    # Copilot ships as a standalone agent under several names.
    r"|github-copilot|copilot-(language-server|agent)|copilot\.vim"
    # Editor-managed trees again, because the editor usually launches these
    # with a plain `node`: the giveaway is the script path in the arguments,
    # not the executable. A service of yours has no reason to name one.
    r"|/Application Support/(JetBrains|Code|Code - Insiders|VSCodium|Cursor|Zed)/"
    r"|\.vscode(-server|-insiders)?/(extensions|bin)/"
    r"|/\.cursor(-server)?/"
)

# Process names that give away where the service came from.
IDES = re.compile(
    r"(IntelliJ IDEA|PyCharm|WebStorm|GoLand|RubyMine|PhpStorm|DataGrip|RustRover)"
    # Toolbox installs whose path carries the slug rather than the display
    # name, e.g. .../apps/intellij-idea-ultimate/ch-0/bin/idea
    r"|/apps/(intellij-idea|pycharm|webstorm|goland|rubymine|phpstorm)[^/]*/"
    r"|/(idea|pycharm|webstorm|goland|rubymine|phpstorm)$",
    re.I)
SHELLS = re.compile(r"/(zsh|bash|fish|sh)$")
TERMINALS = re.compile(r"(iTerm2?|Terminal|Warp|Alacritty|kitty|WezTerm)", re.I)

SYSTEM_PATHS = ("/System/", "/usr/libexec/", "/Library/Apple/")


# ------------------------------------------------------------------ helpers

def run(cmd):
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=5
        ).stdout
    except Exception:
        return ""


def b64(text):
    """Values travel base64-encoded: SwiftBar splits parameters on whitespace
    and treats | as its own separator."""
    import base64 as _b64
    return _b64.b64encode(text.encode()).decode()


def clean(text):
    """SwiftBar uses | as the separator between title and parameters."""
    return text.replace("|", "¦").replace("\n", " ").strip()


# ---------------------------------------------------------------- gathering

def listening():
    """{pid: set(ports)} of the current user's listening TCP sockets."""
    output = run([
        LSOF, "-nP", "-a", "-iTCP", "-sTCP:LISTEN",
        "-u", str(os.getuid()), "-F", "pn",
    ])
    ports = {}
    pid = None
    for line in output.splitlines():
        if not line:
            continue
        tag, value = line[0], line[1:]
        if tag == "p":
            pid = value
        elif tag == "n" and pid:
            # Shapes: *:8080 · 127.0.0.1:8080 · [::1]:8080
            if ":" not in value:
                continue
            port = value.rsplit(":", 1)[1]
            if port.isdigit():
                ports.setdefault(pid, set()).add(int(port))
    return ports


def working_dirs(pids):
    """{pid: cwd}. The directory a service runs from is the most reliable clue
    to which project it belongs to: the IDE sets it to the module root."""
    if not pids:
        return {}
    output = run([LSOF, "-a", "-p", ",".join(pids), "-d", "cwd", "-F", "pn"])
    cwds = {}
    pid = None
    for line in output.splitlines():
        if not line:
            continue
        tag, value = line[0], line[1:]
        if tag == "p":
            pid = value
        elif tag == "n" and pid:
            cwds[pid] = value
    return cwds


def process_tree():
    """{pid: (ppid, comm)} for every process."""
    processes = {}
    for line in run([PS, "-Ao", "pid=,ppid=,comm="]).splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit():
            processes[parts[0]] = (parts[1], parts[2])
    return processes


def start_times(pids):
    """{pid: (start time, usage)}. The executable name alone cannot tell two
    processes apart — every JVM is `java` — so a recycled PID would pass the
    kill guard. The start time is what makes the identity unique.

    Usage rides along in the same ps call: "0.4% CPU · 38 MB · up 2 h". lstart
    goes last because it is the one column with spaces in it."""
    if not pids:
        return {}
    out = {}
    for line in run([PS, "-o", "pid=,%cpu=,rss=,etime=,lstart=", "-p", ",".join(pids)]).splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) == 5 and parts[0].isdigit():
            out[parts[0]] = (parts[4].strip(), usage(parts[1], parts[2], parts[3]))
    return out


def usage(cpu, rss_kb, etime):
    """ps's raw columns, as the submenu shows them."""
    try:
        mb = int(rss_kb) / 1024.0
    except ValueError:
        return ""
    mem = "{:.1f} GB".format(mb / 1024) if mb >= 1024 else "{:.0f} MB".format(mb)
    return "{}% CPU · {} · up {}".format(cpu, mem, uptime(etime))


def uptime(etime):
    """[[dd-]hh:]mm:ss → the same wording as the other bars: 5 min, 3 h, 2 d."""
    days, _, rest = etime.rpartition("-")
    fields = [int(f) for f in rest.split(":") if f.isdigit()]
    while len(fields) < 3:
        fields.insert(0, 0)
    h, m = fields[0], fields[1]
    if days.isdigit():
        return "{} d".format(int(days))
    if h:
        return "{} h".format(h)
    return "{} min".format(m) if m else "just now"


def arguments(pids):
    """{pid: full command line}."""
    if not pids:
        return {}
    args = {}
    for line in run([PS, "-o", "pid=,args=", "-p", ",".join(pids)]).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            args[parts[0]] = parts[1]
    return args


# ----------------------------------------------------------- classification

def module_root(start):
    """The directory holding the go.mod above `start`, or None."""
    if not start or not os.path.isdir(start):
        return None
    current = os.path.realpath(start)
    home = os.path.expanduser("~")
    for _ in range(LEVELS_UP):
        if os.path.isfile(os.path.join(current, "go.mod")):
            return current
        parent = os.path.dirname(current)
        if parent == current or current == home:
            break
        current = parent
    return None


def in_go_module(start):
    """Is this directory inside a Go module? Walks up looking for go.mod."""
    if not start or not os.path.isdir(start):
        return False
    current = os.path.realpath(start)
    home = os.path.expanduser("~")
    for _ in range(LEVELS_UP):
        if os.path.isfile(os.path.join(current, "go.mod")):
            return True
        parent = os.path.dirname(current)
        if parent == current or current == home:
            break
        current = parent
    return False


def runtime_of(comm, parent_comm="", cwd=None):
    base = os.path.basename(comm)
    for name, pattern in RUNTIMES:
        if pattern.match(base):
            return name
    if GO_TEMP.search(comm) or base.startswith("__debug_bin"):
        return "go"
    if os.path.basename(parent_comm) in GO_PARENTS:
        return "go"
    # A Go binary built and run directly has no tell in its name or its parent.
    # Running from inside a Go module is a signal, but on its own it catches
    # every unrelated listener started from that directory — a kubectl
    # port-forward, an ssh tunnel, a database GUI. Requiring the executable
    # itself to live inside the module narrows it to binaries you built.
    if cwd and comm.startswith("/") and in_go_module(cwd):
        mod = module_root(cwd)
        if mod and os.path.realpath(comm).startswith(mod + os.sep):
            return "go"
    return None


def is_system(comm):
    return comm.startswith(SYSTEM_PATHS)


def origin(pid, processes):
    """Walks up the parent chain looking for whoever launched it.

    It does not stop at the first hint: an `npm run dev` in IntelliJ's embedded
    terminal goes through a shell before reaching the IDE, and the IDE is what
    matters. So a shell is kept as a fallback answer and the walk continues.
    """
    seen = set()
    fallback = ""
    current = pid
    while current and current != "1" and current not in seen:
        seen.add(current)
        parent, comm = processes.get(current, (None, ""))
        ide = IDES.search(comm)
        if ide:
            return ide.group(1)
        if not fallback and (TERMINALS.search(comm) or SHELLS.search(comm)):
            fallback = "terminal"
        current = parent
    return fallback


def tokenize(line):
    """Plain split(): shlex chokes on stray quotes inside classpaths."""
    return line.split()


# Options whose value sits in the next token. Without this list, the argument
# of -e or -cp gets taken for the script and ends up as the name in the bar.
TAKES_VALUE = {
    "java": {"-cp", "-classpath", "--class-path", "-p", "--module-path",
             "--add-modules", "--add-opens", "--add-exports", "-javaagent"},
    "python": {"-c", "-m", "-W", "-X", "--check-hash-based-pycs"},
    "node": {"-e", "--eval", "-p", "--print", "-r", "--require",
             "--import", "--loader", "--experimental-loader"},
    "go": set(),
    # Bun and Deno take node-ish flags plus their own. Adding them to RUNTIMES
    # without adding them here made first_operand raise KeyError, which
    # app_name's except swallowed — the service silently lost its project.
    "bun": {"-e", "--eval", "-r", "--preload", "--config", "--port"},
    # Deno's --allow-* take their value glued on with = (--allow-net=host), so
    # they must NOT be listed here: treating them as value-taking swallowed the
    # next flag and the port number ended up as the service name.
    # --port does take a separate value (deno serve --port 8080 main.ts).
    "deno": {"-e", "--eval", "--config", "-c", "--import-map", "--lock",
             "--port", "-p"},
}

# Subcommands that come before the script and are not the script. Without this
# `bun run server.ts` reported itself as "run".
SUBCOMMANDS = {
    "bun": {"run", "x", "exec", "test", "--bun"},
    "deno": {"run", "task", "serve", "test", "bench", "eval"},
}


def first_operand(tokens, runtime):
    """First token that is neither an option, an option's value, nor a
    subcommand of the runtime itself."""
    takes_value = TAKES_VALUE.get(runtime, set())
    subcommands = SUBCOMMANDS.get(runtime, set())
    skip = False
    for t in tokens[1:]:
        if skip:
            skip = False
            continue
        if t in takes_value:
            skip = True
            continue
        if t.startswith("-"):
            continue
        if t in subcommands:
            continue
        return t
    return None


def with_folder(path):
    """A bare index.js or manage.py says nothing: prepend the directory."""
    base = os.path.basename(path)
    parent = os.path.basename(os.path.dirname(path))
    return "{}/{}".format(parent, base) if parent else base


GENERIC = {
    "__main__.py", "manage.py", "app.py", "main.py", "server.py", "run.py",
    "index.js", "server.js", "main.js", "app.js", "index.mjs", "main.ts",
}


def java_name(tokens):
    for i, t in enumerate(tokens):
        if t == "-jar" and i + 1 < len(tokens):
            return os.path.basename(tokens[i + 1])
        if t.startswith("-Dspring.application.name="):
            return t.split("=", 1)[1]
    text = " ".join(tokens)
    if "GradleDaemon" in text:
        return "Gradle (daemon)"
    if "plexus.classworlds.launcher.Launcher" in text:
        return "Maven"
    if "gradle.launcher" in text or "GradleWrapperMain" in text:
        return "Gradle"
    op = first_operand(tokens, "java")
    if not op:
        return "java"
    # A path is trimmed to its file name; a packaged class name is trimmed at
    # the last dot. Telling them apart matters: otherwise /path/Server.java
    # ends up being called "java".
    if "/" in op or op.endswith((".java", ".jar")):
        return os.path.basename(op)
    return op.rsplit(".", 1)[-1] if "." in op else op


def python_name(tokens):
    for i, t in enumerate(tokens):
        if t == "-m" and i + 1 < len(tokens):
            return tokens[i + 1]
        if t == "-c":
            return "python (-c)"
    op = first_operand(tokens, "python")
    if not op:
        return "python"
    return with_folder(op) if os.path.basename(op) in GENERIC else os.path.basename(op)


def go_name(tokens):
    # The binary IS the program: argv[0] is the name, not an interpreter.
    base = os.path.basename(tokens[0])
    return "debug build" if base.startswith("__debug_bin") else base


def node_name(tokens, runtime="node"):
    for t in tokens[1:]:
        if t in ("-e", "--eval", "-p", "--print"):
            return "%s (-e)" % runtime
    # The runtime is threaded through so bun and deno get their own flag and
    # subcommand tables: with node's, `bun run server.ts` came out as "run".
    op = first_operand(tokens, runtime)
    if not op:
        return runtime
    if "node_modules/.bin/" in op:
        return os.path.basename(op)
    base = os.path.basename(op)
    if base in ("npm-cli.js", "npm"):
        return "npm"
    if base in ("yarn.js", "yarn"):
        return "yarn"
    return with_folder(op) if base in GENERIC else base


# --------------------------------------------------------------- project name

# When the entry points are all called main.py or main.js, the name that
# identifies the service lives in the project metadata, not in the path.

MAX_METADATA = 1 << 20      # do not read absurdly large files
LEVELS_UP = 8               # cap on the walk looking for the project root

# Reverse-domain prefixes that only take up room in a menu bar. Which ones is
# a per-organisation matter, so they come from the config file.
TRIMMABLE_PREFIXES = tuple(
    p.strip() for p in CFG.get("DEVPORTS_TRIM_PREFIXES", "").split(",") if p.strip()
)


def trim_prefix(name):
    if not name:
        return name
    # npm scope: @acme/widgets → widgets
    if name.startswith("@") and "/" in name:
        rest = name.split("/", 1)[1]
        if rest:
            name = rest
    for p in TRIMMABLE_PREFIXES:
        if name.startswith(p) and len(name) > len(p):
            return name[len(p):]
    return name


def _read(path):
    if os.path.getsize(path) > MAX_METADATA:
        return None
    with open(path, "r", errors="replace") as f:
        return f.read()


def package_json_name(path):
    data = json.loads(_read(path) or "{}")
    name = data.get("name")
    return name.strip() if isinstance(name, str) and name.strip() else None


def pom_name(path):
    root = ET.fromstring(_read(path) or "")
    # Direct children only: the artifactId under <parent> is the parent's, not ours.
    for child in root:
        if child.tag.rsplit("}", 1)[-1] == "artifactId":
            return (child.text or "").strip() or None
    return None


def pyproject_name(path):
    # Python 3.9 has no tomllib, and pulling one in for a single field is overkill.
    section = None
    for line in (_read(path) or "").splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1].strip()
            continue
        if section in ("project", "tool.poetry"):
            m = re.match(r'name\s*=\s*["\']([^"\']+)["\']', s)
            if m:
                return m.group(1)
    return None


def gomod_name(path):
    m = re.search(r'(?m)^\s*module\s+(\S+)', _read(path) or "")
    return m.group(1).rstrip("/").rsplit("/", 1)[-1] if m else None


def gradle_name(path):
    m = re.search(r'rootProject\.name\s*=\s*["\']([^"\']+)["\']', _read(path) or "")
    return m.group(1) if m else None


def setup_py_name(path):
    m = re.search(r'\bname\s*=\s*["\']([^"\']+)["\']', _read(path) or "")
    return m.group(1) if m else None


MARKERS = {
    "go": (("go.mod", gomod_name),),
    "node": (("package.json", package_json_name),),
    # Bun reads package.json like node; Deno prefers its own manifest but
    # falls back to package.json in Node-compatible projects.
    "bun": (("package.json", package_json_name),),
    "deno": (("deno.json", package_json_name),
             ("deno.jsonc", package_json_name),
             ("package.json", package_json_name)),
    "python": (("pyproject.toml", pyproject_name), ("setup.py", setup_py_name)),
    "java": (("settings.gradle", gradle_name),
             ("settings.gradle.kts", gradle_name),
             ("pom.xml", pom_name),
             ("build.gradle", lambda p: None),
             ("build.gradle.kts", lambda p: None)),
}


def project_root(start, runtime):
    """Walks up from `start` until it finds a project root.

    Returns (directory, name). The name may be None if the marker exists but
    declares none: the directory name serves in that case.
    """
    if not start or not os.path.isdir(start):
        return None, None
    order = list(MARKERS.get(runtime, ()))
    for other, markers in MARKERS.items():
        if other != runtime:
            order.extend(markers)
    home = os.path.expanduser("~")
    current = os.path.realpath(start)
    for _ in range(LEVELS_UP):
        for filename, reader in order:
            path = os.path.join(current, filename)
            if os.path.isfile(path):
                try:
                    return current, reader(path) or os.path.basename(current)
                except Exception:
                    return current, os.path.basename(current)
        parent = os.path.dirname(current)
        if parent == current or current == home:
            break
        current = parent
    return None, None


def script_dir(tokens, runtime):
    """Directory of the running script, if it is an absolute path."""
    # Not for Go: `go run` builds into a temp dir, so the binary's location
    # says nothing about the project. Only the working directory does.
    if runtime == "go":
        return None
    op = first_operand(tokens, runtime)
    if op and op.startswith("/") and os.path.isabs(op):
        return os.path.dirname(op)
    return None


def app_name(runtime, line, cwd):
    """Name to display, plus the project it comes from.

    Order: identity declared on the command line, project name, and only if
    neither is there, the entry-point file.
    """
    tokens = tokenize(line)
    if not tokens:
        return runtime, None

    # 1. Explicit identity: beats everything, it is what the service calls itself.
    for t in tokens:
        if t.startswith("-Dspring.application.name="):
            value = t.split("=", 1)[1]
            if value:
                proj_dir, _ = project_root(cwd, runtime)
                return trim_prefix(value), proj_dir

    # 2. The project: from the working directory first, and if nothing comes of
    #    it, from wherever the script lives.
    proj_dir, name = project_root(cwd, runtime)
    if not name:
        try:
            proj_dir, name = project_root(script_dir(tokens, runtime), runtime)
        except Exception:
            proj_dir, name = None, None
    if name:
        return trim_prefix(name), proj_dir

    # 3. No metadata: the jar, the main class, the file or the binary.
    try:
        if runtime == "java":
            return java_name(tokens), proj_dir
        if runtime == "python":
            return python_name(tokens), proj_dir
        if runtime == "go":
            return go_name(tokens), proj_dir
        return node_name(tokens, runtime), proj_dir
    except Exception:
        return runtime, proj_dir


# ------------------------------------------------------------------- output

def settings_menu(seen, shown):
    """Settings and diagnostics. `seen` vs `shown` is the number that answers
    'why is my service not listed' without touching a terminal."""
    cfg_path = os.environ.get("SWIFTBAR_CONFIG") or os.path.expanduser(
        "~/.config/swiftbar-devkit/config.sh")
    act = 'bash="{}" terminal=false'.format(ACTION)

    print("---")
    print("Settings | sfimage=gearshape")
    if os.path.isfile(cfg_path):
        print("--{} | {}".format(cfg_path.replace(os.path.expanduser("~"), "~"), MONO))
    else:
        print("--⚠ no config file yet · using defaults | {}".format(MONO))
    print("--Open config file | {} param1=openconfig".format(act))
    print("-----")

    print("--Only IDE-launched: {}".format("yes" if IDE_ONLY else "no"))
    for label, value in (("Yes", "1"), ("No", "0")):
        mark = "  ✓" if (value == "1") == IDE_ONLY else ""
        print("----{}{} | {} param1=set param2=DEVPORTS_IDE_ONLY param3={} refresh=true"
              .format(label, mark, act, value))
    print("--Trimmed prefixes: {} | {}".format(
        ", ".join(TRIMMABLE_PREFIXES) or "none", MONO))
    print("--Debug ports: {} | {}".format(
        ", ".join(str(p) for p in sorted(DEBUG_PORTS)), MONO))
    print("-----")

    print("--Sockets: {} seen · {} shown · {} hidden | {}"
          .format(seen, shown, seen - shown, MONO))
    print("--lsof: {} · python {}.{}.{} | {}".format(
        LSOF, sys.version_info[0], sys.version_info[1], sys.version_info[2], MONO))


def main():
    ports = listening()
    processes = process_tree()
    args = arguments(list(ports.keys()))
    cwds = working_dirs(list(ports.keys()))
    starts = start_times(list(ports.keys()))

    services = []
    for pid, port_set in ports.items():
        ppid, comm = processes.get(pid, (None, ""))
        if not comm or is_system(comm):
            continue
        _, parent_comm = processes.get(ppid, (None, ""))
        runtime = runtime_of(comm, parent_comm, cwds.get(pid))
        if not runtime:
            continue
        line = args.get(pid, comm)
        if EXCLUDED_PATH.search(comm) or EXCLUDED_ARGS.search(line):
            continue
        came_from = origin(pid, processes)
        if IDE_ONLY and not IDES.search(came_from):
            continue
        ordered = sorted(port_set)
        useful = [p for p in ordered if p not in DEBUG_PORTS]
        name, project = app_name(runtime, line, cwds.get(pid))
        # The interpreter's directory says nothing the rows above do not, and
        # the Command Line Tools' Python runs to ninety characters of it before
        # the script even appears. Matched on comm, so a path with spaces in it
        # loses its directory whole rather than at the first space.
        shown = line
        if comm.startswith("/") and line.startswith(comm):
            shown = os.path.basename(comm) + line[len(comm):]
        services.append({
            "pid": pid,
            "runtime": runtime,
            "name": name,
            "project": project,
            "ports": ordered,
            "primary": useful[0] if useful else ordered[0],
            "origin": came_from,
            "cmd": shown,
            "comm": os.path.basename(comm),
            "start": starts.get(pid, ("", ""))[0],
            "usage": starts.get(pid, ("", ""))[1],
        })

    services.sort(key=lambda s: (s["primary"], s["name"]))

    if services:
        print("{} | sfimage=powerplug.fill".format(len(services)))
    else:
        print(" | sfimage=powerplug")
    print("---")

    if not services:
        print("No dev service listening")
        settings_menu(len(ports), 0)
        print("---")
        print("Refresh | refresh=true")
        return

    print("{} service{} listening".format(
        len(services), "" if len(services) == 1 else "s"))

    for s in services:
        extra = " +{}".format(len(s["ports"]) - 1) if len(s["ports"]) > 1 else ""
        print("{}{}  {}".format(s["primary"], extra, clean(s["name"])))

        detail = "{} · PID {}".format(s["runtime"], s["pid"])
        if s["origin"]:
            detail += " · {}".format(s["origin"])
        print("--{} | {}".format(clean(detail), MONO))
        if s["usage"]:
            print("--{} | {}".format(s["usage"], MONO))
        if s["project"]:
            home = os.path.expanduser("~")
            path = s["project"]
            if path.startswith(home):
                path = "~" + path[len(home):]
            print("--{} | {}".format(clean(path), MONO))
        # A debug port has nothing to open; the rest become links. Not every
        # service speaks HTTP, but on a dev box most do and the click is free.
        for p in s["ports"]:
            label = DEBUG_PORTS.get(p)
            if label:
                print("--Port {} ({}) | {}".format(p, label, MONO))
            else:
                print("--Port {} · localhost:{} | href=http://localhost:{} sfimage=globe {}"
                      .format(p, p, p, MONO))

        cmd = clean(s["cmd"])
        if len(cmd) > MAX_CMD:
            cmd = cmd[:MAX_CMD] + "…"
        print("--{} | {}".format(cmd, MONO))

        print("-----")
        # Identity travels with the action: executable AND start time. Between
        # drawing the menu and the click the PID may have been recycled, and
        # the name alone does not distinguish two JVMs.
        # Clipboard and navigation, before the destructive part of the submenu.
        print("--Copy PID {} | bash=\"{}\" param1=copy param2={} terminal=false"
              .format(s["pid"], ACTION, b64(str(s["pid"]))))
        print("--Copy localhost:{} | bash=\"{}\" param1=copy param2={} terminal=false"
              .format(s["primary"], ACTION, b64("localhost:%s" % s["primary"])))
        if s.get("project"):
            print("--Open project in IDE | bash=\"{}\" param1=openide param2={} terminal=false"
                  .format(ACTION, b64(s["project"])))
        print("--Who holds port {} | bash=\"{}\" param1=whoport param2={} terminal=true"
              .format(s["primary"], ACTION, s["primary"]))
        print("-----")

        if not s["start"]:
            # No start time, no identity: the action refuses these, so offering
            # the button would just produce a click that does nothing. Happens
            # when the process exits while the menu is being built.
            print("--Kill unavailable (process state changed) | {}".format(MONO))
        else:
            ident = b64("%s\t%s" % (s["comm"], s["start"]))
            print("--Kill | bash=\"{}\" param1=kill param2={} param3={} terminal=false refresh=true"
                  .format(ACTION, s["pid"], ident))
            print("--Force (SIGKILL) | bash=\"{}\" param1=force param2={} param3={} terminal=false refresh=true"
                  .format(ACTION, s["pid"], ident))

    if len(services) > 1:
        print("---")
        # Every entry carries its own identity; the action re-checks each one.
        batch = b64("\n".join(
            "%s\t%s\t%s" % (s["pid"], s["comm"], s["start"])
            for s in services if s["start"]))
        print("Kill all {} | bash=\"{}\" param1=killall param2={} terminal=true refresh=true"
              .format(len(services), ACTION, batch))
        # SIGKILL for whatever ignored the first round. Confirmed in the action.
        print("Force kill survivors | bash=\"{}\" param1=forceall param2={} terminal=true refresh=true"
              .format(ACTION, batch))

    settings_menu(len(ports), len(services))
    print("---")
    print("Refresh | refresh=true")


if __name__ == "__main__":
    # Buffered: main() prints the title first, so a failure halfway through used
    # to append the error banner to a half-drawn menu and SwiftBar rendered the
    # wreckage. Nothing reaches stdout unless the whole menu was built.
    import io
    buf, real = io.StringIO(), sys.stdout
    try:
        sys.stdout = buf
        main()
    except Exception as e:
        sys.stdout = real
        print(" | sfimage=exclamationmark.triangle")
        print("---")
        print("Plugin error: {}".format(clean(str(e))))
        sys.exit(0)
    finally:
        sys.stdout = real
    real.write(buf.getvalue())
