# Changelog

## [Unreleased]

### Added
- **Background fetch** in the Repos bar, every 30 minutes by default
  (`REPOS_AUTO_FETCH_MINUTES`), so behind/ahead stay current without a click.
  It never asks for a password: a remote that wants one is skipped.
- **Pull requests** in the Repos bar: the open PR for each branch, with its
  checks and review, looked up through `gh` every 5 minutes
  (`REPOS_PR_MINUTES`). Failing checks mark the row and count as pending.
- **CPU, memory and uptime** for every service in the Dev ports bar.

### Fixed
- **Run them in Terminal** ran each suggested line on Return, as written: a
  commit with `"..."` as its message, and `--abort` straight after a
  `--continue` that stopped on a conflict. Each line now asks `[y/N]`, a
  failure ends the sequence, and a line with a placeholder is never run.
- Settings written from the Repos and Colima menus were stored unescaped in a
  file every bar sources: a `$` in a folder name was expanded away, and a
  `$(…)` would have run on every refresh.
- A `|` in a stash message, a file name, a group or a remote name spilled into
  SwiftBar's parameters.
- A scan root that is a symlink, or whose path holds `[ ]`, and a root that no
  longer exists all read "All up to date · 0 repos". The missing root is now
  named, with Settings still on hand to remove it.
- A worktree whose main repository moved was shown as a detached HEAD, with
  advice about commits that would be lost.
- `zsh install.sh` ignored which bars you picked and handed Homebrew every
  formula as one name.
- Rows with an icon left their neighbours indented on macOS 26, which lines a
  whole menu section up on its icons.

### Changed
- Stopping or restarting the Colima VM or its service, and restarting
  llama-swap, now ask first: everything running goes down with them.
- The Repos bar walks each root once instead of three times, and stays out of
  `.git`. Colima asks Docker for its containers once per refresh, llama-swap
  reads every model's state in one `jq`.
- The ports bar shows the interpreter by name, not by its full path.
- New screenshots, in light and dark.

## [0.1.0] - 2026-08-23

First public release. Four SwiftBar bars, an installer, and a test suite.

### Added
- **Repos bar** — every repository under the configured roots, grouped by
  folder, with the exact commands that resolve whatever is wrong. Branch
  listing and switching (local and remote-tracking), deletion of branches whose
  upstream is gone, stashes listed one by one with their own `show` / `apply` /
  `pop`, detection of half-finished rebases, merges and cherry-picks, fetch
  freshness, parallel fetch eight at a time, an optional filter that hides
  repositories that are up to date, and "open in your IDE or on the remote"
  with the IDE chosen per project type.
- **Dev ports bar** — Java, Python, Node, Bun, Deno and Go services holding a
  local port, named after their project rather than their entry point, with
  debug ports labelled and demoted. Kill, force-kill and batch kill, plus
  copying the PID or `localhost:<port>` and opening the project.
- **Colima bar** — containers with status, logs, a shell, clickable published
  ports and the ID on the clipboard; Compose projects; image and VM disk usage
  with a warning threshold; the Homebrew service; and a repair for the registry
  credentials left behind by a Docker Desktop migration.
- **llama-swap bar** — which model is loaded, named in the menu bar itself;
  load, unload and switch; RAM, GPU, swap and the context window in use.
- **Installer** that asks which bars you want — one, some or all — and offers
  their dependencies (`colima`, `llama-swap`, `llama.cpp`, `jq`) through
  Homebrew. It never uninstalls anything.
- **One config file** shared by every bar, `config.example.sh`, read by both the
  shell bars and the Python one.
- **Test suite** — fixture repositories built from scratch on each run, and
  stubbed `colima`, `docker` and `curl`, so every state is reachable without
  touching the machine it runs on.

### Notes on behaviour
- Everything destructive confirms first, names what it is about to affect, and
  defaults to Cancel: killing processes, deleting branches, removing containers,
  stopping the model server.
- A kill verifies the executable **and** the process start time before signalling,
  because up to fifteen seconds pass between the menu being drawn and the click,
  and macOS reuses PIDs.
- The bars never write outside their own cache directory and the config file.
