setup() { load 'helpers/common'; setup_acdev; printf 'image = "img:1"\n' >.applecontainer.toml; }
teardown() { teardown_acdev; }

@test "absent container is created" {
  export ACDEV_FAKE_STATE=absent
  run acdev up
  [ "$status" -eq 0 ]
  grep -q "^run -d --name acdev-myproject-" "$ACDEV_FAKE_LOG"
  [[ "$output" == *"created"* ]]
}

@test "stopped container is restarted, not recreated" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=stopped ACDEV_FAKE_NAME="$name"
  run acdev up
  [ "$status" -eq 0 ]
  grep -q "^start $name" "$ACDEV_FAKE_LOG"
  ! grep -q "^run -d" "$ACDEV_FAKE_LOG"
  [[ "$output" == *"restarted"* ]]
}

@test "running container is reused (no run, no start)" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=running ACDEV_FAKE_NAME="$name"
  run acdev up
  [ "$status" -eq 0 ]
  ! grep -q "^run -d" "$ACDEV_FAKE_LOG"
  ! grep -q "^start " "$ACDEV_FAKE_LOG"
  [[ "$output" == *"reusing"* ]]
}
