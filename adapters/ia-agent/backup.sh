#!/usr/bin/env bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root"
    exit 1
fi

IA_USER="${IA_AGENT_USER:-${MBC_USER:-${SUDO_USER:-}}}"

if [ -z "$IA_USER" ] || [ "$IA_USER" = "root" ]; then
    echo "ERROR: set IA_AGENT_USER to the Unix user that owns the backup repository"
    exit 1
fi

USER_HOME="$(getent passwd "$IA_USER" | cut -d: -f6)"

if [ -z "$USER_HOME" ]; then
    echo "ERROR: cannot determine home directory for user: $IA_USER"
    exit 1
fi

SOURCE="${IA_AGENT_SOURCE:-/srv/ia-agent}"
BACKEND="${IA_AGENT_BACKEND_CONTAINER:-ia-agent-backend}"
FRONTEND="${IA_AGENT_FRONTEND_CONTAINER:-ia-agent-frontend}"
VOLUME_NAME="${IA_AGENT_FRONTEND_VOLUME:-ia-agent_frontend_node_modules}"
DB_PATH="${IA_AGENT_DATABASE:-${SOURCE}/data/ia_agent.db}"
CONTROL="${IA_AGENT_CONTROL_CENTER:-${USER_HOME}/.local/share/cockpit/ia_control_center}"

BACKUP_ROOT="${MBC_BACKUP_ROOT:-${USER_HOME}/ia-server-backups}"
ROOT="${IA_AGENT_BACKUP_ROOT:-${BACKUP_ROOT}/ia-agent}"

if [ ! -d "$SOURCE" ]; then
    echo "ERROR: IA-Agent source directory not found: $SOURCE"
    exit 1
fi

if [ ! -f "$DB_PATH" ]; then
    echo "ERROR: IA-Agent SQLite database not found: $DB_PATH"
    exit 1
fi

BACKEND_IMAGE_REF="$(docker inspect -f '{{.Config.Image}}' "$BACKEND" 2>/dev/null || true)"
FRONTEND_IMAGE_REF="$(docker inspect -f '{{.Config.Image}}' "$FRONTEND" 2>/dev/null || true)"
BACKEND_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$BACKEND" 2>/dev/null || true)"
FRONTEND_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$FRONTEND" 2>/dev/null || true)"

if [ -z "$BACKEND_IMAGE_ID" ] || [ -z "$FRONTEND_IMAGE_ID" ]; then
    echo "ERROR: cannot determine IA-Agent Docker images"
    exit 1
fi

VOLUME_PATH="$(docker volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}' 2>/dev/null || true)"

if [ -z "$VOLUME_PATH" ] || [ ! -d "$VOLUME_PATH" ]; then
    echo "ERROR: Docker volume not found: $VOLUME_NAME"
    exit 1
fi

STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
NAME="ia-agent_${STAMP}"
FINAL="${ROOT}/${NAME}"
PARTIAL="${ROOT}/.${NAME}.partial"

SUCCESS=0
BACKEND_WAS_RUNNING=0
FRONTEND_WAS_RUNNING=0

cleanup() {
    if [ "$BACKEND_WAS_RUNNING" -eq 1 ]; then
        docker start "$BACKEND" >/dev/null 2>&1 || true
    fi

    if [ "$FRONTEND_WAS_RUNNING" -eq 1 ]; then
        docker start "$FRONTEND" >/dev/null 2>&1 || true
    fi

    if [ "$SUCCESS" -ne 1 ]; then
        rm -rf "$PARTIAL"
    fi
}
trap cleanup EXIT

install -d -m 0700 -o "$IA_USER" -g "$IA_USER" "$ROOT"

mkdir -p \
    "$PARTIAL/app" \
    "$PARTIAL/control-center" \
    "$PARTIAL/metadata" \
    "$PARTIAL/image" \
    "$PARTIAL/volumes"

echo "[1/7] Recording IA-Agent configuration..."

if [ -f "$SOURCE/docker-compose.yml" ]; then
    docker compose -f "$SOURCE/docker-compose.yml" config \
        > "$PARTIAL/metadata/compose-resolved.yml" 2>/dev/null || true
fi

docker inspect "$BACKEND" "$FRONTEND" \
    > "$PARTIAL/metadata/docker-inspect.json"

docker image inspect "$BACKEND_IMAGE_ID" "$FRONTEND_IMAGE_ID" \
    > "$PARTIAL/metadata/docker-images.json"

docker volume inspect "$VOLUME_NAME" \
    > "$PARTIAL/metadata/docker-volume.json"

if [ -d "$SOURCE/.git" ]; then
    {
        echo "Commit: $(git -C "$SOURCE" rev-parse HEAD 2>/dev/null || true)"
        echo "Branch: $(git -C "$SOURCE" branch --show-current 2>/dev/null || true)"
        echo "Remote: $(git -C "$SOURCE" remote get-url origin 2>/dev/null || true)"
        echo
        git -C "$SOURCE" status --short --branch 2>/dev/null || true
    } > "$PARTIAL/metadata/git.txt"
