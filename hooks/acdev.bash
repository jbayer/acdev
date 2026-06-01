# acdev auto-handoff (bash). Source from ~/.bashrc:
#   source /path/to/hooks/acdev.bash
cd() {
  builtin cd "$@" || return
  if [ -f ".applecontainer.toml" ] && [ -z "$ACDEV_INSIDE" ]; then
    acdev up && ACDEV_INSIDE=1 acdev shell
  fi
}
