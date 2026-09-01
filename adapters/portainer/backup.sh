#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root"
    exit 1
fi

PORTAINER_USER="${PORTAINER_USER:-${MBC_USER:-${SUDO_USER:-}}}"

if [ -z "$PORTAINER_USER" ] || [ "$PORTAINER_USER" = "root" ]; then
    echo "ERROR: set PORTAINER_USER to the Unix user that owns the backup repository"
    exit 1
fi

USER_HOME="$(getent passwd "$PORTAINER_USER" | cut -d: -f6)"

if [ -z "$USER_HOME" ]; then
    echo "ERROR: cannot determine home directory for user: $PORTAINER_USER"
    exit 1
fi

CONTAINER="${PORTAINER_CONTAINER:-portainer}"
DATA="${PORTAINER_DATA:-/var/lib/docker/volumes/portainer_data/_data}"

BACKUP_ROOT="${MBC_BACKUP_ROOT:-${USER_HOME}/ia-server-backups}"
ROOT="${PORTAINER_BACKUP_ROOT:-${BACKUP_ROOT}/portainer}"

IMAGE_REF="${PORTAINER_IMAGE:-$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)}"
IMAGE_ID="$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)"

if [ -z "$IMAGE_REF" ] || [ -z "$IMAGE_ID" ]; then
    echo "ERROR: cannot determine Docker image for container: $CONTAINER"
    exit 1
fi

if [ ! -d "$DATA" ]; then
    echo "ERROR: Portainer data directory not found: $DATA"
    exit 1
fi

STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
NAME="portainer_${STAMP}"
FINAL="${ROOT}/${NAME}"
PARTIAL="${ROOT}/.${NAME}.partial"

SUCCESS=0
PORTAINER_WAS_RUNNING=0

cleanup() {
    if [ "$PORTAINER_WAS_RUNNING" -eq 1 ]; then
        docker start "$CONTAINER" >/dev/null 2>&1 || true
    fi

    if [ "$SUCCESS" -ne 1 ]; then
        rm -rf "$PARTIAL"
    fi
}
trap cleanup EXIT

install -d -m 0700 -o "$PORTAINER_USER" -g "$PORTAINER_USER" "$ROOT"

mkdir -p "$PARTIAL/data"
mkdir -p "$PARTIAL/image"
mkdir -p "$PARTIAL/metadata"

echo "[1/5] Recording Portainer configuration..."

docker inspect "$CONTAINER" > "$PARTIAL/metadata/docker-inspect.json"
docker image inspect "$IMAGE_ID" > "$PARTIAL/metadata/docker-image-inspect.json"

{
    echo "Portainer modular recovery backup v1"
    echo "Created: $(date --iso-8601=seconds)"
    echo "Hostname: $(hostname)"
    echo
    echo "Container:"
    echo "$CONTAINER"
    echo
    echo "Image reference:"
    echo "$IMAGE_REF"
    echo
    echo "Exact image ID:"
    echo "$IMAGE_ID"
    echo
    echo "Persistent data:"
    echo "$DATA"
    echo
    echo "Container mounts:"
    docker inspect --format '{{range .Mounts}}{{println .Type .Source "->" .Destination}}{{end}}' "$CONTAINER"
} > "$PARTIAL/metadata/manifest.txt"

echo "[2/5] Stopping Portainer briefly..."

if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true; then
    PORTAINER_WAS_RUNNING=1
    docker stop -t 10 "$CONTAINER" >/dev/null
fi

echo "[3/5] Copying persistent Portainer data..."

rsync -aAXH --numeric-ids "$DATA/" "$PARTIAL/data/"

if [ "$PORTAINER_WAS_RUNNING" -eq 1 ]; then
    docker start "$CONTAINER" >/dev/null
    PORTAINER_WAS_RUNNING=0
fi

echo "[4/5] Saving exact Docker image..."

docker save "$IMAGE_ID" -o "$PARTIAL/image/portainer-image.tar"
gzip -1 "$PARTIAL/image/portainer-image.tar"

echo "[5/5] Creating integrity checksums..."

(
    cd "$PARTIAL"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

chown -R "$PORTAINER_USER:$PORTAINER_USER" "$PARTIAL"
find "$PARTIAL" -type d -exec chmod 0700 {} +
find "$PARTIAL" -type f -exec chmod 0600 {} +

mv "$PARTIAL" "$FINAL"
SUCCESS=1

SIZE="$(du -sh "$FINAL" | awk '{print $1}')"

echo
echo "PORTAINER BACKUP OK"
echo "Backup: $FINAL"
echo "Size:   $SIZE"
echo "Verify: (cd \"$FINAL\" && sha256sum -c SHA256SUMS)"
