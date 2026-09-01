#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/modular-backup-center"
COCKPIT_DIR="/usr/local/share/cockpit/modular-backup-center"
CONFIG_DIR="/etc/modular-backup-center"
DATA_DIR="/var/lib/modular-backup-center/backups"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run install.sh as root"
    exit 1
fi

install -d -m 0755 "$LIB_DIR" "$COCKPIT_DIR" "$CONFIG_DIR"
install -d -m 0700 "$DATA_DIR"

install -m 0755 "$ROOT_DIR/bin/mbcctl" "$LIB_DIR/mbcctl"
install -m 0644 "$ROOT_DIR/cockpit/manifest.json" "$COCKPIT_DIR/manifest.json"
install -m 0644 "$ROOT_DIR/cockpit/index.html" "$COCKPIT_DIR/index.html"
install -m 0644 "$ROOT_DIR/cockpit/app.js" "$COCKPIT_DIR/app.js"
install -m 0644 "$ROOT_DIR/cockpit/styles.css" "$COCKPIT_DIR/styles.css"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    install -m 0600 "$ROOT_DIR/config/config.example.json" "$CONFIG_DIR/config.json"
fi

echo "Modular Backup Center installed."
echo "Cockpit package: $COCKPIT_DIR"
echo "Backend:         $LIB_DIR/mbcctl"
echo "Config:          $CONFIG_DIR/config.json"
echo "Backup root:     $DATA_DIR"
echo
echo "Reload Cockpit in the browser to open Modular Backup Center."
