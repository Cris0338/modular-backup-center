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
BACKUP_ROOT="${MBC_BACKUP_ROOT:-${USER_HOME}/ia-server-backups}"
SAFETY_ROOT="${OPENCLAW_SAFETY_ROOT:-${BACKUP_ROOT}/openclaw-safety}"
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

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not available"
    exit 4
fi

if ! command -v rsync >/dev/null 2>&1; then
    echo "ERROR: rsync is not available"
    exit 4
fi

if ! command -v gzip >/dev/null 2>&1; then
    echo "ERROR: gzip is not available"
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

STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
SAFETY_DIR="${SAFETY_ROOT}/openclaw_pre_restore_${STAMP}"
GATEWAY_WAS_RUNNING=0
RESTORE_COMPLETED=0
SAFETY_READY=0
CURRENT_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$GATEWAY" 2>/dev/null || true)"
CURRENT_IMAGE_REF="$(docker inspect -f '{{.Config.Image}}' "$GATEWAY" 2>/dev/null || true)"

if docker inspect -f '{{.State.Running}}' "$GATEWAY" 2>/dev/null | grep -qx true; then
    GATEWAY_WAS_RUNNING=1
fi

restore_tree_from_safety() {
    local source_dir="$1"
    local target_dir="$2"
    local missing_marker="$3"
    local mode="$4"

    if [ -f "$missing_marker" ]; then
        rm -rf "$target_dir"
        return
    fi

    install -d -m "$mode" -o "$IA_USER" -g "$IA_USER" "$target_dir"
    rsync -aAXH --numeric-ids --delete "$source_dir/" "$target_dir/" || true
}

restore_deployment_from_safety() {
    if [ ! -d "$SAFETY_DIR/deployment" ]; then
        return
    fi

    while IFS= read -r -d '' saved_file; do
        rel="${saved_file#"$SAFETY_DIR/deployment/"}"
        install -d -m 0755 -o "$IA_USER" -g "$IA_USER" "$(dirname "$SRC/$rel")"
        cp -a "$saved_file" "$SRC/$rel"
    done < <(find "$SAFETY_DIR/deployment" -type f -print0)

    if [ -f "$SAFETY_DIR/metadata/deployment-originally-missing.txt" ]; then
        while IFS= read -r rel; do
            [ -n "$rel" ] && rm -f "$SRC/$rel"
        done < "$SAFETY_DIR/metadata/deployment-originally-missing.txt"
    fi

    if [ -f "$SAFETY_DIR/metadata/deployment-dir-originally-missing" ]; then
        rmdir "$SRC" >/dev/null 2>&1 || true
    fi
}

rollback_restore() {
    echo "ROLLBACK: restoring pre-restore safety snapshot..." >&2

    if docker inspect -f '{{.State.Running}}' "$GATEWAY" 2>/dev/null | grep -qx true; then
        docker stop "$GATEWAY" >/dev/null 2>&1 || true
    fi

    restore_tree_from_safety \
        "$SAFETY_DIR/state" \
        "$STATE" \
        "$SAFETY_DIR/metadata/state-originally-missing" \
        0700
    restore_tree_from_safety \
        "$SAFETY_DIR/auth-profile-secrets" \
        "$AUTH" \
        "$SAFETY_DIR/metadata/auth-originally-missing" \
        0700
    restore_deployment_from_safety || true

    if [ -f "$SAFETY_DIR/metadata/control-originally-missing" ]; then
        rm -rf "$CONTROL"
    elif [ -d "$SAFETY_DIR/control-center" ]; then
        install -d -m 0755 -o "$IA_USER" -g "$IA_USER" "$CONTROL"
        rsync -aAXH --numeric-ids --delete "$SAFETY_DIR/control-center/" "$CONTROL/" || true
    fi

    if [ -n "$CURRENT_IMAGE_ID" ] && [ -n "$CURRENT_IMAGE_REF" ]; then
        docker tag "$CURRENT_IMAGE_ID" "$CURRENT_IMAGE_REF" >/dev/null 2>&1 || true
    fi

    if [ "$GATEWAY_WAS_RUNNING" -eq 1 ] && [ -f "$SRC/.env" ] && [ -f "$SRC/docker-compose.yml" ]; then
        docker compose --env-file "$SRC/.env" -f "$SRC/docker-compose.yml" up -d --no-build openclaw-gateway >/dev/null 2>&1 || true
    fi

    echo "ROLLBACK: safety snapshot retained at $SAFETY_DIR" >&2
}

