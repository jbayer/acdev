setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

write_config() { printf '%s\n' "$@" >"$PROJECT/.applecontainer.toml"; }

@test "up --dry-run builds the run command from config" {
  write_config \
    'image = "jbayer/devcontainer-flox:1.12.1"' \
    'user = "flox"' \
    'workspace = "/workspaces/container"'
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"container run -d"* ]]
  [[ "$output" == *"--name acdev-myproject-"* ]]
  [[ "$output" == *"-v $PROJECT:/workspaces/container"* ]]
  [[ "$output" == *"-w /workspaces/container"* ]]
  [[ "$output" == *"--user flox"* ]]
  [[ "$output" == *"jbayer/devcontainer-flox:1.12.1 sleep infinity"* ]]
}

@test "workspace defaults to /workspaces/<basename> when omitted" {
  write_config 'image = "img:1"'
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"-w /workspaces/myproject"* ]]
  [[ "$output" == *"-v $PROJECT:/workspaces/myproject"* ]]
}

@test "user is omitted from run command when not set" {
  write_config 'image = "img:1"'
  run acdev up --dry-run
  [[ "$output" != *"--user"* ]]
}

@test "env table becomes -e KEY=VAL flags" {
  write_config 'image = "img:1"' '[env]' 'FOO = "bar"' 'BAZ = "qux"'
  run acdev up --dry-run
  [[ "$output" == *"-e FOO=bar"* ]]
  [[ "$output" == *"-e BAZ=qux"* ]]
}

@test "missing image falls back to the default image (latest)" {
  write_config 'user = "flox"'
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"jbayer/devcontainer-flox:latest sleep infinity"* ]]
}

@test "ACDEV_DEFAULT_IMAGE overrides the fallback image" {
  write_config 'user = "flox"'
  ACDEV_DEFAULT_IMAGE='myreg/custom:9@sha256:abc' run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"myreg/custom:9@sha256:abc sleep infinity"* ]]
}

@test "explicit image in config wins over ACDEV_DEFAULT_IMAGE" {
  write_config 'image = "img:1"'
  ACDEV_DEFAULT_IMAGE='other:2' run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"img:1 sleep infinity"* ]]
  [[ "$output" != *"other:2"* ]]
}

@test "missing .applecontainer.toml is a clear error" {
  run acdev up --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *".applecontainer.toml"* ]]
}
