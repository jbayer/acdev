setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

@test "shell --dry-run emits exec with flox-conditional entry (flox=auto)" {
  printf 'image = "img:1"\nworkspace = "/workspaces/myproject"\n' >.applecontainer.toml
  run acdev shell --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"container exec -it -w /workspaces/myproject acdev-myproject-"* ]]
  [[ "$output" == *'if [ -d .flox ]'* ]]
  # FLOX_SHELL is set so flox can detect the shell inside the container, where
  # $SHELL is unset and `exec` hides the parent process from flox's detection.
  [[ "$output" == *"exec env FLOX_SHELL=bash flox activate"* ]]
  [[ "$output" == *"exec bash -l"* ]]
}

@test "flox=false never activates flox" {
  printf 'image = "img:1"\nflox = "false"\n' >.applecontainer.toml
  run acdev shell --dry-run
  [[ "$output" != *"flox activate"* ]]
  [[ "$output" == *"exec bash -l"* ]]
}

@test "flox=true always activates flox" {
  printf 'image = "img:1"\nflox = "true"\n' >.applecontainer.toml
  run acdev shell --dry-run
  [[ "$output" == *"exec env FLOX_SHELL=bash flox activate"* ]]
  [[ "$output" != *'if [ -d .flox ]'* ]]
}

@test "flox activation passes the configured shell to FLOX_SHELL" {
  printf 'image = "img:1"\nflox = "true"\nshell = "zsh"\n' >.applecontainer.toml
  run acdev shell --dry-run
  [[ "$output" == *"exec env FLOX_SHELL=zsh flox activate"* ]]
}

@test "shell honors a custom shell" {
  printf 'image = "img:1"\nflox = "false"\nshell = "zsh"\n' >.applecontainer.toml
  run acdev shell --dry-run
  [[ "$output" == *"exec zsh -l"* ]]
}
