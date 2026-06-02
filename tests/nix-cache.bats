setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

@test "up --dry-run injects NIX_CONFIG when nix_cache is set" {
  printf 'image = "img:1"\nnix_cache = "http://192.168.64.1:8126"\n' >.applecontainer.toml
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"-e NIX_CONFIG=extra-substituters = http://192.168.64.1:8126/flox?priority=1 http://192.168.64.1:8126/nixos?priority=2"* ]]
}

@test "up --dry-run has no NIX_CONFIG when nix_cache is unset" {
  printf 'image = "img:1"\n' >.applecontainer.toml
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"NIX_CONFIG"* ]]
}

@test "trailing slash on nix_cache is normalized" {
  printf 'image = "img:1"\nnix_cache = "http://192.168.64.1:8126/"\n' >.applecontainer.toml
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://192.168.64.1:8126/flox?priority=1"* ]]
  [[ "$output" != *"8126//flox"* ]]
}

@test "acdev-nix-cache --print-config renders the template (default listen)" {
  export ACDEV_NIX_CACHE_TEMPLATE="$REPO_ROOT/nix-cache/nginx.conf.template"
  export ACDEV_NIX_CACHE_DIR="$WORK/nixcache"
  export ACDEV_NIX_CACHE_PORT=8126
  run acdev-nix-cache --print-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"listen 192.168.64.1:8126;"* ]]
  [[ "$output" == *"proxy_pass https://cache.flox.dev/;"* ]]
  [[ "$output" == *"proxy_pass https://cache.nixos.org/;"* ]]
  [[ "$output" == *"$WORK/nixcache/cache"* ]]
}

@test "acdev-nix-cache honors ACDEV_NIX_CACHE_LISTEN override" {
  export ACDEV_NIX_CACHE_TEMPLATE="$REPO_ROOT/nix-cache/nginx.conf.template"
  export ACDEV_NIX_CACHE_DIR="$WORK/nixcache"
  export ACDEV_NIX_CACHE_LISTEN=0.0.0.0
  run acdev-nix-cache --print-config
  [[ "$output" == *"listen 0.0.0.0:8126;"* ]]
}
