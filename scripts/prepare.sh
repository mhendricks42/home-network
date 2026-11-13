#!/bin/sh
set -eu

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail "Run as root on the target Linux host."
node=${1:-}
root=${2:-/srv}
case "$node" in server) ;; *) fail "Usage: sh scripts/prepare.sh server [/srv]";; esac
case "$root" in /*) ;; *) fail "Data root must be an absolute path.";; esac
cd "$(dirname "$0")/.."
umask 077

copy_once() {
    if [ -e "$2" ]; then
        printf 'Keeping existing %s\n' "$2"
    else
        cp "$1" "$2"
        printf 'Created %s; review before starting.\n' "$2"
    fi
}

mkdir -p "$root/adguard/config" "$root/adguard/data"
copy_once services/adguard/AdGuardHome.yaml.example "$root/adguard/config/AdGuardHome.yaml"

for directory in caddy/data caddy/config mqtt/config mqtt/data homeassistant/config/packages \
    zigbee2mqtt/data zwave/data esphome/config frigate/config frigate/data/clips \
    netalertx/data forgejo/data/gitea/conf runner/data; do
    mkdir -p "$root/$directory"
done
copy_once services/homeassistant/configuration.yaml "$root/homeassistant/config/configuration.yaml"
for file in automations.yaml scenes.yaml; do
    if [ ! -e "$root/homeassistant/config/$file" ]; then
        printf '[]\n' > "$root/homeassistant/config/$file"
    fi
done
if [ ! -e "$root/homeassistant/config/scripts.yaml" ]; then
    printf '{}\n' > "$root/homeassistant/config/scripts.yaml"
fi
copy_once services/zigbee2mqtt/configuration.yaml "$root/zigbee2mqtt/data/configuration.yaml"
copy_once services/frigate/config.yml "$root/frigate/config/config.yml"
copy_once services/forgejo/app.ini.example "$root/forgejo/data/gitea/conf/app.ini"
if [ ! -e "$root/mqtt/config/passwords" ]; then
    : > "$root/mqtt/config/passwords"
fi
# These images run as non-root; other containers retain their image's defaults.
chown -R 1883:1883 "$root/mqtt"
chown -R 1000:1000 "$root/forgejo" "$root/runner"
printf '%s\n' "Preparation complete. Fill placeholders and credentials using docs/runbook.md."
