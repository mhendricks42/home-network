#!/bin/sh
# Install or update HACS (pinned) into Home Assistant's config on odin, then restart HA.
# Run from the repo clone: sudo sh scripts/install-hacs.sh   (docs/runbook.md, "HACS")
# To update: change VERSION and SHA256 to the new release (sha256sum of its hacs.zip).
set -eu
VERSION=2.0.5
SHA256=97be6b824a4f38e683728cc6dd72367f6b8bad0a43428b1b3b987a3087adf413

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail "Run with sudo."
cd "$(dirname "$0")/.."
config="${DATA_ROOT:-/srv}/homeassistant/config"
[ -f "$config/configuration.yaml" ] || fail "No Home Assistant config in $config."
target="$config/custom_components/hacs"

tmp=$(mktemp -d); trap 'rm -f "$tmp/hacs.zip"; rm -rf "$tmp/hacs"; rmdir "$tmp"' EXIT
curl -fsSL -o "$tmp/hacs.zip" "https://github.com/hacs/integration/releases/download/$VERSION/hacs.zip"
printf '%s  %s\n' "$SHA256" "$tmp/hacs.zip" | sha256sum -c --quiet - || fail "Checksum mismatch: not installing."
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$tmp/hacs.zip" "$tmp/hacs"
grep -q "\"version\": \"$VERSION\"" "$tmp/hacs/manifest.json" || fail "Archive is not HACS $VERSION."

mkdir -p "$config/custom_components"
rm -rf "$target.old"; [ -d "$target" ] && mv "$target" "$target.old"
mv "$tmp/hacs" "$target"
rm -rf "$target.old"
printf 'HACS %s installed in %s\n' "$VERSION" "$target"
docker compose -f compose.server.yml restart homeassistant
