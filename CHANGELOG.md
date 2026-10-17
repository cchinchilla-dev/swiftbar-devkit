# Changelog

## [Unreleased]

## [0.1.0] - 2026-10-17

First public release. Four SwiftBar bars, an installer, and a test suite.

### Added
- **Repos bar** — every repository under the configured roots, grouped by
  folder, with the exact commands that resolve whatever is wrong, and a
  **Run them in Terminal** that asks before each line.
  - **Branches**: listing and switching, local and remote-tracking, with every
    local branch's tracking (`↑N`/`↓N`, `local`, `gone`); deletion of branches
    whose upstream is gone or that are already merged.
  - **Worktrees**: **New worktree…** checks a branch out beside the main
    checkout as `<repo>.worktrees/<branch>` and opens it in the IDE; linked
    worktrees sit under their repository, marked `↳`, and can be removed again.
    A branch open in another worktree opens that worktree instead of a switch
    git would refuse.
  - **The commits behind ↓ and ↑**, so you see what Update brings and what
    Push sends before clicking either.
  - **Pull requests** for the branch you are on, with their checks and review,
    looked up through `gh` every 5 minutes (`REPOS_PR_MINUTES`). Failing checks
    mark the row.
  - **Background fetch** every 30 minutes (`REPOS_AUTO_FETCH_MINUTES`), never
    asking for a password, plus a manual fetch of everything eight at a time.
  - Stashes listed one by one with their own `show` / `apply` / `pop`;
    detection of half-finished rebases, merges and cherry-picks; fetch
    freshness; an optional filter that hides repositories that are up to date;
    and "open in your IDE or on the remote" with the IDE chosen per project
    type.
- **Dev ports bar** — Java, Python, Node, Bun, Deno and Go services holding a
  local port, named after their project rather than their entry point, with the
  branch each one runs from, its CPU, memory and uptime, and debug ports
  labelled and demoted. Kill, force-kill and batch kill, plus copying the PID
  or `localhost:<port>` and opening the project.
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
  shell bars and the Python one, and editable from each bar's Settings.
- **Test suite** — fixture repositories built from scratch on each run, and
  stubbed `colima`, `docker` and `curl`, so every state is reachable without
  touching the machine it runs on.

### Notes on behaviour
- Everything destructive confirms first, names what it is about to affect, and
  defaults to Cancel: killing processes, deleting branches, removing containers
  and worktrees, stopping or restarting the Colima VM and the model server.
- A kill verifies the executable **and** the process start time before signalling,
  because up to fifteen seconds pass between the menu being drawn and the click,
  and macOS reuses PIDs.
- Branch deletion uses `git branch -d`, the form git can refuse, and nothing
  that rewrites history starts in the middle of a rebase or a merge.
- Settings are written by one writer, `lib/setconfig.py`, which escapes what it
  stores: a value is never run when the bars source the file.
- The bars never write outside their own cache directory and the config file.
