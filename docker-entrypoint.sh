#!/bin/sh
# Prepare the daemon profile inside the mounted volume, then hand off to qbzd.
# Runs as the unprivileged container user, so /data must already be writable by
# it (docker-compose.yml sets `user:` and the README covers ownership).
set -eu

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/qbzd"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/qbzd"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/qbzd"

mkdir -p "$config_dir" "$data_dir" "$cache_dir"
chmod 0700 "$config_dir"

# Seed an editable qbzd.toml on first start; never overwrite the operator's.
if [ ! -e "$config_dir/qbzd.toml" ]; then
    cp /usr/share/qbzd/qbzd.toml.example "$config_dir/qbzd.toml"
    echo "qbzd: seeded default config at $config_dir/qbzd.toml"
fi

if [ ! -d /dev/snd ]; then
    echo "qbzd: warning - /dev/snd is not present; the daemon will run but has no audio device" >&2
fi

exec "$@"
