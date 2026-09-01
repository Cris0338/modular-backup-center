#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/modular-backup-center"
COCKPIT_DIR="/usr/local/share/cockpit/modular-backup-center"
CONFIG_DIR="/etc/modular-backup-center"
DATA_DIR="${MBC_BACKUP_ROOT:-/var/lib/modular-backup-center/backups}"
CONFIG_FILE="$CONFIG_DIR/config.json"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run install.sh as root"
    exit 1
fi

install -d -m 0755 "$LIB_DIR" "$COCKPIT_DIR" "$CONFIG_DIR"

# Create the default backup directory only when it does not already exist.
# A custom MBC_BACKUP_ROOT may point to an existing backup repository whose
# ownership and permissions must be preserved.
if [ ! -d "$DATA_DIR" ]; then
    install -d -m 0755 "$DATA_DIR"
fi

install -m 0755 "$ROOT_DIR/bin/mbcctl" "$LIB_DIR/mbcctl"
install -m 0644 "$ROOT_DIR/cockpit/manifest.json" "$COCKPIT_DIR/manifest.json"
install -m 0644 "$ROOT_DIR/cockpit/index.html" "$COCKPIT_DIR/index.html"
install -m 0644 "$ROOT_DIR/cockpit/app.js" "$COCKPIT_DIR/app.js"
install -m 0644 "$ROOT_DIR/cockpit/styles.css" "$COCKPIT_DIR/styles.css"

# The config contains paths and non-secret settings only. Keep it readable by
# the Cockpit session user; secrets must never be stored here.
if [ ! -f "$CONFIG_FILE" ]; then
    python3 - "$DATA_DIR" "$CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path

backup_root = sys.argv[1]
config_file = Path(sys.argv[2])
config_file.write_text(
    json.dumps({"backup_root": backup_root}, indent=2) + "\n",
    encoding="utf-8",
)
PY
    chmod 0644 "$CONFIG_FILE"
fi

echo "Modular Backup Center installed."
echo "Cockpit package: $COCKPIT_DIR"
echo "Backend:         $LIB_DIR/mbcctl"
echo "Config:          $CONFIG_FILE"
echo "Backup root:     $DATA_DIR"
echo
echo "Reload Cockpit in the browser to open Modular Backup Center."
