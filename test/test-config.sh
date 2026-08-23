# Config used by tests.sh, so the suite does not depend on whatever the
# machine happens to have in ~/.config/swiftbar-devkit/config.sh.
# REPOS_ROOT in the environment overrides the roots anyway.

# No REPOS_ROOTS on purpose: tests.sh always passes REPOS_ROOT in the
# environment, which wins, and hardcoding a path here would only rot.
REPOS_DEPTH=4
REPOS_IDE="Finder"
REPOS_IDE_CMD=""
REPOS_FETCH_STALE_HOURS=24
REPOS_MAX_FILES=3
