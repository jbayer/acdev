# acdev auto-handoff (zsh). Source from ~/.zshrc:
#   source /path/to/hooks/acdev.zsh
chpwd() {
  if [ -f ".applecontainer.toml" ] && [ -z "$ACDEV_INSIDE" ]; then
    acdev up && ACDEV_INSIDE=1 acdev shell
  fi
}
