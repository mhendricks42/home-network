#!/usr/bin/env bash
# List entity IDs used in a dashboard (or package) file that Home Assistant doesn't have.
# Run on odin: bash scripts/check-ha-entities.sh services/homeassistant/dashboards/network-health.yaml
set -euo pipefail
file=${1:?usage: check-ha-entities.sh FILE}
read -rsp "Home Assistant long-lived access token: " token; echo
curl -fsS http://127.0.0.1:8123/api/states -H "Authorization: Bearer $token" | python3 -c '
import json, re, sys
have = {e["entity_id"] for e in json.load(sys.stdin)}
want = sorted(set(re.findall(r"\b(?:sensor|binary_sensor|switch|device_tracker|update)\.[a-z0-9_]+", open(sys.argv[1]).read())))
missing = [e for e in want if e not in have]
for e in missing:
    # Suggest existing entities that share the last word, e.g. *_status or *_battery_charge.
    tail = e.split(".")[1].split("_")[-1]
    near = [h for h in have if h.startswith(e.split(".")[0] + ".") and h.endswith("_" + tail)][:4]
    print("MISSING", e, ("  similar: " + ", ".join(near)) if near else "")
print(f"{len(want) - len(missing)}/{len(want)} entities found.")
sys.exit(1 if missing else 0)' "$file"
