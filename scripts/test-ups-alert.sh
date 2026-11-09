#!/usr/bin/env bash
# Simulate a UPS power event in Home Assistant to test the "UPS on battery /
# restored" automation. Only HA's copy of the status changes; the UPS and NUT
# are untouched, and the next NUT poll (within a minute) restores the real value.
# Run on odin: bash scripts/test-ups-alert.sh [sensor.ups0_status_data]
set -euo pipefail

ha=http://127.0.0.1:8123
entity=${1:-sensor.ups0_status_data}
read -rsp "Home Assistant long-lived access token: " token; echo

set_state() {
    curl -fsS -X POST "$ha/api/states/$entity" \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -d "{\"state\": \"$1\"}" >/dev/null
    echo "$(date +%T)  $entity = $1"
}

before=$(curl -fsS "$ha/api/states/$entity" -H "Authorization: Bearer $token" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
echo "Current state: $before"
[[ "$before" != unavailable && "$before" != unknown ]] || { echo "Entity has no real value; fix it before testing." >&2; exit 1; }

set_state "OB DISCHRG"      # expect: On battery
sleep 20                    # longer than an optional 15 s "for:" on the OB triggers
set_state "OB DISCHRG LB"   # expect: Battery low (only if LB triggers were added)
sleep 5
set_state "OL CHRG"         # expect: Mains power restored
