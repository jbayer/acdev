setup() { load 'helpers/common'; setup_acdev; printf 'image = "img:1"\n' >.applecontainer.toml; }
teardown() { teardown_acdev; }

@test "status reports running and shows the IP" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=running ACDEV_FAKE_NAME="$name"
  run acdev status
  [ "$status" -eq 0 ]
  [[ "$output" == *"running"* ]]
  [[ "$output" == *"192.168.64.42"* ]]
  [[ "$output" == *"$name"* ]]
}

@test "status reports absent" {
  export ACDEV_FAKE_STATE=absent
  run acdev status
  [ "$status" -eq 0 ]
  [[ "$output" == *"absent"* ]]
}
