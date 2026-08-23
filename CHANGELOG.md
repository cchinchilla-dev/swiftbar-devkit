# Changelog

## [Unreleased]

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
