# acdev auto-handoff (fish). Source from ~/.config/fish/config.fish:
#   source /path/to/hooks/acdev.fish
function __acdev_autostart --on-variable PWD
    if test -f .applecontainer.toml; and test -z "$ACDEV_INSIDE"
        acdev up; and ACDEV_INSIDE=1 acdev shell
    end
end