fi

echo "[2/7] Stopping IA-Agent briefly for a consistent snapshot..."

if docker inspect -f '{{.State.Running}}' "$BACKEND" 2>/dev/null | grep -qx true; then
    BACKEND_WAS_RUNNING=1
    docker stop -t 10 "$BACKEND" >/dev/null
fi

if docker inspect -f '{{.State.Running}}' "$FRONTEND" 2>/dev/null | grep -qx true; then
    FRONTEND_WAS_RUNNING=1
    docker stop -t 10 "$FRONTEND" >/dev/null
fi

echo "[3/7] Copying application data..."

rsync -aAXH --numeric-ids \
    --exclude='backups/***' \
    --exclude='frontend/node_modules/***' \
    --exclude='frontend/dist/***' \
    --exclude='data/ia_agent.db' \
    "$SOURCE/" "$PARTIAL/app/"

python3 - "$DB_PATH" "$PARTIAL/ia_agent.db" <<'SQLITE'
import sqlite3
import sys

source, destination = sys.argv[1], sys.argv[2]

src = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
dst = sqlite3.connect(destination)

try:
    src.backup(dst)
    result = dst.execute("PRAGMA integrity_check").fetchone()
    if not result or str(result[0]).lower() != "ok":
        raise SystemExit("SQLite integrity_check failed")
finally:
    dst.close()
    src.close()
SQLITE

if [ -d "$CONTROL" ]; then
    cp -a "$CONTROL/." "$PARTIAL/control-center/"
fi

echo "[4/7] Saving frontend dependency volume..."

tar --xattrs --acls --numeric-owner \
    -C "$VOLUME_PATH" \
    -czf "$PARTIAL/volumes/frontend-node-modules.tar.gz" .

if [ "$BACKEND_WAS_RUNNING" -eq 1 ]; then
    docker start "$BACKEND" >/dev/null
    BACKEND_WAS_RUNNING=0
fi

if [ "$FRONTEND_WAS_RUNNING" -eq 1 ]; then
    docker start "$FRONTEND" >/dev/null
    FRONTEND_WAS_RUNNING=0
fi

echo "[5/7] Saving exact Docker images..."

docker save \
    "$BACKEND_IMAGE_ID" \
    "$FRONTEND_IMAGE_ID" \
    -o "$PARTIAL/image/ia-agent-images.tar"

gzip -1 "$PARTIAL/image/ia-agent-images.tar"

echo "[6/7] Writing recovery manifest..."

{
    echo "IA-Agent modular recovery backup v2"
    echo "Created: $(date --iso-8601=seconds)"
    echo "Hostname: $(hostname)"
    echo "Source: $SOURCE"
    echo
    echo "Contains:"
    echo "- IA-Agent application files"
    echo "- consistent SQLite database backup"
    echo "- Cockpit IA Control Center"
    echo "- exact backend Docker image"
    echo "- exact frontend Docker image"
    echo "- frontend node_modules Docker volume"
    echo "- Docker/Compose metadata"
    echo "- Git version metadata"
    echo
    echo "Backend container:"
    echo "$BACKEND"
    echo
    echo "Backend image reference:"
    echo "$BACKEND_IMAGE_REF"
    echo
    echo "Backend exact image ID:"
    echo "$BACKEND_IMAGE_ID"
    echo
    echo "Frontend container:"
    echo "$FRONTEND"
    echo
    echo "Frontend image reference:"
    echo "$FRONTEND_IMAGE_REF"
    echo
    echo "Frontend exact image ID:"
    echo "$FRONTEND_IMAGE_ID"
    echo
    echo "Frontend volume:"
    echo "$VOLUME_NAME"
    echo
    echo "Excluded from app tree because stored/reconstructible elsewhere:"
    echo "backups/"
    echo "frontend/node_modules/"
    echo "frontend/dist/"
    echo "data/ia_agent.db -> stored separately as ia_agent.db"
} > "$PARTIAL/metadata/manifest.txt"

echo "[7/7] Creating integrity checksums..."

(
    cd "$PARTIAL"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

chown -R "$IA_USER:$IA_USER" "$PARTIAL"
find "$PARTIAL" -type d -exec chmod 0700 {} +
find "$PARTIAL" -type f -exec chmod 0600 {} +

mv "$PARTIAL" "$FINAL"
SUCCESS=1

SIZE="$(du -sh "$FINAL" | awk '{print $1}')"

echo
echo "IA-AGENT BACKUP OK"
echo "Backup: $FINAL"
echo "Size:   $SIZE"
echo "Verify: (cd \"$FINAL\" && sha256sum -c SHA256SUMS)"
