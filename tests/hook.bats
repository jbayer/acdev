setup() {
  load 'helpers/common'; setup_acdev
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Stub acdev to just record calls.
  STUB="$WORK/bin"; mkdir -p "$STUB"
  cat >"$STUB/acdev" <<EOF
#!/usr/bin/env bash
echo "acdev \$*" >>"$WORK/hook.log"
EOF
  chmod +x "$STUB/acdev"
  PATH="$STUB:$PATH"
}
teardown() { teardown_acdev; }

@test "bash hook fires acdev up && shell when marker present" {
  : >"$WORK/hook.log"
  mkdir -p "$WORK/proj"; touch "$WORK/proj/.applecontainer.toml"
  source "$REPO_ROOT/hooks/acdev.bash"
  cd "$WORK/proj"
  grep -q "acdev up" "$WORK/hook.log"
  grep -q "acdev shell" "$WORK/hook.log"
}

@test "bash hook is a no-op without the marker" {
  : >"$WORK/hook.log"
  mkdir -p "$WORK/plain"
  source "$REPO_ROOT/hooks/acdev.bash"
  cd "$WORK/plain"
  [ ! -s "$WORK/hook.log" ]
}

@test "bash hook is suppressed inside a session" {
  : >"$WORK/hook.log"
  mkdir -p "$WORK/proj2"; touch "$WORK/proj2/.applecontainer.toml"
  source "$REPO_ROOT/hooks/acdev.bash"
  ACDEV_INSIDE=1 bash -c 'source "'"$REPO_ROOT"'/hooks/acdev.bash"; cd "'"$WORK"'/proj2"; echo done' >/dev/null
  [ ! -s "$WORK/hook.log" ]
}
