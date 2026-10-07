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

@test "status shows the running container's image digest" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=running ACDEV_FAKE_NAME="$name"
  run acdev status
  [ "$status" -eq 0 ]
  [[ "$output" == *"digest    sha256:a994b4024250c41fc5fd0d387c603adca30e978378a4cba7027a39ad30c61d9b"* ]]
}

@test "status shows a stopped container's image digest" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=stopped ACDEV_FAKE_NAME="$name" ACDEV_FAKE_DIGEST="0280f47c7a8d0c4c3d78975a0fc0ac2fc5dceb8e9a151ba307c02031b1a8c6a0"
  run acdev status
  [ "$status" -eq 0 ]
  [[ "$output" == *"digest    sha256:0280f47c7a8d0c4c3d78975a0fc0ac2fc5dceb8e9a151ba307c02031b1a8c6a0"* ]]
}

@test "status omits the digest when no container exists" {
  export ACDEV_FAKE_STATE=absent
  run acdev status
  [ "$status" -eq 0 ]
  [[ "$output" != *"digest"* ]]
}
