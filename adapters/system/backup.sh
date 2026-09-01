#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root"
    exit 1
fi

SYSTEM_USER="${SYSTEM_USER:-${MBC_USER:-${SUDO_USER:-}}}"

if [ -z "$SYSTEM_USER" ] || [ "$SYSTEM_USER" = "root" ]; then
    echo "ERROR: set SYSTEM_USER to the Unix user that owns the backup repository"
    exit 1
fi

USER_HOME="$(getent passwd "$SYSTEM_USER" | cut -d: -f6)"
SYSTEM_GROUP="$(id -gn "$SYSTEM_USER")"

if [ -z "$USER_HOME" ]; then
    echo "ERROR: cannot determine home directory for user: $SYSTEM_USER"
    exit 1
fi

BACKUP_ROOT="${MBC_BACKUP_ROOT:-${USER_HOME}/ia-server-backups}"
ROOT="${SYSTEM_BACKUP_ROOT:-${BACKUP_ROOT}/system}"

ROOT_SOURCE="$(readlink -f "$(findmnt -no SOURCE /)")"
ROOT_PARENT="$(lsblk -no PKNAME "$ROOT_SOURCE" | head -n1)"

if [ -z "$ROOT_PARENT" ]; then
    echo "ERROR: cannot determine physical disk containing root filesystem"
    exit 1
fi

SOURCE_DISK="/dev/${ROOT_PARENT}"
ROOT_FSTYPE="$(findmnt -no FSTYPE /)"

EFI_SOURCE="$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)"
EFI_PRESENT=0

if [ -n "$EFI_SOURCE" ]; then
    EFI_SOURCE="$(readlink -f "$EFI_SOURCE")"
    EFI_PARENT="$(lsblk -no PKNAME "$EFI_SOURCE" | head -n1)"

    if [ -z "$EFI_PARENT" ]; then
        echo "ERROR: cannot determine physical disk containing EFI filesystem"
        exit 1
    fi

    EFI_DISK="/dev/${EFI_PARENT}"

    if [ "$EFI_DISK" != "$SOURCE_DISK" ]; then
        echo "ERROR: root and EFI are on different physical disks; this SYSTEM adapter currently requires one disk"
        exit 1
    fi

    EFI_PRESENT=1
fi

HOST="$(hostname -s)"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
NAME="${HOST}_system_${STAMP}"
FINAL="${ROOT}/${NAME}"
PARTIAL="${ROOT}/.${NAME}.partial"

SUCCESS=0
WORK=""

cleanup() {
    if [ -n "$WORK" ]; then
        rm -rf "$WORK"
    fi

    if [ "$SUCCESS" -ne 1 ]; then
        rm -rf "$PARTIAL"
    fi
}
trap cleanup EXIT

install -d -m 0700 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$ROOT"

WORK="$(mktemp -d "${ROOT}/.staging.XXXXXX")"

mkdir -p \
    "$PARTIAL" \
    "$WORK/rootfs" \
    "$WORK/efi"

EXCLUDES=(
    "/proc"
    "/sys"
    "/dev"
    "/run"
    "/tmp"
    "/mnt"
    "/media"
    "/swap.img"
    "$BACKUP_ROOT"
    "$USER_HOME/.cache"
    "/root/.cache"
    "/srv/ia-agent"
    "/srv/OpenClaw"
    "$USER_HOME/.openclaw"
    "$USER_HOME/.openclaw-auth-profile-secrets"
    "$USER_HOME/.local/share/cockpit/ia_control_center"
    "$USER_HOME/.local/share/cockpit/openclaw_control_center"
    "$USER_HOME/.local/share/cockpit/openclaw_control_center.backup-pre-edit"
    "/var/lib/docker"
    "/var/lib/containerd"
    "/var/cache"
    "/var/tmp"
    "/var/log/journal"
    "/var/crash"
    "/lost+found"
    "/cdrom"
)

if [ -n "${MBC_SYSTEM_EXTRA_EXCLUDES:-}" ]; then
    IFS=':' read -r -a EXTRA_EXCLUDES <<< "$MBC_SYSTEM_EXTRA_EXCLUDES"

    for path in "${EXTRA_EXCLUDES[@]}"; do
        if [ -n "$path" ]; then
            EXCLUDES+=("$path")
        fi
    done
fi

{
    for path in "${EXCLUDES[@]}"; do
        printf '%s\n' "$path"
    done
} > "$PARTIAL/exclusions.txt"

cat > "$PARTIAL/README-RESTORE.txt" <<TXT
Modular Backup Center - SYSTEM bare-metal backup

