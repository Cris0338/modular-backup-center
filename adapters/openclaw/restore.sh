#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
BACKUP_DIR="${2:-}"

IA_USER="${OPENCLAW_USER:-${MBC_USER:-${SUDO_USER:-}}}"
if [ -z "$IA_USER" ] || [ "$IA_USER" = "root" ]; then
    echo "ERROR: set OPENCLAW_USER or MBC_USER to the Unix user that owns OpenClaw state"
    exit 1
fi

USER_HOME="${OPENCLAW_HOME:-$(getent passwd "$IA_USER" | cut -d: -f6)}"
SRC="${OPENCLAW_SRC:-/srv/OpenClaw/src}"
STATE="${OPENCLAW_STATE:-${USER_HOME}/.openclaw}"
AUTH="${OPENCLAW_AUTH:-${USER_HOME}/.openclaw-auth-profile-secrets}"
CONTROL="${OPENCLAW_CONTROL_CENTER:-${USER_HOME}/.local/share/cockpit/openclaw_control_center}"
GATEWAY="${OPENCLAW_GATEWAY:-src-openclaw-gateway-1}"
CONFIRM="${OPENCLAW_RESTORE_CONFIRM:-}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root"
    exit 1
fi

usage() {
    echo "Usage: $0 precheck <backup-dir>"
    echo "       OPENCLAW_RESTORE_CONFIRM=RESTORE $0 restore <backup-dir>"
}

if [ "$ACTION" != "precheck" ] && [ "$ACTION" != "restore" ]; then
    usage
    exit 2
fi

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: backup directory not found: $BACKUP_DIR"
    exit 2
fi

BACKUP_DIR="$(readlink -f "$BACKUP_DIR")"
CHECKSUMS="$BACKUP_DIR/SHA256SUMS"
MANIFEST="$BACKUP_DIR/metadata/manifest.txt"
IMAGE_ARCHIVE="$BACKUP_DIR/image/openclaw-image.tar.gz"
DEPLOY_ENV="$BACKUP_DIR/deployment/.env"
DEPLOY_COMPOSE="$BACKUP_DIR/deployment/docker-compose.yml"

for required in "$CHECKSUMS" "$MANIFEST" "$IMAGE_ARCHIVE" "$DEPLOY_ENV" "$DEPLOY_COMPOSE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: required backup file missing: $required"
        exit 3
    fi
done

for required_dir in "$BACKUP_DIR/state" "$BACKUP_DIR/auth-profile-secrets" "$BACKUP_DIR/deployment"; do
    if [ ! -d "$required_dir" ]; then
        echo "ERROR: required backup directory missing: $required_dir"
        exit 3
    fi
done

if ! grep -qx 'OpenClaw modular recovery backup v1' "$MANIFEST"; then
    echo "ERROR: unsupported or invalid OpenClaw backup manifest"
    exit 4
fi

echo "[1/5] Verifying backup checksums..."
(
    cd "$BACKUP_DIR"
    sha256sum --check --strict SHA256SUMS >/dev/null
)

EXPECTED_IMAGE_ID="$(awk '/^Docker image:$/ { getline; print $1; exit }' "$MANIFEST")"
EXPECTED_REPODIGEST="$(awk '/^Docker image:$/ { getline; print $2; exit }' "$MANIFEST")"
IMAGE_REF="$(awk -F= '$1 == "OPENCLAW_IMAGE" {print substr($0, index($0, "=") + 1); exit}' "$DEPLOY_ENV")"

