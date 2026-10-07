setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

PINNED='jbayer/devcontainer-flox:latest'

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

@test "init shows the default image but leaves it commented out" {
  run acdev init
  grep -qE "^# *image *= \"$PINNED\"" .applecontainer.toml
  ! grep -q '^image' .applecontainer.toml
}

@test "init shows ACDEV_DEFAULT_IMAGE when set, still commented so the project follows it" {
  ACDEV_DEFAULT_IMAGE='myreg/custom:9@sha256:deadbeef' run acdev init
  [ "$status" -eq 0 ]
  grep -qE '^# *image *= "myreg/custom:9@sha256:deadbeef"' .applecontainer.toml
  ! grep -q '^image' .applecontainer.toml
}

@test "a project made by init follows a later ACDEV_DEFAULT_IMAGE" {
  run acdev init
  ACDEV_DEFAULT_IMAGE='myreg/pinned:2' run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"myreg/pinned:2 sleep infinity"* ]]
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

@test "init writes nix_cache active (uncommented) when the proxy is detected" {
  ACDEV_FAKE_CACHE_RUNNING=1 run acdev init
  [ "$status" -eq 0 ]
  grep -q '^nix_cache = "http://192.168.64.1:8126"' .applecontainer.toml
  ! grep -q '^# *nix_cache' .applecontainer.toml
  # init tells the user it wired up the detected proxy
  [[ "$output" == *"nix-cache"* ]]
}

@test "a detected nix_cache flows through to up --dry-run as NIX_CONFIG" {
  ACDEV_FAKE_CACHE_RUNNING=1 run acdev init
  [ "$status" -eq 0 ]
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"NIX_CONFIG=extra-substituters = http://192.168.64.1:8126/flox?priority=1"* ]]
}

@test "a detected proxy honors ACDEV_NIX_CACHE_PORT in the written URL" {
  ACDEV_FAKE_CACHE_RUNNING=1 ACDEV_NIX_CACHE_PORT=9000 run acdev init
  [ "$status" -eq 0 ]
  grep -q '^nix_cache = "http://192.168.64.1:9000"' .applecontainer.toml
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