Created: $(date --iso-8601=seconds)
Hostname: $(hostname)
Source disk: $SOURCE_DISK
Root filesystem: $ROOT_SOURCE ($ROOT_FSTYPE)
EFI filesystem: ${EFI_SOURCE:-not mounted}

This module contains the operating system and host configuration.

It intentionally DOES NOT contain:
- Modular Backup Center backup repository
- known application modules handled by their own adapters
- Docker/containerd images and runtime state
- caches and temporary files

Recommended restore order:
1. SYSTEM
2. application modules
3. management modules
TXT

{
    echo "Modular Backup Center SYSTEM backup v1"
    echo "Created: $(date --iso-8601=seconds)"
    echo "Hostname: $(hostname)"
    echo "Source disk: $SOURCE_DISK"
    echo "Root source: $ROOT_SOURCE"
    echo "Root filesystem: $ROOT_FSTYPE"
    echo "EFI source: ${EFI_SOURCE:-not mounted}"
    echo
    echo "=== OS ==="
    cat /etc/os-release 2>/dev/null || true
    echo
    echo "=== Kernel ==="
    uname -a
    echo
    echo "=== Disk layout ==="
    lsblk -o NAME,SIZE,FSTYPE,FSVER,TYPE,MOUNTPOINTS,MODEL "$SOURCE_DISK"
    echo
    echo "=== Filesystems ==="
    blkid
    echo
    echo "=== EFI entries ==="
    efibootmgr -v 2>/dev/null || true
    echo
    echo "=== GRUB ==="
    grub-install --version 2>/dev/null || true
} > "$PARTIAL/system-manifest.txt"

sfdisk -d "$SOURCE_DISK" > "$PARTIAL/partition-table.sfdisk"

{
    blkid "$ROOT_SOURCE"

    if [ "$EFI_PRESENT" -eq 1 ]; then
        blkid "$EFI_SOURCE"
    fi
} > "$PARTIAL/filesystems.txt"

cp -a /etc/fstab "$PARTIAL/fstab"

if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$PARTIAL/packages.tsv"
elif command -v rpm >/dev/null 2>&1; then
    rpm -qa | sort > "$PARTIAL/packages.tsv"
else
    echo "Package inventory unavailable" > "$PARTIAL/packages.tsv"
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files --state=enabled --no-pager \
        > "$PARTIAL/enabled-services.txt" 2>/dev/null || true
else
    echo "systemd unavailable" > "$PARTIAL/enabled-services.txt"
fi

RSYNC_EXCLUDES=()

for path in "${EXCLUDES[@]}"; do
    RSYNC_EXCLUDES+=(--exclude="$path")
    RSYNC_EXCLUDES+=(--exclude="${path%/}/***")
done

echo "[1/5] Copying root filesystem..."

rsync -aAXH --numeric-ids --sparse --one-file-system \
    "${RSYNC_EXCLUDES[@]}" \
    / "$WORK/rootfs/"

if [ "$EFI_PRESENT" -eq 1 ]; then
    echo "[2/5] Copying EFI filesystem..."
    rsync -aH /boot/efi/ "$WORK/efi/"
else
    echo "[2/5] No EFI filesystem mounted; skipping EFI copy"
fi

echo "[3/5] Creating filesystem archives..."

tar --acls --xattrs --numeric-owner \
    -C "$WORK/rootfs" \
    -czf "$PARTIAL/rootfs.tar.gz" .

if [ "$EFI_PRESENT" -eq 1 ]; then
    tar \
        -C "$WORK/efi" \
        -czf "$PARTIAL/efi.tar.gz" .
fi

echo "[4/5] Testing archives..."

gzip -t "$PARTIAL/rootfs.tar.gz"
tar -tzf "$PARTIAL/rootfs.tar.gz" >/dev/null

if [ "$EFI_PRESENT" -eq 1 ]; then
    gzip -t "$PARTIAL/efi.tar.gz"
    tar -tzf "$PARTIAL/efi.tar.gz" >/dev/null
fi

echo "[5/5] Creating integrity checksums..."

(
    cd "$PARTIAL"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

chown -R "$SYSTEM_USER:$SYSTEM_GROUP" "$PARTIAL"
find "$PARTIAL" -type d -exec chmod 0700 {} +
find "$PARTIAL" -type f -exec chmod 0600 {} +

mv "$PARTIAL" "$FINAL"
SUCCESS=1

SIZE="$(du -sh "$FINAL" | awk '{print $1}')"

echo
echo "SYSTEM BACKUP OK"
echo "Backup: $FINAL"
echo "Size:   $SIZE"
echo "Verify: (cd \"$FINAL\" && sha256sum -c SHA256SUMS)"
