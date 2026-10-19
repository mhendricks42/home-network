#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
repository=$PWD
temporary=$(mktemp -d)
trap 'rm -f "$temporary/docker" "$temporary/id" "$temporary/output" "$temporary/started" "$temporary/adguard/config/AdGuardHome.yaml" "$temporary/mqtt/config/passwords" "$temporary/forgejo/data/gitea/conf/app.ini" "$temporary/prepared/adguard/config/AdGuardHome.yaml"; rmdir "$temporary/adguard/config" "$temporary/adguard" "$temporary/mqtt/config" "$temporary/mqtt" "$temporary/forgejo/data/gitea/conf" "$temporary/forgejo/data/gitea" "$temporary/forgejo/data" "$temporary/forgejo" "$temporary/prepared/adguard/config" "$temporary/prepared/adguard/data" "$temporary/prepared/adguard" "$temporary/prepared/uptime-kuma/data" "$temporary/prepared/uptime-kuma" "$temporary/prepared" "$temporary"' EXIT
mkdir -p "$temporary/adguard/config" "$temporary/mqtt/config" "$temporary/forgejo/data/gitea/conf"
cat > "$temporary/docker" <<'STUB'
#!/bin/sh
case "$*" in
    *"config --environment"*) printf 'DATA_ROOT=%s\n' "$TEST_DATA_ROOT";;
    *"up -d --build"*) : > "$TEST_DATA_ROOT/started";;
esac
STUB
chmod +x "$temporary/docker"
export TEST_DATA_ROOT="$temporary"
export PATH="$temporary:$PATH"

# Simulate root only for prepare.sh; all writes stay in the test directory.
printf '#!/bin/sh\nprintf "0\\n"\n' > "$temporary/id"
chmod +x "$temporary/id"
sh scripts/prepare.sh pi "$temporary/prepared" > "$temporary/output"
cmp services/adguard/AdGuardHome.yaml.example "$temporary/prepared/adguard/config/AdGuardHome.yaml"
printf 'preserve existing credentials\n' > "$temporary/prepared/adguard/config/AdGuardHome.yaml"
sh scripts/prepare.sh pi "$temporary/prepared" > "$temporary/output"
grep -q '^preserve existing credentials$' "$temporary/prepared/adguard/config/AdGuardHome.yaml"
printf 'PASS: preparation copies initial config and preserves existing state.\n'

reject() {
    expected=$1
    shift
    if sh "$repository/scripts/start.sh" "$@" > "$temporary/output" 2>&1; then
        printf 'FAIL: expected rejection: %s\n' "$expected" >&2
        exit 1
    fi
    grep -q "$expected" "$temporary/output" || { cat "$temporary/output"; exit 1; }
    [ ! -e "$temporary/started" ] || { printf 'FAIL: started before validation\n' >&2; exit 1; }
}
reject 'Usage:' unknown
reject 'Unknown profile' server invalid
reject 'Pi has no optional profiles' pi https
reject 'Run prepare.sh first' pi
printf 'REPLACE_DOMAIN\n' > "$temporary/adguard/config/AdGuardHome.yaml"
reject 'Fill the AdGuard' pi
printf 'schema_version: 34\n' > "$temporary/adguard/config/AdGuardHome.yaml"
reject 'Create MQTT credentials' server
printf 'homeassistant:hash\nzigbee2mqtt:hash\nfrigate:hash\n' > "$temporary/mqtt/config/passwords"
printf 'DOMAIN = example.test\n' > "$temporary/forgejo/data/gitea/conf/app.ini"
reject 'Set HOME_DOMAIN' server https
reject 'Set ZIGBEE_DEVICE' server radios
reject 'Set MQTT_FRIGATE_PASSWORD' server cameras
reject 'Register the runner' server actions
sh "$repository/scripts/start.sh" pi > "$temporary/output" 2>&1
[ -f "$temporary/started" ] || { printf 'FAIL: valid configuration did not start\n' >&2; exit 1; }
printf 'PASS: 11 preflight rejection cases and valid Pi startup (mock Docker).\n'
