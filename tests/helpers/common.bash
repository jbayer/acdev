# Shared bats setup. Source from each test file's setup().
# Puts bin/ and the fake container on PATH ahead of the real one,
# and creates an isolated temp workspace per test.

setup_acdev() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FAKE_DIR="$REPO_ROOT/tests/helpers"
  # bin/ first (acdev), then fake-container dir (shadows real `container`)
  PATH="$REPO_ROOT/bin:$FAKE_DIR:$PATH"
  export PATH

  # Where the fake container records its invocations.
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/acdev-test.XXXXXX")"
  export ACDEV_FAKE_LOG="$WORK/calls.log"
  : >"$ACDEV_FAKE_LOG"

  # A throwaway project directory we cd into.
  PROJECT="$WORK/myproject"
  mkdir -p "$PROJECT"
  cd "$PROJECT" || return 1
}

teardown_acdev() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}