if [[ ! "$EXPECTED_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: invalid Docker image ID in manifest: $EXPECTED_IMAGE_ID"
    exit 4
fi

if [[ ! "$EXPECTED_REPODIGEST" =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: invalid Docker RepoDigest in manifest: $EXPECTED_REPODIGEST"
    exit 4
fi

if [ -z "$IMAGE_REF" ]; then
    echo "ERROR: OPENCLAW_IMAGE is missing from backed-up .env"
    exit 4
fi

echo "[2/5] Validating restore targets..."
if ! getent passwd "$IA_USER" >/dev/null; then
    echo "ERROR: restore user does not exist: $IA_USER"
    exit 4
fi

if [ ! -d "$SRC" ]; then
    echo "ERROR: OpenClaw source/deployment directory does not exist: $SRC"
    exit 4
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not available"
    exit 4
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: docker compose is not available"
    exit 4
fi

echo "[3/5] Restore plan validated."
echo "Backup:      $BACKUP_DIR"
echo "User:        $IA_USER"
echo "State:       $STATE"
echo "Auth:        $AUTH"
echo "Deployment:  $SRC"
echo "Image ID:    $EXPECTED_IMAGE_ID"
echo "RepoDigest:  $EXPECTED_REPODIGEST"
echo "Image ref:   $IMAGE_REF"

if [ "$ACTION" = "precheck" ]; then
    echo "[4/5] No changes requested (precheck only)."
    echo "[5/5] OPENCLAW RESTORE PRECHECK OK"
    exit 0
fi

if [ "$CONFIRM" != "RESTORE" ]; then
    echo "ERROR: destructive restore requires OPENCLAW_RESTORE_CONFIRM=RESTORE"
    exit 5
fi

GATEWAY_WAS_RUNNING=0
RESTORE_COMPLETED=0

cleanup() {
    if [ "$RESTORE_COMPLETED" -ne 1 ] && [ "$GATEWAY_WAS_RUNNING" -eq 1 ]; then
        docker compose --env-file "$SRC/.env" -f "$SRC/docker-compose.yml" up -d --no-build openclaw-gateway >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "[4/9] Loading exact Docker image from backup..."
LOAD_OUTPUT="$(gzip -dc "$IMAGE_ARCHIVE" | docker load)"
echo "$LOAD_OUTPUT"
LOADED_IMAGE_ID="$(printf '%s\n' "$LOAD_OUTPUT" | sed -n 's/^Loaded image ID: //p' | tail -n 1)"

if [ "$LOADED_IMAGE_ID" != "$EXPECTED_IMAGE_ID" ]; then
    echo "ERROR: loaded Docker image ID does not match manifest"
    echo "Expected: $EXPECTED_IMAGE_ID"
    echo "Loaded:   $LOADED_IMAGE_ID"
    exit 6
fi

echo "[5/9] Applying backed-up Docker image reference..."
docker tag "$LOADED_IMAGE_ID" "$IMAGE_REF"

if docker inspect -f '{{.State.Running}}' "$GATEWAY" 2>/dev/null | grep -qx true; then
    GATEWAY_WAS_RUNNING=1
    echo "[6/9] Stopping OpenClaw gateway..."
    docker stop "$GATEWAY" >/dev/null
else
    echo "[6/9] OpenClaw gateway already stopped or absent."
fi

echo "[7/9] Restoring OpenClaw data and deployment..."
install -d -m 0700 -o "$IA_USER" -g "$IA_USER" "$STATE"
install -d -m 0700 -o "$IA_USER" -g "$IA_USER" "$AUTH"
install -d -m 0755 -o "$IA_USER" -g "$IA_USER" "$SRC"

rsync -aAXH --numeric-ids --delete "$BACKUP_DIR/state/" "$STATE/"
rsync -aAXH --numeric-ids --delete "$BACKUP_DIR/auth-profile-secrets/" "$AUTH/"
rsync -aAXH --numeric-ids "$BACKUP_DIR/deployment/" "$SRC/"

if [ -d "$BACKUP_DIR/control-center" ]; then
    install -d -m 0755 -o "$IA_USER" -g "$IA_USER" "$CONTROL"
    rsync -aAXH --numeric-ids --delete "$BACKUP_DIR/control-center/" "$CONTROL/"
fi

echo "[8/9] Starting OpenClaw with the restored image and deployment..."
docker compose --env-file "$SRC/.env" -f "$SRC/docker-compose.yml" up -d --no-build openclaw-gateway >/dev/null

for _ in $(seq 1 30); do
    STATUS="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$GATEWAY" 2>/dev/null || true)"
    if [ "$STATUS" = "healthy" ] || [ "$STATUS" = "running" ]; then
        RESTORE_COMPLETED=1
        echo "[9/9] OPENCLAW RESTORE OK"
        echo "Gateway: $GATEWAY"
        echo "Status:  $STATUS"
        echo "Image:   $LOADED_IMAGE_ID"
        exit 0
    fi
    if [ "$STATUS" = "unhealthy" ] || [ "$STATUS" = "exited" ] || [ "$STATUS" = "dead" ]; then
        echo "ERROR: OpenClaw gateway failed health check: $STATUS"
        exit 7
    fi
    sleep 2
done

echo "ERROR: OpenClaw gateway did not become healthy in time"
exit 7
