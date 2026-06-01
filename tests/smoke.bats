setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

@test "acdev --help prints usage and exits 0" {
  run acdev --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: acdev"* ]]
}

@test "acdev with no args prints usage and exits non-zero" {
  run acdev
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: acdev"* ]]
}
