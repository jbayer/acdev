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

# --- stale-image warning on reuse -----------------------------------------
A994=a994b4024250c41fc5fd0d387c603adca30e978378a4cba7027a39ad30c61d9b
O280=0280f47c7a8d0c4c3d78975a0fc0ac2fc5dceb8e9a151ba307c02031b1a8c6a0

reuse() {  # reuse <state>: set up a container of that state named for $PROJECT
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE="$1" ACDEV_FAKE_NAME="$name"
}

@test "no warning when the container matches the local configured image" {
  reuse running
  export ACDEV_FAKE_DIGEST=$A994 ACDEV_FAKE_IMAGE_DIGEST=$A994
  run acdev up
  [ "$status" -eq 0 ]
  [[ "$output" != *"⚠"* ]]
}

@test "warns when a running container's digest differs from the local configured image" {
  reuse running
  export ACDEV_FAKE_DIGEST=$O280 ACDEV_FAKE_IMAGE_DIGEST=$A994
  run acdev up
  [ "$status" -eq 0 ]
  [[ "$output" == *"reusing"* ]]
  [[ "$output" == *"⚠"* ]]
  [[ "$output" == *"0280f47c7a8d"* ]]
  [[ "$output" == *"a994b4024250"* ]]
  [[ "$output" == *"acdev down --rm && acdev up"* ]]
}

@test "warns when a restarted container's digest differs too" {
  reuse stopped
  export ACDEV_FAKE_DIGEST=$O280 ACDEV_FAKE_IMAGE_DIGEST=$A994
  run acdev up
  [ "$status" -eq 0 ]
  [[ "$output" == *"restarted"* ]]
  [[ "$output" == *"acdev down --rm && acdev up"* ]]
}

@test "without a local image, matching names (docker.io/, :latest) don't warn" {
  printf 'image = "jbayer/x"\n' >.applecontainer.toml
  reuse running
  export ACDEV_FAKE_REF=docker.io/jbayer/x:latest
  run acdev up
  [ "$status" -eq 0 ]
  [[ "$output" != *"⚠"* ]]
}

@test "without a local image, a container pinned to another digest warns" {
  printf 'image = "jbayer/x:latest"\n' >.applecontainer.toml
  reuse running
  export ACDEV_FAKE_REF="docker.io/jbayer/x@sha256:$O280" ACDEV_FAKE_DIGEST=$O280
  run acdev up
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠"* ]]
}

@test "a digest-pinned config compares against its own digest" {
  printf 'image = "jbayer/x:1.17.0@sha256:%s"\n' "$A994" >.applecontainer.toml
  reuse running
  export ACDEV_FAKE_DIGEST=$A994 ACDEV_FAKE_REF="docker.io/jbayer/x@sha256:$A994"
  run acdev up
  [[ "$output" != *"⚠"* ]]
  export ACDEV_FAKE_DIGEST=$O280
  run acdev up
  [[ "$output" == *"⚠"* ]]
}

@test "a newly created container is never flagged" {
  export ACDEV_FAKE_STATE=absent ACDEV_FAKE_IMAGE_DIGEST=$A994
  run acdev up
  [ "$status" -eq 0 ]
  [[ "$output" != *"⚠"* ]]
}
