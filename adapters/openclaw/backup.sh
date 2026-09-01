#!/usr/bin/env bash

set -euo pipefail



IA_USER="${OPENCLAW_USER:-${MBC_USER:-${SUDO_USER:-}}}"



if [ -z "$IA_USER" ] || [ "$IA_USER" = "root" ]; then

    echo "ERROR: set OPENCLAW_USER to the Unix user that owns OpenClaw state"

    exit 1

fi



USER_HOME="${OPENCLAW_HOME:-$(getent passwd "$IA_USER" | cut -d: -f6)}"



SRC="${OPENCLAW_SRC:-/srv/OpenClaw/src}"

STATE="${OPENCLAW_STATE:-${USER_HOME}/.openclaw}"

AUTH="${OPENCLAW_AUTH:-${USER_HOME}/.openclaw-auth-profile-secrets}"

CONTROL="${OPENCLAW_CONTROL_CENTER:-${USER_HOME}/.local/share/cockpit/openclaw_control_center}"



BACKUP_ROOT="${MBC_BACKUP_ROOT:-${USER_HOME}/ia-server-backups}"

ROOT="${OPENCLAW_BACKUP_ROOT:-${BACKUP_ROOT}/openclaw}"



GATEWAY="${OPENCLAW_GATEWAY:-src-openclaw-gateway-1}"
IMAGE_ID=""
IMAGE_REPODIGEST=""
IMAGE_ID="$(docker inspect -f '{{.Image}}' "$GATEWAY")"
IMAGE_REPODIGEST="$(docker image inspect "$IMAGE_ID" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}')"

GATEWAY_WAS_RUNNING=0

GATEWAY_STOPPED=0



STAMP="$(date +%Y-%m-%d_%H-%M-%S)"

NAME="openclaw_${STAMP}"

FINAL="${ROOT}/${NAME}"

PARTIAL="${ROOT}/.${NAME}.partial"

SUCCESS=0



cleanup() {



    if [ "$GATEWAY_STOPPED" -eq 1 ] && [ "$GATEWAY_WAS_RUNNING" -eq 1 ]; then



        docker start "$GATEWAY" >/dev/null 2>&1 || true



        GATEWAY_STOPPED=0



    fi



    if [ "$SUCCESS" -ne 1 ]; then



        rm -rf "$PARTIAL"



    fi



}

trap cleanup EXIT



if [ "$(id -u)" -ne 0 ]; then

    echo "ERROR: run as root"

    exit 1

fi



install -d -m 0700 -o "$IA_USER" -g "$IA_USER" "$ROOT"

mkdir -p "$PARTIAL/state"

mkdir -p "$PARTIAL/auth-profile-secrets"

mkdir -p "$PARTIAL/control-center"

mkdir -p "$PARTIAL/deployment"

mkdir -p "$PARTIAL/metadata"

mkdir -p "$PARTIAL/image"



if docker inspect -f '{{.State.Running}}' "$GATEWAY" 2>/dev/null | grep -qx true; then

    GATEWAY_WAS_RUNNING=1

    echo "[0/6] Stopping OpenClaw gateway for a consistent snapshot..."

    docker stop "$GATEWAY" >/dev/null

    GATEWAY_STOPPED=1

fi



echo "[1/6] Copying OpenClaw state..."

rsync -aAXH --numeric-ids "$STATE/" "$PARTIAL/state/"



echo "[2/6] Copying authentication data..."

rsync -aAXH --numeric-ids "$AUTH/" "$PARTIAL/auth-profile-secrets/"



if [ "$GATEWAY_STOPPED" -eq 1 ] && [ "$GATEWAY_WAS_RUNNING" -eq 1 ]; then

    echo "[2/6] Restarting OpenClaw gateway..."

    docker start "$GATEWAY" >/dev/null

    GATEWAY_STOPPED=0

fi



echo "[3/6] Copying deployment configuration..."

if [ -d "$CONTROL" ]; then

    cp -a "$CONTROL/." "$PARTIAL/control-center/"

fi



for f in .env docker-compose.yml docker-compose.extra.yml docker-compose.sandbox.yml Dockerfile; do

    if [ -f "$SRC/$f" ]; then

        cp -a "$SRC/$f" "$PARTIAL/deployment/"

    fi

done



echo "[4/6] Recording exact running version..."

docker compose -f "$SRC/docker-compose.yml" config > "$PARTIAL/metadata/compose-resolved.yml" 2>/dev/null || true

docker inspect "$GATEWAY" > "$PARTIAL/metadata/docker-inspect.json"

docker image inspect "$IMAGE_ID" > "$PARTIAL/metadata/docker-image-inspect.json"



{

    echo "Commit: $(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"

    echo "Branch: $(git -C "$SRC" branch --show-current 2>/dev/null || true)"

    echo "Remote: $(git -C "$SRC" remote get-url origin 2>/dev/null || true)"

    echo

    git -C "$SRC" status --short --branch 2>/dev/null || true

} > "$PARTIAL/metadata/git.txt"



{

    echo "OpenClaw modular recovery backup v1"

    echo "Created: $(date --iso-8601=seconds)"

    echo "Hostname: $(hostname)"

    echo

    echo "Contains:"

    echo "- OpenClaw state and workspace"

    echo "- authentication/profile secrets"

    echo "- deployment configuration"

    echo "- Cockpit OpenClaw Control Center"

    echo "- exact Docker image"

    echo "- Git commit/version metadata"

    echo

    echo "Docker image:"

    echo "$IMAGE_ID $IMAGE_REPODIGEST"

} > "$PARTIAL/metadata/manifest.txt"



echo "[5/6] Saving exact Docker image..."

docker save "$IMAGE_ID" -o "$PARTIAL/image/openclaw-image.tar"

gzip -1 "$PARTIAL/image/openclaw-image.tar"



echo "[6/6] Creating integrity checksums..."

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

echo "OPENCLAW BACKUP OK"

echo "Backup: $FINAL"

echo "Size:   $SIZE"

echo "Verify: (cd \"$FINAL\" && sha256sum -c SHA256SUMS)"
