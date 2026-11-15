# Export / rename Home Assistant entity IDs in bulk (docs/ha-dashboard.md).
# Runs inside the HA container (uses its aiohttp), token from $HA_TOKEN:
#   sudo --preserve-env=HA_TOKEN docker compose -f compose.server.yml exec -T -e HA_TOKEN \
#     homeassistant python3 - export|apply|apply --dry-run < scripts/ha-entities.py
# export writes /config/ha-entities.json; edit "new_entity_id" / "enable", then apply.
import asyncio, json, os, re, sys
import aiohttp

FILE = "/config/ha-entities.json"
PLATFORMS = {"nut", "uptime_kuma", "systemmonitor", "adguard", "unifi", "sabnzbd", "qbittorrent"}
VALID = re.compile(r"^[a-z_]+\.[a-z0-9_]*[a-z0-9]$")


async def main(mode, dry):
    async with aiohttp.ClientSession() as session, session.ws_connect("ws://127.0.0.1:8123/api/websocket") as ws:
        await ws.receive_json()
        await ws.send_json({"type": "auth", "access_token": os.environ["HA_TOKEN"]})
        if (await ws.receive_json())["type"] != "auth_ok":
            sys.exit("Token rejected.")
        seq = 0

        async def call(**msg):
            nonlocal seq
            seq += 1
            await ws.send_json({"id": seq, **msg})
            while True:
                reply = await ws.receive_json()
                if reply.get("id") == seq:
                    if not reply["success"]:
                        sys.exit(f"{msg['type']} failed: {reply['error']}")
                    return reply["result"]

        entities = await call(type="config/entity_registry/list")
        if mode == "export":
            devices = {d["id"]: d for d in await call(type="config/device_registry/list")}
            rows = []
            for e in entities:
                if e["platform"] not in PLATFORMS:
                    continue
                d = devices.get(e["device_id"]) or {}
                rows.append({"entity_id": e["entity_id"], "new_entity_id": e["entity_id"],
                             "enable": False, "disabled": bool(e.get("disabled_by")),
                             "platform": e["platform"], "device": d.get("name_by_user") or d.get("name"),
                             "name": e.get("name") or e.get("original_name")})
            rows.sort(key=lambda r: (r["platform"], r["device"] or "", r["entity_id"]))
            with open(FILE, "w") as f:
                json.dump(rows, f, indent=1)
            print(f"{len(rows)} entities written to {FILE}")
            return

        rows = json.load(open(FILE))
        have = {e["entity_id"] for e in entities}
        targets = [r["new_entity_id"] for r in rows if r["new_entity_id"] != r["entity_id"]]
        # Refuse the whole batch on a bad or clashing name, before changing anything.
        bad = [t for t in targets if not VALID.match(t)]
        dupes = {t for t in targets if targets.count(t) > 1}
        taken = [t for t in targets if t in have and t not in {r["entity_id"] for r in rows if r["new_entity_id"] != r["entity_id"]}]
        if bad or dupes or taken:
            sys.exit(f"Not applied. Invalid: {bad} Duplicate: {sorted(dupes)} Already exists: {taken}")
        for r in rows:
            change = {}
            if r["new_entity_id"] != r["entity_id"]:
                change["new_entity_id"] = r["new_entity_id"]
            if r.get("enable") and r.get("disabled"):
                change["disabled_by"] = None
            if not change:
                continue
            if r["entity_id"] not in have:
                print("skip (no longer exists):", r["entity_id"])
                continue
            print(("would update " if dry else "updated ") + r["entity_id"], change)
            if not dry:
                await call(type="config/entity_registry/update", entity_id=r["entity_id"], **change)
        if not dry:
            print("Done. Re-enabled entities appear after HA reloads the integration (about 30 s).")


mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode not in ("export", "apply"):
    sys.exit("usage: export | apply [--dry-run]")
asyncio.run(main(mode, "--dry-run" in sys.argv))
