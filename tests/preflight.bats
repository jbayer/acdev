setup() { load 'helpers/common'; setup_acdev; printf 'image = "img:1"\n' >.applecontainer.toml; }
teardown() { teardown_acdev; }

@test "missing container binary gives an actionable error" {
  # Shadow PATH so `container` cannot be found, but acdev still can.
  PATH="$REPO_ROOT/bin:/usr/bin:/bin"
  run acdev up
  [ "$status" -ne 0 ]
  [[ "$output" == *"container"* ]]
  [[ "$output" == *"install"* || "$output" == *"not found"* || "$output" == *"Install"* ]]
}

@test "daemon-down is surfaced, not swallowed" {
  export ACDEV_FAKE_STATE=daemon_down
  run acdev up
  [ "$status" -ne 0 ]
  [[ "$output" == *"container system start"* ]]
}
