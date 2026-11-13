#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
repository=$PWD
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/adguard/config" "$temporary/mqtt/config" "$temporary/forgejo/data/gitea/conf"
cat > "$temporary/bin/docker" <<'STUB'
#!/bin/sh
case "$*" in
    *"config --environment"*) printf 'DATA_ROOT=%s\n' "$TEST_DATA_ROOT";;
    *"up -d --build"*) : > "$TEST_DATA_ROOT/started";;
esac
STUB
# Simulate root and skip ownership changes for prepare.sh; all writes stay in the test directory.
printf '#!/bin/sh\nprintf "0\\n"\n' > "$temporary/bin/id"
printf '#!/bin/sh\nexit 0\n' > "$temporary/bin/chown"
chmod +x "$temporary/bin/docker" "$temporary/bin/id" "$temporary/bin/chown"
export TEST_DATA_ROOT="$temporary"
export PATH="$temporary/bin:$PATH"

sh scripts/prepare.sh server "$temporary/prepared" > "$temporary/output"
cmp services/adguard/AdGuardHome.yaml.example "$temporary/prepared/adguard/config/AdGuardHome.yaml"
cmp services/homeassistant/configuration.yaml "$temporary/prepared/homeassistant/config/configuration.yaml"
printf 'preserve existing credentials\n' > "$temporary/prepared/adguard/config/AdGuardHome.yaml"
sh scripts/prepare.sh server "$temporary/prepared" > "$temporary/output"
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
reject 'Usage:' pi
reject 'Unknown profile' server invalid
reject 'Run prepare.sh first' server
printf 'REPLACE_DOMAIN\n' > "$temporary/adguard/config/AdGuardHome.yaml"
reject 'Fill the AdGuard' server
printf 'schema_version: 34\n' > "$temporary/adguard/config/AdGuardHome.yaml"
reject 'Create MQTT credentials' server
printf 'homeassistant:hash\nzigbee2mqtt:hash\nfrigate:hash\n' > "$temporary/mqtt/config/passwords"
printf 'DOMAIN = example.test\n' > "$temporary/forgejo/data/gitea/conf/app.ini"
reject 'Set HOME_DOMAIN' server https
reject 'Set ZIGBEE_DEVICE' server radios
reject 'Set MQTT_FRIGATE_PASSWORD' server cameras
reject 'Register the runner' server actions
sh "$repository/scripts/start.sh" server > "$temporary/output" 2>&1
[ -f "$temporary/started" ] || { printf 'FAIL: valid configuration did not start\n' >&2; exit 1; }
printf 'PASS: 10 preflight rejection cases and valid server startup (mock Docker).\n'
