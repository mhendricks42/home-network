#!/bin/sh
set -eu

fail() { printf '%s\n' "$*" >&2; exit 1; }
cd "$(dirname "$0")/.."
node=${1:-}
case "$node" in server) ;; *) fail "Usage: sh scripts/start.sh server [https radios cameras monitoring actions]";; esac
shift
profiles=" $* "
for profile in "$@"; do
    case "$profile" in https|radios|cameras|monitoring|actions) ;; *) fail "Unknown profile: $profile";; esac
done

set -- docker compose --env-file .env -f "compose.$node.yml"
for profile in $profiles; do
    set -- "$@" --profile "$profile"
done
settings=$("$@" config --environment)
value() { printf '%s\n' "$settings" | awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }'; }
require() {
    setting=$(value "$1")
    [ -n "$setting" ] || fail "Set $1 in .env."
    case "$setting" in *REPLACE*) fail "Replace placeholder in $1.";; esac
}
root=$(value DATA_ROOT)
root=${root:-/srv}
config="$root/adguard/config/AdGuardHome.yaml"
[ -s "$config" ] || fail "Run prepare.sh first: missing $config."
if grep -q REPLACE "$config"; then fail "Fill the AdGuard domain and bcrypt hash in $config."; fi

[ -s "$root/mqtt/config/passwords" ] || fail "Create MQTT credentials first."
for user in homeassistant zigbee2mqtt frigate; do
    grep -q "^$user:" "$root/mqtt/config/passwords" || fail "Missing MQTT account: $user"
done
config="$root/forgejo/data/gitea/conf/app.ini"
[ -s "$config" ] || fail "Missing Forgejo configuration."
if grep -q REPLACE "$config"; then fail "Fill the domain in $config."; fi
case "$profiles" in *" https "*)
    for key in HOME_DOMAIN ACME_EMAIL CADDY_DNS_MODULE DNS_PROVIDER DNS_API_TOKEN; do require "$key"; done
    for file in esphome-users ersatztv-users; do
        [ -s "$root/caddy/config/$file" ] || fail "Create Caddy credentials: $file"
    done
    ;;
esac
case "$profiles" in *" radios "*)
    for key in ZIGBEE_DEVICE ZWAVE_DEVICE MQTT_Z2M_PASSWORD Z2M_AUTH_TOKEN; do require "$key"; done
    for key in ZIGBEE_DEVICE ZWAVE_DEVICE; do
        [ -c "$(value "$key")" ] || fail "$key is not an attached character device."
    done
    ;;
esac
case "$profiles" in *" cameras "*)
    require MQTT_FRIGATE_PASSWORD
    require RENDER_GID
    require DRI_DEVICE
    [ -c "$(value DRI_DEVICE)" ] || fail "DRI_DEVICE is not an attached GPU."
    for camera in 1 2 3 4 5; do
        require "FRIGATE_CAMERA_${camera}_MAIN"
        require "FRIGATE_CAMERA_${camera}_SUB"
    done
    recordings=$(value RECORDINGS_ROOT)
    mountpoint -q "$recordings" || fail "Recording disk is not mounted at $recordings."
    [ -f "$recordings/.homelab-recording-volume" ] || fail "Create the recording-volume marker on the mounted disk."
    ;;
esac
case "$profiles" in *" actions "*)
    [ -s "$root/runner/data/.runner" ] || fail "Register the runner before enabling Actions."
    ;;
esac
"$@" config --quiet
"$@" up -d --build
"$@" ps
