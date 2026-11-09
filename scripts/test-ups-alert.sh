#!/usr/bin/env bash
# Simulate a UPS power event in Home Assistant to test the "UPS on battery /
# restored" automation. Only HA's copy of the status changes; the UPS and NUT
# are untouched, and the next NUT poll (within a minute) restores the real value.
# Run on odin: bash scripts/test-ups-alert.sh [sensor.ups_office_status_data]
set -euo pipefail

ha=http://127.0.0.1:8123
entity=${1:-sensor.ups_office_status_data}
read -rsp "Home Assistant long-lived access token: " token; echo

set_state() {
    curl -fsS -X POST "$ha/api/states/$entity" \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -d "{\"state\": \"$1\"}" >/dev/null
    echo "$(date +%T)  $entity = $1"
}

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
code=$(curl -sS -o "$tmp" -w '%{http_code}' "$ha/api/states/$entity" -H "Authorization: Bearer $token")
if [[ "$code" == 401 ]]; then echo "Token rejected (401): create a new long-lived access token." >&2; exit 1; fi
if [[ "$code" == 404 ]]; then
    echo "No entity named $entity. UPS status sensors in Home Assistant:" >&2
    curl -fsS "$ha/api/states" -H "Authorization: Bearer $token" | python3 -c '
import json, sys
for e in json.load(sys.stdin):
    if e["entity_id"].startswith("sensor.") and e["entity_id"].endswith(("_status_data", "_status")):
        print("  %-50s %s" % (e["entity_id"], e["state"]))' >&2
    exit 1
fi
[[ "$code" == 200 ]] || { echo "Home Assistant returned HTTP $code." >&2; exit 1; }
before=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$tmp")
echo "Current state: $before"
[[ "$before" != unavailable && "$before" != unknown ]] || { echo "Entity has no real value; fix it before testing." >&2; exit 1; }

set_state "OB DISCHRG"      # expect: On battery
sleep 20                    # longer than an optional 15 s "for:" on the OB triggers
set_state "OB DISCHRG LB"   # expect: Battery low (only if LB triggers were added)
sleep 5
set_state "OL CHRG"         # expect: Mains power restored
