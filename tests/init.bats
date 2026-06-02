setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

PINNED='jbayer/devcontainer-flox:1.12.1@sha256:ce5b46c215b06ca580a02fa4793d929855a4b8e3a9d7acd4d47662a4a29be4a3'

@test "init creates .applecontainer.toml when none exists" {
  [ ! -f .applecontainer.toml ]
  run acdev init
  [ "$status" -eq 0 ]
  [ -f .applecontainer.toml ]
  [[ "$output" == *"created"* ]]
}

@test "init message points at 'acdev up' and 'acdev shell'" {
  run acdev init
  [[ "$output" == *"acdev up"* ]]
  [[ "$output" == *"acdev shell"* ]]
}

@test "init writes the hard-coded pinned default image, active (uncommented)" {
  run acdev init
  grep -qF "image = \"$PINNED\"" .applecontainer.toml
}

@test "init lists the optional settings but comments them out" {
  run acdev init
  # present but commented
  grep -q '^# *user' .applecontainer.toml
  grep -q '^# *workspace' .applecontainer.toml
  grep -q '^# *shell' .applecontainer.toml
  grep -q '^# *flox' .applecontainer.toml
  grep -q '^# *nix_cache' .applecontainer.toml
  # not active
  ! grep -q '^user' .applecontainer.toml
  ! grep -q '^shell' .applecontainer.toml
  ! grep -q '^flox' .applecontainer.toml
  ! grep -q '^workspace' .applecontainer.toml
  ! grep -q '^nix_cache' .applecontainer.toml
}

@test "the generated config drives up --dry-run cleanly" {
  run acdev init
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"container run -d"* ]]
  [[ "$output" == *"$PINNED sleep infinity"* ]]
}

@test "init does nothing when .applecontainer.toml already exists" {
  printf 'image = "preexisting:1"\n' > .applecontainer.toml
  run acdev init
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  # original untouched
  grep -q '^image = "preexisting:1"' .applecontainer.toml
  ! grep -q 'devcontainer-flox' .applecontainer.toml
}
