setup() { load 'helpers/common'; setup_acdev; printf 'image = "img:1"\n' >.applecontainer.toml; }
teardown() { teardown_acdev; }

@test "down stops the container" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=running ACDEV_FAKE_NAME="$name"
  run acdev down
  [ "$status" -eq 0 ]
  grep -q "^stop $name" "$ACDEV_FAKE_LOG"
  ! grep -q "^rm " "$ACDEV_FAKE_LOG"
}

@test "down --rm stops and removes" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=running ACDEV_FAKE_NAME="$name"
  run acdev down --rm
  [ "$status" -eq 0 ]
  grep -q "^stop $name" "$ACDEV_FAKE_LOG"
  grep -q "^rm $name" "$ACDEV_FAKE_LOG"
}
