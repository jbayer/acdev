setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

@test "acdev --version prints 'acdev <semver>' and exits 0" {
  run acdev --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^acdev[[:space:]][0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "acdev -v is an alias for --version" {
  run acdev -v
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "usage/--help includes the version line" {
  run acdev --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ acdev[[:space:]][0-9]+\.[0-9]+\.[0-9]+ ]]
  [[ "$output" == *"Usage: acdev"* ]]
}

@test "the version lives in one place that the Flox build also reads" {
  # The manifest's version.command extracts this exact line; the CLI prints the
  # same value. Guards the single-source-of-truth coupling without a full build.
  ver="$(grep '^ACDEV_VERSION=' "$REPO_ROOT/bin/acdev" | cut -d'"' -f2)"
  [ -n "$ver" ]
  run acdev --version
  [[ "$output" == *"$ver"* ]]
}
