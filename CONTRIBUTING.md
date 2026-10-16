# Contributing to swiftbar-devkit

Thanks for considering a contribution. This is a personal project maintained in
spare time, so expect replies to be slow — but issues and pull requests are
genuinely welcome.

## Setup

```bash
git clone https://github.com/<your-user>/swiftbar-devkit.git
cd swiftbar-devkit
git remote add upstream https://github.com/cchinchilla-dev/swiftbar-devkit.git

bash test/tests.sh
```

There is nothing to install: everything is bash and the Python that ships with
macOS. The test suite builds its own fixture repositories and stubs `colima`,
`docker` and `curl`, so it never touches your real machine.

To try your changes for real, `bash install.sh` symlinks the bars into
SwiftBar's plugin folder — so an edit to the repository is live on the next
refresh.

## Before opening a pull request

- [ ] `bash test/tests.sh` passes
- [ ] `bash -n` is clean on every script you touched
- [ ] The bar still renders: `bash plugins/<name>` prints a menu

## House style

The code is bash 3.2 — the version macOS ships — so no associative arrays and
no `${array[-1]}`. Scripts have to survive being run with `zsh`, which does not
word-split unquoted variables and whose arrays are 1-based.

**Comments explain why, not what.** Most of the ones in here record a specific
failure: a bug that was found, or a shape of input that broke something. If you
fix something subtle, leave the reason behind — it is the most useful thing in
the file.

**Anything destructive asks first.** Killing a process, deleting a branch,
removing a container: each one confirms, names what it is about to affect, and
defaults to Cancel. A new action that changes state should do the same, and the
test suite is the place to prove it refuses when it should.

## Adding a bar

Four files, following any existing bar as the model:

- `plugins/<name>.<interval>.sh` — renders the menu, reads state, changes nothing
- `bin/<name>bar-action` — every verb that changes state, with the confirmations
- `test/tests-<name>.sh` — states reached through stubbed binaries
- an entry in `install.sh`'s `BAR_*` tables, and its keys in `config.example.sh`

Settings it writes go through `lib/setconfig.py`, never a copy of its own: the
config is sourced by every bar, so how a value is escaped is not a local choice.

Keep the render cheap: these run every few seconds, forever.

## Reporting a bug

Please use the issue templates — they ask for the macOS version, which bar, and
what the plugin prints when run from a terminal. That last one is usually the
whole answer, because a bar is only ever plain text on standard output.