cleanup() {
    status=$?
    trap - EXIT
    if [ "$status" -ne 0 ] && [ "$SAFETY_READY" -eq 1 ] && [ "$RESTORE_COMPLETED" -ne 1 ]; then
        rollback_restore
    elif [ "$status" -ne 0 ] && [ "$GATEWAY_WAS_RUNNING" -eq 1 ] && [ -f "$SRC/.env" ] && [ -f "$SRC/docker-compose.yml" ]; then
        docker compose --env-file "$SRC/.env" -f "$SRC/docker-compose.yml" up -d --no-build openclaw-gateway >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT

echo "[4/11] Capturing current OpenClaw runtime metadata..."
echo "Current image ID:  ${CURRENT_IMAGE_ID:-not present}"
echo "Current image ref: ${CURRENT_IMAGE_REF:-not present}"

if [ "$GATEWAY_WAS_RUNNING" -eq 1 ]; then
    echo "[5/11] Stopping OpenClaw gateway for a consistent safety snapshot..."
    docker stop "$GATEWAY" >/dev/null
else
    echo "[5/11] OpenClaw gateway already stopped or absent."
fi

echo "[6/11] Creating pre-restore safety snapshot..."
install -d -m 0700 -o "$IA_USER" -g "$IA_USER" "$SAFETY_ROOT" "$SAFETY_DIR"
mkdir -p "$SAFETY_DIR/state" "$SAFETY_DIR/auth-profile-secrets" "$SAFETY_DIR/deployment" "$SAFETY_DIR/metadata"

if [ -d "$STATE" ]; then
    rsync -aAXH --numeric-ids "$STATE/" "$SAFETY_DIR/state/"
else
    touch "$SAFETY_DIR/metadata/state-originally-missing"
fi

if [ -d "$AUTH" ]; then
    rsync -aAXH --numeric-ids "$AUTH/" "$SAFETY_DIR/auth-profile-secrets/"
else
    touch "$SAFETY_DIR/metadata/auth-originally-missing"
fi

if [ ! -d "$SRC" ]; then
    touch "$SAFETY_DIR/metadata/deployment-dir-originally-missing"
fi

: > "$SAFETY_DIR/metadata/deployment-originally-missing.txt"
while IFS= read -r -d '' backup_file; do
    rel="${backup_file#"$BACKUP_DIR/deployment/"}"
    if [ -f "$SRC/$rel" ]; then
        install -d -m 0700 "$(dirname "$SAFETY_DIR/deployment/$rel")"
        cp -a "$SRC/$rel" "$SAFETY_DIR/deployment/$rel"
    else
        printf '%s\n' "$rel" >> "$SAFETY_DIR/metadata/deployment-originally-missing.txt"
    fi
done < <(find "$BACKUP_DIR/deployment" -type f -print0)

if [ -d "$CONTROL" ]; then
    mkdir -p "$SAFETY_DIR/control-center"
    rsync -aAXH --numeric-ids "$CONTROL/" "$SAFETY_DIR/control-center/"
else
    touch "$SAFETY_DIR/metadata/control-originally-missing"
fi

{
    echo "Created: $(date --iso-8601=seconds)"
    echo "Gateway was running: $GATEWAY_WAS_RUNNING"
    echo "Image ID: $CURRENT_IMAGE_ID"
    echo "Image ref: $CURRENT_IMAGE_REF"
    echo "Restore source: $BACKUP_DIR"
} > "$SAFETY_DIR/metadata/safety-manifest.txt"

SAFETY_READY=1
echo "Safety snapshot: $SAFETY_DIR"

echo "[7/11] Loading exact Docker image from backup..."
LOAD_OUTPUT="$(gzip -dc "$IMAGE_ARCHIVE" | docker load)"
echo "$LOAD_OUTPUT"
LOADED_IMAGE_ID="$(printf '%s\n' "$LOAD_OUTPUT" | sed -n 's/^Loaded image ID: //p' | tail -n 1)"

if [ "$LOADED_IMAGE_ID" != "$EXPECTED_IMAGE_ID" ]; then
    echo "ERROR: loaded Docker image ID does not match manifest"
    echo "Expected: $EXPECTED_IMAGE_ID"
    echo "Loaded:   $LOADED_IMAGE_ID"
    exit 6
fi

echo "[8/11] Applying backed-up Docker image reference..."
docker tag "$LOADED_IMAGE_ID" "$IMAGE_REF"

echo "[9/11] Restoring OpenClaw data and deployment..."
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

echo "[10/11] Starting OpenClaw with the restored image and deployment..."
docker compose --env-file "$SRC/.env" -f "$SRC/docker-compose.yml" up -d --no-build openclaw-gateway >/dev/null

for _ in $(seq 1 30); do
    STATUS="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$GATEWAY" 2>/dev/null || true)"
    if [ "$STATUS" = "healthy" ]; then
        RESTORE_COMPLETED=1
        echo "[11/11] OPENCLAW RESTORE OK"
        echo "Gateway: $GATEWAY"
        echo "Status:  $STATUS"
        echo "Image:   $LOADED_IMAGE_ID"
        echo "Safety:  $SAFETY_DIR"
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
